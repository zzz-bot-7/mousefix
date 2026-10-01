# MouseFix

MouseFix is a local macOS input remapper built for the Logitech MX Master 4.
It keeps trackpad input native while adding mouse-specific smooth scrolling,
button mappings, gestures, side-wheel navigation, and a laser overlay.

## Default Behavior

- Scroll wheel press: native middle click.
- Button `3`: `Cmd+Z`.
- Button `4`: hold Command. It combines with the physical keyboard, so holding
  the mouse button and pressing `R` sends `Cmd+R`.
- Button `5`: `Cmd+Shift+4` screenshot.
- Button `6`: tap for `Cmd+Tab`; hold and move left/right for the adjacent
  Space; hold and move up/down for Mission Control or App Expose.
- Side wheel: plain left/right arrow presses.
- Button below the scroll wheel: laser overlay while held. This uses the
  Logitech HID++ control reported as `0x00C4`.
- Main wheel: continuous, phased scrolling only for the configured Logitech
  mouse. Apple trackpad events pass through unchanged.

Button numbers can differ by mouse, connection mode, or firmware. Use discovery
mode before changing a mapping.

## Build And Install

```bash
git clone https://github.com/zzz-bot-7/mousefix.git
cd mousefix
swift build -c release --only-use-versions-from-resolved-file

mkdir -p /Applications/MouseFix.app/Contents/MacOS
cp .build/release/MouseFix /Applications/MouseFix.app/Contents/MacOS/MouseFix
```

This creates a minimal unsigned app bundle. The repository does not publish a
signed or notarized release.

Run it:

```bash
/Applications/MouseFix.app/Contents/MacOS/MouseFix
```

Run discovery mode:

```bash
/Applications/MouseFix.app/Contents/MacOS/MouseFix discover
```

## Permissions

MouseFix needs Accessibility permission or its event tap cannot start.

Open **System Settings > Privacy & Security > Accessibility**, click **+**, and
add `/Applications/MouseFix.app`. If macOS requests Input Monitoring, allow the
same app there. Permissions are tied to the app or binary path.

## Config

MouseFix reads:

```text
~/.config/mousefix/config.yaml
```

The versioned `config.example.yaml` is the portable source of truth for the
verified MX Master profile. The compiled defaults intentionally match it, so a
fresh clone works without a local config file. Copy it when you want an
editable per-machine override:

```bash
mkdir -p ~/.config/mousefix
cp config.example.yaml ~/.config/mousefix/config.yaml
```

Example:

```yaml
buttons:
  2: "MiddleClick"
  3: "Cmd+Z"
  4: "Cmd"
  5: "Cmd+Shift+4"
  6: "None"

gesture:
  button: 6
  click: "Cmd+Tab"
  hold_left: "Ctrl+Right"
  hold_right: "Ctrl+Left"
  hold_up: "MissionControl"
  hold_down: "AppExpose"

tilt_scroll:
  left: "Left"
  right: "Right"

scroll:
  enabled: true
  device: "mx master"
  response: 0.68
  speed: 1.0
```

A modifier without a key, such as `Cmd`, `Shift`, `Ctrl`, or `Opt`, remains
active until the mapped mouse button is released. Modifiers can be combined
with physical keyboard and primary mouse input.

Supported shortcut keys include `A-Z`, `0-9`, punctuation, arrow keys,
`F1-F15`, `Space`, `Tab`, `Return`, `Escape`, `Delete`, `Home`, `End`,
`PageUp`, and `PageDown`.

Scroll settings are bounded at parse time:

- `response`: `0...1`
- `speed`: `0.1...4`

## Security And Privacy

- MouseFix has no network client, telemetry, updater, login item, privileged
  helper, credential storage, or remote-control interface.
- The event tap receives key events so an active mouse-held modifier can be
  merged into them. The runtime does not inspect key codes or log, store, or
  transmit keyboard input.
- Discovery mode prints mouse button numbers and scroll metadata to stdout. It
  does not print keyboard input.
- The laser control uses temporary Logitech HID++ diversion. MouseFix reads the
  original diversion state and restores it when disabled or shut down. It does
  not write persistent firmware configuration.
- Haptic output is disabled. The program will not send a haptic report until
  verified runtime feature discovery exists. This avoids sending commands to a
  guessed HID feature index.
- The event callback returns borrowed CoreGraphics events without retaining
  them, preventing an input-rate memory leak.
- `Package.resolved` pins every Swift package dependency. CI builds only from
  that resolved file and runs with read-only repository permissions.

Treat the YAML file as trusted local configuration. Mappings trigger shortcuts
in the foreground application.

MouseFix uses two private macOS interfaces. CoreDock notifications trigger
Mission Control, App Expose, and Show Desktop. A weakly linked HID event bridge
identifies which physical device produced a scroll event. Either behavior may
change in a future macOS release. If sender identification is unavailable,
MouseFix leaves the scroll event unchanged.

## Validation

```bash
swift build --only-use-versions-from-resolved-file
swift run --only-use-versions-from-resolved-file MouseFixCoreChecks
swift test --only-use-versions-from-resolved-file
swift build -c release --only-use-versions-from-resolved-file
```

The checks cover config parsing and bounds, default mappings, device
classification, held-modifier composition, arrow-event flags, side-wheel
routing, smooth-scroll physics and output fields, and HID++ control parsing.
Accessibility permission, overlay appearance, firmware behavior, and real input
delivery still require manual testing on macOS hardware.

## Architecture

```text
Sources/MouseFix/
  main.swift                     Runtime composition, menu bar, cleanup
  EventTap.swift                 Input routing and device isolation
  ActionRunner.swift             Synthetic shortcuts and system actions
  HeldModifierController.swift   Mouse-held modifier state
  SmoothScrollEngine.swift       Scroll physics and phased event output
  InputDeviceResolver.swift      Physical device classification
  LogitechControlMonitor.swift   Temporary HID++ control diversion
  GestureEngine.swift            Hold-and-move gestures
  LaserPointer.swift             Multi-display overlay
  HapticEngine.swift             Disabled future haptic boundary

Sources/MouseFixCore/
  ButtonMap.swift                Action and mapping model
  Config.swift                   YAML parsing and defaults
  KeySynth.swift                 Shortcut parsing and keycodes
  SmoothScrollSettings.swift     Bounded scroll configuration

Sources/MouseFixHIDBridge/
  MouseFixHIDBridge.c            Weak sender-ID bridge

Tests/
  MouseFixCoreChecks/            Framework-free core checks
  MouseFixTests/                 Runtime behavior tests
```

## Requirements

- macOS 13 or newer.
- Swift 5.9 or newer.
- A multi-button mouse for remapping.

## License

Apache License 2.0. See [LICENSE](LICENSE). Attribution notices are in
[NOTICE](NOTICE).
