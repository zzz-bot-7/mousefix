import AppKit
import CoreGraphics
@testable import MouseFix
import Testing

@Suite
struct ConfigParsingTests {
    @Test
    func parsesHeldModifiersAndDeviceScopedScrollSettings() {
        let config = Config.parse(yaml: """
        buttons:
          4: "Cmd"
          5: "Cmd+Shift+4"
          6: "Shift"
          7: "LaserPointer"
        gesture:
          button: -1
          logitech_control: true
        tilt_scroll:
          left: "Left"
          right: "Right"
        scroll:
          enabled: true
          device: "MX Master 4"
          response: 0.7
          speed: 1.2
        """)

        let map = config.defaultProfile
        #expect(map.buttons[4] == .heldModifier(.maskCommand))
        #expect(map.buttons[6] == .heldModifier(.maskShift))
        #expect(map.gestureButton == -1)
        #expect(map.logitechGestureEnabled)
        #expect(map.tiltLeft == Action.parse("Left"))
        #expect(map.tiltRight == Action.parse("Right"))
        #expect(map.smoothScroll.deviceName == "MX Master 4")
        #expect(map.smoothScroll.response == 0.7)
        #expect(map.smoothScroll.speed == 1.2)
    }
}

@Suite
struct SideScrollCommandTests {
    @Test
    func routesOnlyDominantHorizontalMouseDeltas() throws {
        var map = Config.mxMasterDefaults()
        map.tiltLeft = Action.parse("Left")
        map.tiltRight = Action.parse("Right")

        let left = try #require(
            SideScrollCommand.resolve(
                delta: ScrollVector(x: -72, y: 0),
                buttonMap: map
            )
        )
        #expect(left.action == Action.parse("Left"))
        #expect(left.repeatCount == 2)

        let right = try #require(
            SideScrollCommand.resolve(
                delta: ScrollVector(x: 36, y: 0),
                buttonMap: map
            )
        )
        #expect(right.action == Action.parse("Right"))
        #expect(right.repeatCount == 1)
        #expect(
            SideScrollCommand.resolve(
                delta: ScrollVector(x: 1, y: 36),
                buttonMap: map
            ) == nil
        )
    }

    @Test
    func nativeSideScrollDoesNotCreateAKeyCommand() {
        var map = Config.mxMasterDefaults()
        map.tiltLeft = .none
        map.tiltRight = .none

        #expect(
            SideScrollCommand.resolve(
                delta: ScrollVector(x: 36, y: 0),
                buttonMap: map
            ) == nil
        )
    }
}

@Suite
struct InputDeviceDescriptorTests {
    @Test
    func classifiesOnlyConfiguredLogitechMouseAsTarget() {
        let mouse = InputDeviceDescriptor(
            registryID: 1,
            product: "MX Master 4",
            vendorID: 0x046D,
            productID: 0xB042,
            transport: "Bluetooth Low Energy"
        )
        let trackpad = InputDeviceDescriptor(
            registryID: 2,
            product: "Apple Internal Keyboard / Trackpad",
            vendorID: 0x05AC,
            productID: 0x0281,
            transport: "SPI"
        )

        #expect(mouse.kind(targetVendorID: 0x046D, targetProductName: "mx master") == .targetMouse)
        #expect(trackpad.kind(targetVendorID: 0x046D, targetProductName: "mx master") == .appleTrackpad)
    }
}

@Suite
struct HeldModifierControllerTests {
    @Test
    func releasingOneMouseButtonPreservesTheOtherHeldModifier() {
        var events: [CGEvent] = []
        let controller = HeldModifierController { event in
            events.append(event.copy() ?? event)
        }

        controller.press(button: 4, modifiers: .maskCommand)
        controller.press(button: 6, modifiers: .maskShift)
        #expect(controller.activeFlags.contains(.maskCommand))
        #expect(controller.activeFlags.contains(.maskShift))

        controller.release(button: 4)
        #expect(!controller.activeFlags.contains(.maskCommand))
        #expect(controller.activeFlags.contains(.maskShift))

        controller.releaseAll()
        #expect(controller.activeFlags.isEmpty)
        #expect(events.count == 4)
        #expect(events.allSatisfy { $0.type == .flagsChanged })
    }

    @Test
    func appliesMouseHeldModifiersToPhysicalKeyboardEvents() throws {
        let controller = HeldModifierController { _ in }
        controller.press(button: 4, modifiers: .maskCommand)

        let physicalR = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x0F,
            keyDown: true
        ))
        physicalR.flags = .maskShift
        controller.applyActiveFlags(to: physicalR)

        #expect(physicalR.flags.contains(.maskCommand))
        #expect(physicalR.flags.contains(.maskShift))

        controller.release(button: 4)
        let nextKey = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x00,
            keyDown: true
        ))
        controller.applyActiveFlags(to: nextKey)
        #expect(!nextKey.flags.contains(.maskCommand))
    }
}

@Suite
struct KeySynthTests {
    @Test
    func arrowKeysDoNotCarryTheFunctionModifier() {
        let flags = KeySynth.effectiveFlags(for: 0x7B, baseFlags: [])

        #expect(flags.contains(.maskNumericPad))
        #expect(!flags.contains(.maskSecondaryFn))
    }

