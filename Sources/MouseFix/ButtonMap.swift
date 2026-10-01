import CoreGraphics
import Foundation

/// Actions that can be triggered by a button or gesture.
enum Action {
    case keystroke(modifiers: CGEventFlags, keyCode: UInt16)
    case heldModifier(CGEventFlags)
    case middleClick
    case laserPointer
    case missionControl
    case appExpose
    case showDesktop
    case none

    /// Parse an action string like "Cmd+Z", "MiddleClick", "LaserPointer".
    static func parse(_ string: String) -> Action {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Cmd", "Command":
            return .heldModifier(.maskCommand)
        case "Shift":
            return .heldModifier(.maskShift)
        case "Ctrl", "Control":
            return .heldModifier(.maskControl)
        case "Opt", "Option", "Alt":
            return .heldModifier(.maskAlternate)
        case "MiddleClick":
            return .middleClick
        case "LaserPointer":
            return .laserPointer
        case "MissionControl":
            return .missionControl
        case "AppExpose":
            return .appExpose
        case "ShowDesktop":
            return .showDesktop
        case "None", "":
            return .none
        default:
            return KeySynth.parseActionString(string)
        }
    }
}

extension Action: Equatable {
    static func == (lhs: Action, rhs: Action) -> Bool {
        switch (lhs, rhs) {
        case (.keystroke(let m1, let k1), .keystroke(let m2, let k2)):
            return m1.rawValue == m2.rawValue && k1 == k2
        case (.heldModifier(let m1), .heldModifier(let m2)):
            return m1.rawValue == m2.rawValue
        case (.middleClick, .middleClick),
             (.laserPointer, .laserPointer),
             (.missionControl, .missionControl),
             (.appExpose, .appExpose),
             (.showDesktop, .showDesktop),
             (.none, .none):
            return true
        default:
            return false
        }
    }
}

/// Maps macOS button numbers to actions.
/// Users define their own number->action pairs via config, so any mouse works.
struct ButtonMap {
    /// Button number -> action. User populates this from `mousefix discover` output.
    var buttons: [Int64: Action] = [:]

    /// Gesture engine config (hold button + move mouse).
    var gestureButton: Int64 = -1  // -1 = disabled
    var logitechGestureEnabled = false
    var gestureClick: Action = .none
    var gestureHoldLeft: Action = .none
    var gestureHoldRight: Action = .none
    var gestureHoldUp: Action = .none
    var gestureHoldDown: Action = .none

    /// Side-wheel actions.
    var tiltLeft: Action = .none
    var tiltRight: Action = .none

    /// Haptic device name filter (substring match). Default matches any MX Master.
    var hapticDeviceName: String = "mx master"

    /// Device-scoped smooth scrolling.
    var smoothScroll = SmoothScrollSettings()

    /// Look up the action for a given mouse button number.
    func action(forButton number: Int64) -> Action? {
        return buttons[number]
    }
}
