<p align="center"><img width="200" alt="Image" src="https://github.com/user-attachments/assets/d4047f7e-d507-4dfd-b277-7b1855b1ad19" /></p>

# Anchor

A headless macOS daemon that keeps the Dock anchored to a specific display in multi-monitor setups.

By default, macOS lets the Dock migrate to whichever display the cursor approaches — anchor stops that. It intercepts mouse movements near the Dock trigger zones on non-anchor displays and, if the Dock ever drifts, nudges it back automatically at startup.

## Requirements

- macOS (tested on macOS Sequoia)
- Swift compiler (`swiftc`) — included with Xcode Command Line Tools

> [!IMPORTANT]
> The binary must be granted **Accessibility** access before it can intercept mouse events:
> **System Settings → Privacy & Security → Accessibility**

## Installation

**1. Compile the binary**

```sh
swiftc -framework Cocoa -framework ApplicationServices anchor.swift -o anchor
```

**2. Move it somewhere on your `PATH`** (the default plist expects `/usr/local/bin/anchor`)

```sh
sudo mv anchor /usr/local/bin/anchor
```

**3. Install the LaunchAgent** to run anchor automatically at login

```sh
cp flesch.anchor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/flesch.anchor.plist
```

## Usage

```
anchor [display_index]   # 0 = primary display (default), 1 = second display, etc.
anchor --list            # print available displays and exit
```

### Examples

```sh
# Anchor the Dock to the primary display (default)
anchor

# Anchor the Dock to the second display
anchor 1

# List available displays
anchor --list
# [0] Built-in Display (primary) — (0.0, 0.0, 1512.0, 982.0)
# [1] Pro Display XDR — (1512.0, 0.0, 3008.0, 1692.0)
```

## How it works

On startup, anchor:

1. Enumerates active displays and selects the anchor display by index.
2. Detects where the Dock currently lives using the Accessibility API.
3. If the Dock is on the wrong display, it synthesizes a smooth mouse movement to the anchor display's Dock trigger zone to relocate it.
4. Installs a low-level `CGEventTap` that blocks mouse movements from entering the Dock trigger zone on any non-anchor display, preventing macOS from moving the Dock away.

Synthetic events are tagged with a private marker so anchor can distinguish its own events from real user input and never accidentally blocks itself.

## Configuration

The `flesch.anchor.plist` LaunchAgent can be customized:

| Key | Default | Description |
|---|---|---|
| `ProgramArguments` | `/usr/local/bin/anchor` | Path to the binary. Add a display index as a second argument to pin to a non-primary display. |
| `KeepAlive` | `true` | Restart automatically if the daemon crashes. |
| `StandardOutPath` | `/tmp/anchor.log` | Stdout log file. |
| `StandardErrorPath` | `/tmp/anchor.err` | Stderr log file. |

To reload after changes:

```sh
launchctl unload ~/Library/LaunchAgents/flesch.anchor.plist
launchctl load   ~/Library/LaunchAgents/flesch.anchor.plist
```

## Troubleshooting

**The Dock still moves to another display**  
Make sure the binary has been granted Accessibility access. anchor will print a warning and exit if the permission is missing.

**`Failed to create event tap`**  
Revoke and re-grant Accessibility access in System Settings, then restart anchor.

**Checking logs**

```sh
tail -f /tmp/anchor.log
tail -f /tmp/anchor.err
```