    @Test
    func modifiedArrowsCarryTheFunctionNavigationModifier() {
        let flags = KeySynth.effectiveFlags(
            for: 0x7C,
            baseFlags: .maskControl
        )

        #expect(flags.contains(.maskControl))
        #expect(flags.contains(.maskNumericPad))
        #expect(flags.contains(.maskSecondaryFn))
    }
}

@Suite
struct SmoothScrollPhysicsTests {
    @Test
    func stopsAfterWheelInputEndsWithoutMomentum() {
        var physics = SmoothScrollPhysics(settings: SmoothScrollSettings())
        physics.feed(delta: ScrollVector(x: 12, y: 0), timestamp: 0)

        let began = physics.advance(to: 1.0 / 120.0)
        #expect(began?.phase == .touchBegan)
        #expect(abs(began?.delta.x ?? 0) > 0)

        #expect(physics.advance(to: 0.02) == nil)
        #expect(physics.isRunning)

        let ended = physics.advance(to: 0.1)
        #expect(ended?.phase == .touchEnded)
        #expect(!physics.isRunning)
        #expect(physics.advance(to: 0.1 + 1.0 / 120.0) == nil)
    }

    @Test
    func convertsDiscreteLinesAndContinuousPointsToPixels() throws {
        let lineEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: -1,
            wheel3: 0
        ))
        #expect(SmoothScrollEngine.pixelDelta(from: lineEvent) == ScrollVector(x: -36, y: 36))

        let continuousEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ))
        continuousEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        continuousEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 3)
        continuousEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -2)
        continuousEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3.5)
        continuousEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2.25)

        #expect(SmoothScrollEngine.pixelDelta(from: continuousEvent) == ScrollVector(x: -2.25, y: 3.5))
    }

    @Test
    func carriesFractionalPointDeltasAcrossFrames() {
        var accumulator = ScrollPointDeltaAccumulator()

        #expect(accumulator.output(for: ScrollVector(x: 0.4, y: -0.6)) == .zero)
        #expect(accumulator.output(for: ScrollVector(x: 0.4, y: -0.6)) == ScrollVector(x: 0, y: -1))
        #expect(accumulator.output(for: ScrollVector(x: 0.4, y: -0.6)) == ScrollVector(x: 1, y: 0))
    }

    @Test
    func postsContinuousScrollThatEndsWithoutMomentum() throws {
        var timestamp = 0.0
        var output: [CGEvent] = []
        let engine = SmoothScrollEngine(
            settings: SmoothScrollSettings(),
            now: { timestamp },
            eventSink: { output.append($0.copy() ?? $0) }
        )
        let input = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))

        #expect(engine.consume(input))
        timestamp = 1.0 / 120.0
        engine.tick()
        timestamp = 0.02
        engine.tick()
        #expect(output.count == 1)
        timestamp = 0.1
        engine.tick()
        timestamp = 0.2
        engine.tick()

        #expect(output.count == 2)
        let began = try #require(output.first)
        let ended = try #require(output.last)
        #expect(SmoothScrollEngine.isSynthetic(began))
        #expect(began.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(began.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.began.rawValue))
        #expect(ended.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.ended.rawValue))
        #expect(output.allSatisfy {
            $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
        })
    }

    @Test
    func postsHorizontalScrollUsingIntegerAndFixedPointAxisFields() throws {
        var timestamp = 0.0
        var output: [CGEvent] = []
        let engine = SmoothScrollEngine(
            settings: SmoothScrollSettings(),
            now: { timestamp },
            eventSink: { output.append($0.copy() ?? $0) }
        )
        let input = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 1,
            wheel3: 0
        ))

        #expect(
            engine.consume(
                input,
                delta: ScrollVector(x: 36, y: 0)
            )
        )
        timestamp = 1.0 / 120.0
        engine.tick()
        engine.stop()

        let event = try #require(output.first)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0)
        #expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2) != 0)

        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(appKitEvent.hasPreciseScrollingDeltas)
        #expect(appKitEvent.scrollingDeltaX != 0)
        #expect(appKitEvent.scrollingDeltaY == 0)
    }

    @Test
    func encodesPixelDeltasAsSixteenSixteenFixedPointLines() {
        #expect(SmoothScrollEngine.lineDelta(forPixelDelta: 4) == 1)
        #expect(SmoothScrollEngine.lineDelta(forPixelDelta: -25) == -2)
        #expect(SmoothScrollEngine.fixedLineDelta(forPixelDelta: 10) == 65_536)
        #expect(SmoothScrollEngine.fixedLineDelta(forPixelDelta: -5) == -32_768)
    }
}

@Suite
struct LogitechControlReportTests {
    @Test
    func parsesActiveHIDPPControlIDs() {
        let report: [UInt8] = [
            0x11, 0x00, 0x09, 0x00,
            0x00, 0xC4,
            0x00, 0xD0,
            0x00, 0x00,
        ]

        #expect(
            LogitechControlMonitor.parseActiveControls(from: report)
                == [0x00C4, 0x00D0]
        )
        #expect(LogitechControlMonitor.parseActiveControls(from: [0x11, 0x00]).isEmpty)
    }
}
