import CoreGraphics
import Foundation

struct SmoothScrollSettings: Equatable {
    var enabled = true
    var deviceName = "mx master"
    var response = 0.68
    var speed = 1.0
}

struct ScrollVector: Equatable {
    var x = 0.0
    var y = 0.0

    static let zero = ScrollVector()

    var hasMovement: Bool {
        abs(x) >= 0.01 || abs(y) >= 0.01
    }
}

/// Quartz stores point deltas as whole pixels even though fixed-point deltas
/// retain fractions. Carrying the remainder forward prevents slow scrolling
/// from disappearing in apps that read only the point-delta fields.
struct ScrollPointDeltaAccumulator {
    private var remainder = ScrollVector.zero

    mutating func output(for delta: ScrollVector) -> ScrollVector {
        let combined = ScrollVector(
            x: delta.x + remainder.x,
            y: delta.y + remainder.y
        )
        let output = ScrollVector(
            x: combined.x.rounded(.towardZero),
            y: combined.y.rounded(.towardZero)
        )
        remainder = ScrollVector(
            x: combined.x - output.x,
            y: combined.y - output.y
        )
        return output
    }

    mutating func reset() {
        remainder = .zero
    }
}

enum SmoothScrollPhase: Equatable {
    case touchBegan
    case touchChanged
    case touchEnded
}

struct SmoothScrollFrame: Equatable {
    let delta: ScrollVector
    let phase: SmoothScrollPhase
}

/// Deterministic scroll physics. Raw wheel impulses become one continuous
/// gesture that ends as soon as wheel input stops.
struct SmoothScrollPhysics {
    private enum State {
        case idle
        case touching
    }

    private let settings: SmoothScrollSettings
    private var state = State.idle
    private var pending = ScrollVector.zero
    private var desiredVelocity = ScrollVector.zero
    private var velocity = ScrollVector.zero
    private var lastInputTimestamp: TimeInterval?
    private var lastTickTimestamp: TimeInterval?
    private var touchHasBegun = false

    private let inputGrace: TimeInterval = 1.0 / 25.0

    init(settings: SmoothScrollSettings) {
        self.settings = settings
    }

    var isRunning: Bool {
        state != .idle || pending.hasMovement
    }

    mutating func feed(delta: ScrollVector, timestamp: TimeInterval) {
        guard delta.hasMovement else {
            return
        }

        pending.x += delta.x
        pending.y += delta.y
        lastInputTimestamp = timestamp

        if state == .idle {
            state = .touching
            touchHasBegun = false
        }

        if lastTickTimestamp == nil {
            lastTickTimestamp = timestamp
        }
    }

    mutating func advance(to timestamp: TimeInterval) -> SmoothScrollFrame? {
        guard state != .idle else {
            return nil
        }

        let previousTick = lastTickTimestamp ?? timestamp
        let dt = min(max(timestamp - previousTick, 1.0 / 240.0), 1.0 / 24.0)
        lastTickTimestamp = timestamp

        let hasPendingInput = pending.hasMovement
        if hasPendingInput {
            desiredVelocity = ScrollVector(
                x: velocityTarget(for: pending.x),
                y: velocityTarget(for: pending.y)
            )
            pending = .zero
        }

        let hasFreshInput = lastInputTimestamp.map { timestamp - $0 <= inputGrace } ?? false

        switch state {
        case .idle:
            return nil

        case .touching:
            if hasPendingInput {
                let blend = min(max((0.35 + settings.response) * dt * 60, 0), 1)
                velocity.x += (desiredVelocity.x - velocity.x) * blend
                velocity.y += (desiredVelocity.y - velocity.y) * blend

                let delta = ScrollVector(x: velocity.x * dt, y: velocity.y * dt)
                guard delta.hasMovement else {
                    return nil
                }

                let phase: SmoothScrollPhase = touchHasBegun ? .touchChanged : .touchBegan
                touchHasBegun = true
                return SmoothScrollFrame(delta: delta, phase: phase)
            }

            // Keep nearby wheel impulses in one gesture, but never generate
            // movement after the physical wheel stops producing input.
            if hasFreshInput {
                return nil
            }

            reset()
            return SmoothScrollFrame(delta: .zero, phase: .touchEnded)
        }
    }

    mutating func reset() {
        state = .idle
        pending = .zero
        desiredVelocity = .zero
        velocity = .zero
        lastInputTimestamp = nil
        lastTickTimestamp = nil
        touchHasBegun = false
    }

