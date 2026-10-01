<div align="center">

<img src="./assets/header.svg" alt="MouseFix" width="100%"/>

<br/>

[![Swift](https://img.shields.io/badge/Swift_6.0-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)
[![macOS](https://img.shields.io/badge/macOS_13+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)

**Ditch Logi Options+. Keep every button.**

Open-source mouse button remapper for macOS. YAML config, zero telemetry, no cloud account.<br/>
Built for the MX Master 4, works with any multi-button mouse.

</div>

---

## Why

Logi Options+ installs background daemons that eat 30-70% CPU, phone home to Logitech servers, and run unauthorized tasks you never asked for. Uninstalling it is a multi-step process because it buries LaunchDaemons, LaunchAgents, and updaters deep in your system.

Your mouse works fine without it. macOS has native HID drivers. The only thing you lose is button remapping and gestures.

MouseFix gives that back in ~600 lines of Swift. One binary, one YAML config file, zero network calls. You own every line of code and can see exactly what it does. No account, no cloud, no telemetry, no updater daemon running at 3am.

## Features

| Feature | Description |
|---------|-------------|
| **Button Remapping** | Map any mouse button to any keyboard shortcut |
| **Held Modifiers** | Hold Command, Shift, Control, or Option with a mouse button |
| **Gesture Engine** | Hold a button + swipe mouse for directional actions (Spaces, Expose) |
| **Device-aware Smooth Scroll** | Adds continuous pixel scrolling to the configured mouse and stops when wheel input stops, without changing trackpad events |
| **Laser Pointer** | Hold a button to project a colored circle on screen |
| **Haptic Feedback** | Logitech HID++ protocol sends vibration pulses to the mouse |
| **Discovery Mode** | `mousefix discover` shows what number each button reports |
| **Any Mouse** | Config maps raw button numbers to actions - works with any device |


## Quick Start

### 1. Build

```bash
git clone https://github.com/zzz-bot-7/mousefix.git
cd mousefix
swift build -c release

# Install as .app bundle (recommended  - required for Accessibility permissions)
mkdir -p /Applications/MouseFix.app/Contents/MacOS
cp .build/release/MouseFix /Applications/MouseFix.app/Contents/MacOS/MouseFix
```

### 2. Permissions

MouseFix needs Accessibility permission to intercept and remap mouse events:

**System Settings > Privacy & Security > Accessibility** → click **+** → add **MouseFix** from /Applications.

### 3. Run

```bash
/Applications/MouseFix.app/Contents/MacOS/MouseFix
```

A 🖱 icon appears in the menu bar. Click it to enable/disable or quit. Your MX Master 4 buttons are now remapped with the defaults below.

### Default Mappings (MX Master 4)

These are the out-of-the-box mappings. They work immediately if you have an MX Master 4 connected via Bluetooth.

| Button | Action |
|--------|--------|
| Middle click | MiddleClick (unchanged) |
| Back thumb | Cmd+Z (Undo) |
| Screenshot | Cmd+Shift+4 |
| Button below screenshot | Hold Command |
| Large thumb button 6 | Tap: App Switcher; swipe: Spaces, Mission Control, App Expose |
| Below-scroll SmartShift | LaserPointer (HID++ control `0x00C4`, hold to show) |
| Horizontal side wheel | Repeated Left/Right Arrow presses |

The vertical wheel uses continuous pixel scrolling with native macOS scroll phases and stops when wheel input stops. The horizontal side wheel produces proportional Left/Right Arrow presses. Events from Apple trackpads and every unrelated input device pass through unchanged.


## Customizing

### Edit the config

```bash
mkdir -p ~/.config/mousefix
cp config.example.yaml ~/.config/mousefix/config.yaml
```

Open `~/.config/mousefix/config.yaml` in any editor. The format maps macOS button numbers directly to actions:

```yaml
# Map button numbers to actions
buttons:
  2: "MiddleClick"          # Middle click
  3: "Cmd+Z"                # Back thumb -> Undo
  4: "Cmd"                  # Hold Command
  5: "Cmd+Shift+4"          # Screenshot
  6: "None"                 # Reserved for gestures

# SmartShift is HID++ control 0x00C4 and is reserved for the laser pointer.

# The MX Master 4 large thumb control reports as button 6.
gesture:
  button: 6
  logitech_control: false
  click: "Cmd+Tab"           # Tap -> App Switcher
  hold_left: "Ctrl+Right"   # Swipe left -> Space right
  hold_right: "Ctrl+Left"   # Swipe right -> Space left
  hold_up: "MissionControl"  # Swipe up -> Mission Control
  hold_down: "AppExpose"    # Swipe down -> App Expose

# Side wheel behaves like repeated Left/Right Arrow presses.
tilt_scroll:
  left: "Left"
  right: "Right"

# Only matching Logitech mouse events are transformed.
scroll:
  enabled: true
  device: "mx master"
  response: 0.68
  speed: 1.0
```

### Using a different mouse

If you're not using an MX Master 4, your button numbers might be different. Run discovery mode to find them:

```bash
mousefix discover
```

Press each button on your mouse. The output shows the number macOS assigns to it:

```
[discover] Button DOWN - number: 3
[discover] Button UP   - number: 3
```

Then edit your config to use those numbers. Any mouse with extra buttons (3+) works for button remapping. Gesture detection works with any mouse. Smooth scrolling is limited to the device name configured under `scroll`. Haptic feedback is Logitech-only (HID++ protocol).

### Action types

| Action | What it does |
|--------|-------------|
| `"Cmd+Z"` | Any keyboard shortcut. Modifiers: `Cmd`, `Ctrl`, `Shift`, `Opt` |
| `"Cmd"` | Holds Command until the mouse button is released |
| `"Shift"` | Holds Shift until the mouse button is released |
| `"MiddleClick"` | Native middle click passthrough |
| `"LaserPointer"` | Red circle overlay follows cursor while button is held |
| `"MissionControl"` | Triggers Mission Control (via private CoreDock API) |
| `"AppExpose"` | Triggers App Expose (current app windows) |
| `"ShowDesktop"` | Triggers Show Desktop |
| `"None"` | Disables the button |

### Supported keys

`A-Z`, `0-9`, `[ ] ; ' , . / \ - =`, `Left Right Up Down`, `F1-F15`, `Space Tab Return Escape Delete Home End PageUp PageDown`


## CLI

```
mousefix              Run the daemon (default)
mousefix run          Same as above
mousefix discover     Log button numbers for all mouse events
mousefix help         Show help
mousefix version      Show version
```


## Architecture

```
Sources/MouseFix/
  main.swift            CLI entry, arg parsing, daemon loop, menu bar icon, signal handling
  EventTap.swift        CGEvent tap - intercepts otherMouse + scrollWheel events
  KeySynth.swift        Parses "Cmd+Z" strings, synthesizes CGEvent keystrokes
  GestureEngine.swift   Gesture button hold + mouse delta -> directional actions
  HapticEngine.swift    IOKit HID manager + HID++ protocol for haptic feedback
  LogitechControlMonitor.swift  HID++ SmartShift control diversion
  LaserPointer.swift    NSWindow overlay - transparent circle follows cursor
  Config.swift          YAML config loading via Yams
  ButtonMap.swift       Button number -> Action enum mapping
  InputDeviceResolver.swift  Physical HID sender -> configured mouse or trackpad
  SmoothScrollEngine.swift   Pixel scrolling and gesture phases
Sources/MouseFixHIDBridge/
  MouseFixHIDBridge.c    Reads the HID sender ID retained by a Quartz event
```

### How it works

1. **CGEvent tap** intercepts `otherMouseDown/Up` and `scrollWheel` events at the session level
2. Button number is looked up in the config to find the mapped action
3. Original mouse event is suppressed and a synthesized keyboard event is posted
4. **Gesture detection**: MX Master HID++ control `0x00C3` or a configured numeric button starts gesture tracking; mouse deltas accumulate until a 50px threshold triggers a directional action
5. **Device routing**: every scroll event is matched to its physical HID service; trackpad and unrelated-device events pass through untouched
6. **Scroll routing**: horizontal MX Master side-wheel events fire configured left/right actions; vertical wheel impulses become continuous pixel events that end when wheel input stops
7. **Haptic**: HID++ short report sent to the mouse via IOKit on Space-switch gestures
8. **Laser pointer**: HID++ control `0x00C4` shows a borderless NSWindow at `.screenSaver` level and restores SmartShift reporting on exit


## Requirements

- macOS 13+ (Ventura or later)
- Swift 6.0+
- Any multi-button mouse (MX Master 4 defaults built-in, haptic feedback Logitech-only)


## License

[MIT](LICENSE)
