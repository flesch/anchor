// anchor — headless Dock anchor daemon
//
// Compile:
//   swiftc -framework Cocoa -framework ApplicationServices anchor.swift -o anchor
//
// Usage:
//   ./anchor [display_index]   # 0 = primary (default), 1 = second display, etc.
//   ./anchor --list            # print available displays and exit
//
// The binary must be granted Accessibility access in:
//   System Settings > Privacy & Security > Accessibility
//
// To run at login, install the launchd plist:
//   cp flesch.anchor.plist ~/Library/LaunchAgents/
//   launchctl load ~/Library/LaunchAgents/flesch.anchor.plist

import Cocoa
import ApplicationServices
import CoreGraphics
import IOKit

// MARK: - Display

struct Display {
    let id: CGDirectDisplayID
    let frame: CGRect    // CG coordinates: y=0 at top-left of primary, increases downward
    let name: String
    let isPrimary: Bool
}

func getDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    let mainID = CGMainDisplayID()
    let displays = (0..<Int(count)).map { i -> Display in
        let id = ids[i]
        return Display(id: id, frame: CGDisplayBounds(id), name: displayName(id), isPrimary: id == mainID)
    }
    return displays.sorted {
        if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
        return $0.frame.minX < $1.frame.minX
    }
}

func displayName(_ id: CGDirectDisplayID) -> String {
    if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
    var iter: io_iterator_t = 0
    let matching = IOServiceMatching("IODisplayConnect")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
        return "Display \(id)"
    }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        guard let unmanaged = IODisplayCreateInfoDictionary(svc, IOOptionBits(kIODisplayOnlyPreferredName)),
              let info = unmanaged.takeRetainedValue() as? [String: Any],
              let names = info[kDisplayProductName] as? [String: String],
              let name = names.values.first,
              let v = info[kDisplayVendorID] as? Int,
              let p = info[kDisplayProductID] as? Int,
              UInt32(v) == CGDisplayVendorNumber(id),
              UInt32(p) == CGDisplayModelNumber(id)
        else { continue }
        return name
    }
    return "Display \(id)"
}

// MARK: - Dock geometry

enum DockEdge: String {
    case bottom, left, right

    static func current() -> DockEdge {
        let raw = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        return DockEdge(rawValue: raw) ?? .bottom
    }

    func triggerZone(for display: Display) -> CGRect {
        let f = display.frame
        switch self {
        case .bottom: return CGRect(x: f.minX,      y: f.maxY - 10, width: f.width,  height: 10)
        case .left:   return CGRect(x: f.minX,      y: f.minY,      width: 10,       height: f.height)
        case .right:  return CGRect(x: f.maxX - 10, y: f.minY,      width: 10,       height: f.height)
        }
    }

    func triggerPoint(for display: Display) -> CGPoint {
        let f = display.frame
        switch self {
        case .bottom: return CGPoint(x: f.midX,      y: f.maxY - 1)
        case .left:   return CGPoint(x: f.minX + 1,  y: f.midY)
        case .right:  return CGPoint(x: f.maxX - 1,  y: f.midY)
        }
    }

    func approachPoint(for display: Display, offset: CGFloat = 50) -> CGPoint {
        let f = display.frame
        switch self {
        case .bottom: return CGPoint(x: f.midX,          y: f.maxY - offset)
        case .left:   return CGPoint(x: f.minX + offset,  y: f.midY)
        case .right:  return CGPoint(x: f.maxX - offset,  y: f.midY)
        }
    }
}

// MARK: - Dock location detection

func dockDisplay(from displays: [Display]) -> CGDirectDisplayID? {
    guard let pid = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    else { return nil }

    let app = AXUIElementCreateApplication(pid)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement], !wins.isEmpty
    else { return nil }

    var posRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(wins[0], kAXPositionAttribute as CFString, &posRef) == .success,
          let axVal = posRef
    else { return nil }

    var pos = CGPoint.zero
    AXValueGetValue(axVal as! AXValue, .cgPoint, &pos)
    return displays.first { $0.frame.contains(pos) }?.id
}

// MARK: - Relocation

let syntheticMarker: Int64 = 0xD0C4A5C4