    private func velocityTarget(for input: Double) -> Double {
        guard input != 0 else {
            return 0
        }

        let magnitude = abs(input)
        let normalizedMagnitude = magnitude / (magnitude + 24)
        let acceleratedMagnitude = magnitude * pow(normalizedMagnitude, 0.98)
        let scale = 33 * (0.85 + settings.speed * 0.4)
        let result = acceleratedMagnitude * scale
        return input < 0 ? -result : result
    }
}

/// Owns the timer and Quartz event delivery for smoothed mouse scrolling.
final class SmoothScrollEngine {
    static let syntheticMarker: Int64 = 0x4D4F555345464958

    private let settings: SmoothScrollSettings
    private let now: () -> TimeInterval
    private let eventSink: (CGEvent) -> Void
    private var physics: SmoothScrollPhysics
    private var timer: Timer?
    private var lastFlags: CGEventFlags = []
    private var pointDeltaAccumulator = ScrollPointDeltaAccumulator()

    init(
        settings: SmoothScrollSettings,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    ) {
        self.settings = settings
        self.now = now
        self.eventSink = eventSink
        physics = SmoothScrollPhysics(settings: settings)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    /// Returns true when the original event was consumed.
    func consume(_ event: CGEvent, delta explicitDelta: ScrollVector? = nil) -> Bool {
        guard settings.enabled, !Self.isSynthetic(event) else {
            return false
        }

        let delta = explicitDelta ?? Self.pixelDelta(from: event)
        guard delta.hasMovement else {
            return false
        }

        lastFlags = event.flags
        physics.feed(delta: delta, timestamp: now())
        startTimerIfNeeded()
        return true
    }

    func tick() {
        guard let frame = physics.advance(to: now()) else {
            if !physics.isRunning {
                stopTimer()
            }
            return
        }

        post(frame)
        if !physics.isRunning {
            stopTimer()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        physics.reset()
        lastFlags = []
        pointDeltaAccumulator.reset()
    }

    static func pixelDelta(from event: CGEvent) -> ScrollVector {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        return ScrollVector(
            x: pixelDelta(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                continuous: continuous
            ),
            y: pixelDelta(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                continuous: continuous
            )
        )
    }

    private static func pixelDelta(
        line: Int64,
        fixed: Double,
        point: Double,
        continuous: Bool
    ) -> Double {
        if continuous {
            if fixed != 0 { return fixed }
            if point != 0 { return point }
            return Double(line) * 36
        }

        if line != 0 { return Double(line) * 36 }
        if point != 0 { return point * 36 }
        if fixed != 0 { return fixed * 360 }
        return 0
    }

    private func startTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func post(_ frame: SmoothScrollFrame) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let pointDelta = pointDeltaAccumulator.output(for: frame.delta)
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1,
            value: Int64(pointDelta.y)
        )
        event.setIntegerValueField(
            .scrollWheelEventFixedPtDeltaAxis1,
            value: Self.fixedLineDelta(forPixelDelta: frame.delta.y)
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2,
            value: Int64(pointDelta.x)
        )
        event.setIntegerValueField(
            .scrollWheelEventFixedPtDeltaAxis2,
            value: Self.fixedLineDelta(forPixelDelta: frame.delta.x)
        )
        event.setIntegerValueField(
            .scrollWheelEventDeltaAxis1,
            value: Self.lineDelta(forPixelDelta: frame.delta.y)
        )
        event.setIntegerValueField(
            .scrollWheelEventDeltaAxis2,
            value: Self.lineDelta(forPixelDelta: frame.delta.x)
        )

        let phases = Self.quartzPhases(for: frame.phase)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phases.scroll?.rawValue ?? 0)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(phases.momentum.rawValue)
        )
        event.flags = lastFlags
        eventSink(event)
    }

    static func lineDelta(forPixelDelta delta: Double) -> Int64 {
        guard abs(delta) >= 0.01 else {
            return 0
        }

        let truncated = Int64((delta / 10).rounded(.towardZero))
        if truncated != 0 {
            return truncated
        }
        return delta < 0 ? -1 : 1
    }

    static func fixedLineDelta(forPixelDelta delta: Double) -> Int64 {
        Int64(((delta / 10) * 65_536).rounded())
    }

    private static func quartzPhases(
        for phase: SmoothScrollPhase
    ) -> (scroll: CGScrollPhase?, momentum: CGMomentumScrollPhase) {
        switch phase {
        case .touchBegan:
            return (.began, .none)
        case .touchChanged:
            return (.changed, .none)
        case .touchEnded:
            return (.ended, .none)
        }
    }
}
