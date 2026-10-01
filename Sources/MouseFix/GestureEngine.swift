import CoreGraphics
import Foundation

/// Tracks gesture button hold + mouse movement to detect directional gestures.
///
/// While the gesture button is held:
/// - Moving left fires gestureHoldLeft
/// - Moving right fires gestureHoldRight
/// - Moving up fires gestureHoldUp
/// - Releasing with no significant movement fires gestureClick
final class GestureEngine {
    private let buttonMap: ButtonMap
    private let hapticEngine: HapticEngine

    /// Which mouse button number is the gesture button. From config.
    let gestureButtonNumber: Int64

    /// Movement threshold in pixels to trigger a directional action.
    private let threshold: Double = 50.0

    /// Accumulated movement while gesture button is held.
    private var deltaX: Double = 0
    private var deltaY: Double = 0
    private var isHeld = false
    private var hasFiredDirection = false

    init(buttonMap: ButtonMap, hapticEngine: HapticEngine) {
        self.buttonMap = buttonMap
        self.hapticEngine = hapticEngine
        self.gestureButtonNumber = buttonMap.gestureButton
    }

    /// Whether gesture mode is enabled (gesture button is configured).
    var isEnabled: Bool { gestureButtonNumber >= 0 }

    func buttonDown() {
        isHeld = true
        hasFiredDirection = false
        deltaX = 0
        deltaY = 0
    }

    func buttonUp() {
        guard isHeld else { return }
        isHeld = false

        if !hasFiredDirection {
            KeySynth.fire(buttonMap.gestureClick)
        }
    }

    func mouseMoved(event: CGEvent) {
        guard isHeld, !hasFiredDirection else { return }

        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)

        deltaX += dx
        deltaY += dy

        let absX = abs(deltaX)
        let absY = abs(deltaY)

        if absX >= threshold || absY >= threshold {
            hasFiredDirection = true

            if absX > absY {
                if deltaX < 0 {
                    KeySynth.fire(buttonMap.gestureHoldLeft)
                    hapticEngine.fireHaptic()
                } else {
                    KeySynth.fire(buttonMap.gestureHoldRight)
                    hapticEngine.fireHaptic()
                }
            } else {
                if deltaY < 0 {
                    KeySynth.fire(buttonMap.gestureHoldUp)
                } else {
                    KeySynth.fire(buttonMap.gestureHoldDown)
                }
            }
        }
    }
}
