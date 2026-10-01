import AppKit
import CoreGraphics
import Foundation

let mouseFixVersion = "0.2.0"

// MARK: - CLI Argument Parsing

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "run"

switch command {
case "discover":
    runDiscover()
case "run":
    runDaemon()
case "help", "--help", "-h":
    printUsage()
case "version", "--version":
    print("mousefix \(mouseFixVersion)")
default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}

// MARK: - Commands

func printUsage() {
    print("""
    mousefix - open-source mouse button remapper for macOS

    USAGE:
      mousefix run         Start the daemon (default)
      mousefix discover    Log button numbers for all mouse events
      mousefix help        Show this help
      mousefix version     Show version

    CONFIG:
      ~/.config/mousefix/config.yaml

    PERMISSIONS:
      System Settings > Privacy & Security > Accessibility
      System Settings > Privacy & Security > Input Monitoring
    """)
}

func runDiscover() {
    print("[mousefix] Discovery mode - press mouse buttons to see their numbers")
    print("[mousefix] Press Ctrl+C to exit\n")

    let config = Config(defaultProfile: ButtonMap())
    let haptic = HapticEngine()
    let laser = LaserPointer()
    let gesture = GestureEngine(buttonMap: config.defaultProfile, hapticEngine: haptic)
    let resolver = InputDeviceResolver(targetProductName: "mx master")
    let verticalScroll = SmoothScrollEngine(settings: config.defaultProfile.smoothScroll)
    let horizontalScroll = SmoothScrollEngine(settings: config.defaultProfile.smoothScroll)
    let eventTap = EventTap(
        buttonMap: config.defaultProfile,
        gestureEngine: gesture,
        laserPointer: laser,
        deviceResolver: resolver,
        verticalScrollEngine: verticalScroll,
        horizontalScrollEngine: horizontalScroll
    )
    eventTap.discoverMode = true
    let logitechControls = LogitechControlMonitor(
        deviceNameFilter: "mx master",
        monitoredControlIDs:
            LogitechControlMonitor.gestureControlIDs
            .union([LogitechControlMonitor.smartShiftControlID])
    ) { controlID, isPressed in
        print(String(
            format: "[discover] Logitech control 0x%04X %@",
            controlID,
            isPressed ? "DOWN" : "UP"
        ))
    }
    _ = logitechControls.connect()

    guard eventTap.start() else {
        logitechControls.disconnect()
        print("[mousefix] Failed to start event tap. Check Accessibility permissions.")
        exit(1)
    }

    setupSignalHandlers {
        eventTap.stop()
        logitechControls.disconnect()
        print("\n[mousefix] Discovery mode stopped.")
        exit(0)
    }

    CFRunLoopRun()
}