func relocate(to anchor: Display, edge: DockEdge) {
    var savedPos = CGPoint.zero
    if let e = CGEvent(source: nil) { savedPos = e.location }

    let approach = edge.approachPoint(for: anchor)
    let edge_pt  = edge.triggerPoint(for: anchor)
    let source   = CGEventSource(stateID: .hidSystemState)

    CGWarpMouseCursorPosition(approach)
    Thread.sleep(forTimeInterval: 0.03)

    for i in 0..<8 {
        let t = CGFloat(i) / 7.0
        let pt = CGPoint(x: approach.x + (edge_pt.x - approach.x) * t,
                         y: approach.y + (edge_pt.y - approach.y) * t)
        CGWarpMouseCursorPosition(pt)
        postSyntheticMove(at: pt, source: source)
        Thread.sleep(forTimeInterval: 0.015)
    }
    for _ in 0..<8 {
        CGWarpMouseCursorPosition(edge_pt)
        postSyntheticMove(at: edge_pt, source: source)
        Thread.sleep(forTimeInterval: 0.025)
    }

    CGWarpMouseCursorPosition(savedPos)
}

private func postSyntheticMove(at pt: CGPoint, source: CGEventSource?) {
    guard let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: pt, mouseButton: .left) else { return }
    ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    ev.post(tap: .cghidEventTap)
}

// MARK: - Daemon

final class DockAnchorDaemon {
    let anchorIndex: Int
    var displays: [Display] = []
    var anchorID: CGDirectDisplayID = 0
    var eventTap: CFMachPort?
    var isRelocating = false

    init(anchorIndex: Int) {
        self.anchorIndex = anchorIndex
    }

    func start() {
        displays = getDisplays()
        guard !displays.isEmpty else { die("No displays found.") }

        let idx = min(anchorIndex, displays.count - 1)
        let anchor = displays[idx]
        anchorID = anchor.id
        let edge = DockEdge.current()

        printDisplayInfo(anchor: anchor, index: idx, edge: edge)
        checkAccessibility()
        installEventTap()
        registerDisplayReconfiguration()

        if displays.count > 1 {
            relocateDockIfNeeded(to: anchor, edge: edge)
        }

        print("Monitoring. Press Ctrl-C to stop.")
        RunLoop.main.run()
    }

    private func printDisplayInfo(anchor: Display, index: Int, edge: DockEdge) {
        print("Displays:")
        for (i, d) in displays.enumerated() {
            print("  [\(i)] \(d.name)\(d.isPrimary ? " (primary)" : "")")
        }
        print("Anchor : [\(index)] \(anchor.name)")
        print("Dock   : \(edge.rawValue) edge")
    }

    private func relocateDockIfNeeded(to anchor: Display, edge: DockEdge) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            if let current = dockDisplay(from: self.displays), current == self.anchorID {
                print("Dock already on anchor display.")
            } else {
                print("Relocating dock to anchor display…")
                self.isRelocating = true
                relocate(to: anchor, edge: edge)
                self.isRelocating = false
                print("Dock relocated.")
            }
        }
    }

    // MARK: Event tap

    func installEventTap() {
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                Unmanaged<DockAnchorDaemon>.fromOpaque(refcon!).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            die("Failed to create event tap. Ensure Accessibility access is granted, then re-run.")
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }

        if isRelocating {
            // Let our synthetic events through; discard real ones
            return event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
                ? Unmanaged.passUnretained(event) : nil
        }

        let loc = event.location
        let edge = DockEdge.current()
        for display in displays where display.id != anchorID {
            if edge.triggerZone(for: display).contains(loc) {
                return nil  // block
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Display reconfiguration

    func registerDisplayReconfiguration() {
        CGDisplayRegisterReconfigurationCallback({ _, _, ref in
            guard let ref else { return }
            let daemon = Unmanaged<DockAnchorDaemon>.fromOpaque(ref).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                daemon.displays = getDisplays()
                print("Display config changed — \(daemon.displays.count) display(s) active.")
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Accessibility

    func checkAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("⚠️  Accessibility permission required.")
            print("   Grant it in System Settings > Privacy & Security > Accessibility, then re-run.")
            exit(1)
        }
    }
}

// MARK: - Entry point

func die(_ msg: String) -> Never {
    fputs("Error: \(msg)\n", stderr)
    exit(1)
}

let args = CommandLine.arguments.dropFirst()

if args.contains("--list") {
    for (i, d) in getDisplays().enumerated() {
        print("[\(i)] \(d.name)\(d.isPrimary ? " (primary)" : "") — \(d.frame)")
    }
    exit(0)
}

let anchorIndex = args.first.flatMap(Int.init) ?? 0
let daemon = DockAnchorDaemon(anchorIndex: anchorIndex)
daemon.start()
