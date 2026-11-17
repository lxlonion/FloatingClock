import AppKit
import ClockCore

final class ClockFaceView: NSView {
    var settings = ClockSettings() { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var fixedDate: Date?
    var onDragMoved: ((CGRect) -> Void)?
    var onDragFinished: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var dialFrame: CGRect? { didSet { needsDisplay = true } }
    var dialCard: CGRect { (dialFrame ?? bounds).insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding) }
    var cardCornerRadius: CGFloat { min(32, max(0, min(bounds.width, bounds.height) / 2 - ClockLayout.padding)) }
    var quickAccessCorner: ClockCorner? { didSet { if oldValue != quickAccessCorner { needsDisplay = true } } }
    private var minutePathCache: (minute: String, card: CGRect, size: Double, path: CGPath)?
    private var hoverTracking: NSTrackingArea?
    private var dragStart: (pointer: CGPoint, dial: CGRect)?

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func resetCursorRects() {
        if !settings.isLocked { addCursorRect(dialFrame ?? bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !settings.isLocked else { return }
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        let location = convert(event.locationInWindow, from: nil)
        guard let window, (dialFrame ?? bounds).contains(location), hitTest(location) === self else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow),
                     window.convertToScreen(convert(dialFrame ?? bounds, to: nil)))
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !settings.isLocked, let window, let dragStart else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        // Anchor to the dial, since moving the timer tray changes the window's
        // origin underneath an ongoing drag.
        onDragMoved?(dragStart.dial.offsetBy(dx: pointer.x - dragStart.pointer.x, dy: pointer.y - dragStart.pointer.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        NSCursor.pop()
        onDragFinished?()
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let card = dialCard
        let scale = card.width / 224
        let center = CGPoint(x: card.midX, y: card.midY)
        let palette = ClockPalette(settings.appearance, effectiveAppearance: effectiveAppearance)
        let dark = palette.dark
        let face = palette.face
        let ink = palette.ink
        let accent = palette.accent
        let backgroundCard = bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
        let radius = cardCornerRadius
        let cardPath = NSBezierPath(roundedRect: backgroundCard, xRadius: radius, yRadius: radius)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(settings.backgroundAlpha / settings.contentAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (blur, offset, opacity) in [(5.0, -1.0, dark ? 0.16 : 0.08), (2.0, -1.0, dark ? 0.12 : 0.06)] {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
            shadow.shadowBlurRadius = blur
            shadow.shadowOffset = NSSize(width: 0, height: offset)
            shadow.set()
            face.setFill()
            cardPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        (dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.white.withAlphaComponent(0.8)).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
        context.endTransparencyLayer()
        context.restoreGState()

        for index in 0..<60 {
            if settings.style == .cardinalNumbers && [0, 1, 14].contains(index % 15) { continue }
            let major = index % 5 == 0
            let angle = Double(index) / 60 * 2 * .pi
            let radius = card.width * 0.402
            stroke(from: point(center, radius - (major ? 9 : 3) * scale, angle),
                   to: point(center, radius, angle),
                   width: (major ? 2.4 : 1.1) * scale,
                   color: ink.withAlphaComponent(major ? 0.72 : 0.19))
        }

        if settings.style == .cardinalNumbers {
            for (number, index) in [("12", 0), ("3", 15), ("6", 30), ("9", 45)] {
                drawCentered(number, at: point(center, card.width * 0.393, Double(index) / 60 * 2 * .pi),
                             font: .systemFont(ofSize: 18 * scale, weight: .regular), color: ink.withAlphaComponent(0.82))
            }
        }

        let now = fixedDate ?? Date()
        let readout = ClockReadout(date: now)
        if settings.showsDate {
            let baseline = card.minY + 16 * scale
            let color = ink.withAlphaComponent(0.54)
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .medium), .foregroundColor: color
            ]
            let weekdayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10 * scale, weight: .medium), .foregroundColor: color
            ]
            if quickAccessCorner != .bottomLeft {
                readout.day.draw(at: CGPoint(x: card.minX + 23 * scale, y: baseline), withAttributes: dayAttributes)
            }
            let weekdaySize = readout.weekday.size(withAttributes: weekdayAttributes)
            if quickAccessCorner != .bottomRight {
                readout.weekday.draw(at: CGPoint(x: card.maxX - 23 * scale - weekdaySize.width, y: baseline), withAttributes: weekdayAttributes)
            }
        }

        if settings.showsMinuteNumerals {
            if minutePathCache?.minute != readout.minute || minutePathCache?.card != card ||
                minutePathCache?.size != settings.minuteNumeralSize {
                minutePathCache = MinuteNumerals.path(for: readout.minute, in: card, size: settings.minuteNumeralSize)
                    .map { (readout.minute, card, settings.minuteNumeralSize, $0) }
            }
            if let path = minutePathCache?.path, let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(ink.withAlphaComponent(settings.minuteNumeralAlpha).cgColor)
                context.addPath(path)
                context.fillPath()
            }
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

    private func drawCentered(_ text: String, at center: CGPoint, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
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