func runDaemon() {
    print("[mousefix] Starting daemon...")

    let config = Config.load()
    let map = config.defaultProfile

    printMappings(map)

    let haptic = HapticEngine()
    haptic.setDeviceFilter(map.hapticDeviceName)
    let laser = LaserPointer()
    let gesture = GestureEngine(buttonMap: map, hapticEngine: haptic)
    let resolver = InputDeviceResolver(targetProductName: map.smoothScroll.deviceName)
    let verticalScroll = SmoothScrollEngine(settings: map.smoothScroll)
    let horizontalScroll = SmoothScrollEngine(settings: map.smoothScroll)
    let eventTap = EventTap(
        buttonMap: map,
        gestureEngine: gesture,
        laserPointer: laser,
        deviceResolver: resolver,
        verticalScrollEngine: verticalScroll,
        horizontalScrollEngine: horizontalScroll
    )
    var monitoredControlIDs: Set<UInt16> = [LogitechControlMonitor.smartShiftControlID]
    if map.logitechGestureEnabled {
        monitoredControlIDs.formUnion(LogitechControlMonitor.gestureControlIDs)
    }
    let logitechControls = LogitechControlMonitor(
        deviceNameFilter: map.smoothScroll.deviceName,
        monitoredControlIDs: monitoredControlIDs
    ) { controlID, isPressed in
        switch controlID {
        case LogitechControlMonitor.smartShiftControlID:
            if isPressed {
                laser.show()
            } else {
                laser.hide()
            }
        case _ where LogitechControlMonitor.gestureControlIDs.contains(controlID):
            if isPressed {
                gesture.buttonDown()
            } else {
                gesture.buttonUp()
            }
        default:
            break
        }
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    laser.setup()

    guard eventTap.start() else {
        print("[mousefix] Failed to start event tap. Check Accessibility permissions.")
        exit(1)
    }
    _ = logitechControls.connect()
    if map.gestureButton >= 0 {
        haptic.connect()
    }

    var didCleanUp = false
    let cleanup = {
        guard !didCleanUp else {
            return
        }
        didCleanUp = true
        print("\n[mousefix] Shutting down...")
        eventTap.stop()
        logitechControls.disconnect()
        haptic.disconnect()
        laser.hide()
    }

    setupSignalHandlers {
        cleanup()
        print("[mousefix] Goodbye.")
        exit(0)
    }

    // Menu bar icon
    setupMenuBar(
        eventTap: eventTap,
        logitechControls: logitechControls,
        cleanup: cleanup
    )

    print("[mousefix] Daemon running. Press Ctrl+C to stop.")
    app.run()
}

// MARK: - Menu Bar

private var statusItem: NSStatusItem?
private var eventTapRef: EventTap?
private var logitechControlsRef: LogitechControlMonitor?
private var cleanupRef: (() -> Void)?

func setupMenuBar(
    eventTap: EventTap,
    logitechControls: LogitechControlMonitor,
    cleanup: @escaping () -> Void
) {
    eventTapRef = eventTap
    logitechControlsRef = logitechControls
    cleanupRef = cleanup
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.title = "🖱"

    let menu = NSMenu()

    let toggleItem = NSMenuItem(title: "Enabled", action: #selector(MenuActions.toggle(_:)), keyEquivalent: "")
    toggleItem.target = MenuActions.shared
    toggleItem.state = .on
    menu.addItem(toggleItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: "Quit", action: #selector(MenuActions.quit(_:)), keyEquivalent: "q")
    quitItem.target = MenuActions.shared
    menu.addItem(quitItem)

    statusItem?.menu = menu
}

final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func toggle(_ sender: NSMenuItem) {
        if sender.state == .on {
            eventTapRef?.stop()
            logitechControlsRef?.disconnect()
            sender.state = .off
            statusItem?.button?.title = "🔇"
            print("[mousefix] Disabled")
        } else {
            _ = eventTapRef?.start()
            _ = logitechControlsRef?.connect()
            sender.state = .on
            statusItem?.button?.title = "🖱"
            print("[mousefix] Enabled")
        }
    }

    @objc func quit(_ sender: NSMenuItem) {
        cleanupRef?()
        print("[mousefix] Goodbye.")
        NSApp.terminate(nil)
    }
}

// MARK: - Helpers

func setupSignalHandlers(cleanup: @escaping () -> Void) {
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler { cleanup() }
    sigintSource.resume()
    signal(SIGINT, SIG_IGN)

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler { cleanup() }
    sigtermSource.resume()
    signal(SIGTERM, SIG_IGN)

    _signalSources = [sigintSource, sigtermSource]
}

var _signalSources: [Any] = []

func printMappings(_ map: ButtonMap) {
    print("[mousefix] Active mappings:")
    fflush(stdout)

    for number in map.buttons.keys.sorted() {
        let action = map.buttons[number]!
        print("  button \(number) -> \(describeAction(action))")
    }

    // Print gesture config.
    if map.gestureButton >= 0 || map.logitechGestureEnabled {
        let source = map.logitechGestureEnabled
            ? "Logitech HID++ 0x00C3"
            : "button \(map.gestureButton)"
        print("  gesture (\(source)):")
        print("    tap        -> \(describeAction(map.gestureClick))")
        print("    hold+left  -> \(describeAction(map.gestureHoldLeft))")
        print("    hold+right -> \(describeAction(map.gestureHoldRight))")
        print("    hold+up    -> \(describeAction(map.gestureHoldUp))")
        print("    hold+down  -> \(describeAction(map.gestureHoldDown))")
    }

    if map.tiltLeft != .none || map.tiltRight != .none {
        print("  side wheel:")
        print("    left  -> \(describeAction(map.tiltLeft))")
        print("    right -> \(describeAction(map.tiltRight))")
    }

    if map.smoothScroll.enabled {
        print("  smooth scroll:")
        print("    device   -> \(map.smoothScroll.deviceName)")
        print("    response -> \(map.smoothScroll.response)")
        print("    speed    -> \(map.smoothScroll.speed)")
    }
}

func describeAction(_ action: Action) -> String {
    switch action {
    case .keystroke(let mods, let key):
        var parts: [String] = []
        if mods.contains(.maskCommand) { parts.append("Cmd") }
        if mods.contains(.maskControl) { parts.append("Ctrl") }
        if mods.contains(.maskShift) { parts.append("Shift") }
        if mods.contains(.maskAlternate) { parts.append("Opt") }
        parts.append(keycodeName(key))
        return parts.joined(separator: "+")
    case .heldModifier(let modifiers):
        var parts: [String] = []
        if modifiers.contains(.maskCommand) { parts.append("HoldCmd") }
        if modifiers.contains(.maskControl) { parts.append("HoldCtrl") }
        if modifiers.contains(.maskShift) { parts.append("HoldShift") }
        if modifiers.contains(.maskAlternate) { parts.append("HoldOpt") }
        return parts.joined(separator: "+")
    case .middleClick:
        return "MiddleClick"
    case .laserPointer:
        return "LaserPointer"
    case .missionControl:
        return "MissionControl"
    case .appExpose:
        return "AppExpose"
    case .showDesktop:
        return "ShowDesktop"
    case .none:
        return "(none)"
    }
}

func keycodeName(_ code: UInt16) -> String {
    switch code {
    case 0x00: return "A"
    case 0x01: return "S"
    case 0x02: return "D"
    case 0x03: return "F"
    case 0x04: return "H"
    case 0x05: return "G"
    case 0x06: return "Z"
    case 0x07: return "X"
    case 0x08: return "C"
    case 0x09: return "V"
    case 0x0B: return "B"
    case 0x0C: return "Q"
    case 0x0D: return "W"
    case 0x0E: return "E"
    case 0x0F: return "R"
    case 0x10: return "Y"
    case 0x11: return "T"
    case 0x12: return "1"
    case 0x13: return "2"
    case 0x14: return "3"
    case 0x15: return "4"
    case 0x16: return "6"
    case 0x17: return "5"
    case 0x19: return "9"
    case 0x1A: return "7"
    case 0x1B: return "-"
    case 0x1C: return "8"
    case 0x1D: return "0"
    case 0x1E: return "]"
    case 0x1F: return "O"
    case 0x20: return "U"
    case 0x21: return "["
    case 0x22: return "I"
    case 0x23: return "P"
    case 0x24: return "Return"
    case 0x25: return "L"
    case 0x26: return "J"
    case 0x28: return "K"
    case 0x2D: return "N"
    case 0x2E: return "M"
    case 0x30: return "Tab"
    case 0x31: return "Space"
    case 0x35: return "Escape"
    case 0x7A: return "F1"
    case 0x78: return "F2"
    case 0x63: return "F3"
    case 0x76: return "F4"
    case 0x60: return "F5"
    case 0x61: return "F6"
    case 0x62: return "F7"
    case 0x64: return "F8"
    case 0x7B: return "Left"
    case 0x7C: return "Right"
    case 0x7D: return "Down"
    case 0x7E: return "Up"
    default: return "0x\(String(code, radix: 16))"
    }
}
