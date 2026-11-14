import AppKit
import ClockCore

final class ClockFaceView: NSView {
    var settings = ClockSettings() { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var fixedDate: Date?
    var onDragFinished: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日  EEE"
        return formatter
    }()

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if !settings.isLocked { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !settings.isLocked else { return }
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
        onDragFinished?()
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let card = bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
        let scale = card.width / 224
        let center = CGPoint(x: card.midX, y: card.midY)
        let dark = settings.appearance == .dark ||
            (settings.appearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let face = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedRed: 0.975, green: 0.967, blue: 0.945, alpha: 1)
        let ink = dark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.17, alpha: 1)
        let accent = dark ? NSColor(calibratedRed: 1, green: 0.53, blue: 0.35, alpha: 1) : NSColor(calibratedRed: 0.79, green: 0.31, blue: 0.18, alpha: 1)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 38 * scale, yRadius: 38 * scale)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.25 : 0.13)
        shadow.shadowBlurRadius = 9 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -3 * scale)
        shadow.set()
        face.setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.white.withAlphaComponent(0.8)).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        for index in 0..<60 {
            let major = index % 5 == 0
            let angle = Double(index) / 60 * 2 * .pi
            let radius = card.width * 0.402
            stroke(from: point(center, radius - (major ? 9 : 3) * scale, angle),
                   to: point(center, radius, angle),
                   width: (major ? 2.4 : 1.1) * scale,
                   color: ink.withAlphaComponent(major ? 0.72 : 0.19))
        }

        let now = fixedDate ?? Date()
        if settings.showsDate {
            dateFormatter.timeZone = .current
            let text = dateFormatter.string(from: now)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10 * scale, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.46),
                .kern: 0.4 * scale
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - 43 * scale - size.height / 2), withAttributes: attributes)
        }

        let angles = ClockAngles(date: now)
        stroke(from: point(center, -8 * scale, angles.hour), to: point(center, 53 * scale, angles.hour), width: 6 * scale, color: ink)
        stroke(from: point(center, -10 * scale, angles.minute), to: point(center, 77 * scale, angles.minute), width: 4 * scale, color: ink)
        if settings.showsSeconds {
            stroke(from: point(center, -19 * scale, angles.second), to: point(center, 82 * scale, angles.second), width: 1.5 * scale, color: accent)
        }
        let hubRadius: CGFloat = (settings.showsSeconds ? 4 : 3.5) * scale
        (settings.showsSeconds ? accent : ink).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: 2 * hubRadius, height: 2 * hubRadius)).fill()
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
    }

    private func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}
