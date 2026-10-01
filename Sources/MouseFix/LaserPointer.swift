import AppKit
import CoreGraphics
import Foundation

/// Draws a colored circle overlay that follows the mouse cursor.
/// Activated by holding the scroll button (below-scroll on MX Master 4).
final class LaserPointer {
    private var window: NSWindow?
    private(set) var isVisible = false

    /// Circle diameter in points.
    private let diameter: CGFloat = 60
    /// Circle color.
    private let color = NSColor(red: 1.0, green: 0.2, blue: 0.1, alpha: 0.45)

    init() {}

    /// Create the overlay window. Must be called after NSApplication is running.
    func setup() {
        let frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false

        // Draw the circle.
        let circleView = CircleView(frame: frame, color: color)
        window.contentView = circleView

        self.window = window
    }

    func show() {
        guard let window = window else { return }
        isVisible = true

        // Position at current mouse location.
        let pos = NSEvent.mouseLocation
        centerWindow(at: pos)
        window.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
    }

    func updatePosition(event: CGEvent) {
        guard isVisible else { return }
        centerWindow(at: appKitPoint(from: event.location))
    }

    private func centerWindow(at point: NSPoint) {
        let half = diameter / 2
        window?.setFrameOrigin(NSPoint(x: point.x - half, y: point.y - half))
    }

    /// Converts global Quartz coordinates to AppKit coordinates for the
    /// display containing the pointer. Using only `NSScreen.main` breaks when
    /// the pointer is on an external display above or beside the main display.
    private func appKitPoint(from quartzPoint: CGPoint) -> NSPoint {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else {
                continue
            }

            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard displayBounds.contains(quartzPoint) else {
                continue
            }

            return NSPoint(
                x: screen.frame.minX + quartzPoint.x - displayBounds.minX,
                y: screen.frame.maxY - (quartzPoint.y - displayBounds.minY)
            )
        }

        return NSEvent.mouseLocation
    }
}

// MARK: - Circle View

private class CircleView: NSView {
    private let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        path.fill()

        // Bright border
        NSColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
