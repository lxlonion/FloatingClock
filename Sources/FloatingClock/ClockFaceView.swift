import AppKit
import ClockCore
import CoreText

private final class DialDrawingView: NSView {
    weak var face: ClockFaceView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func draw(_ dirtyRect: NSRect) { face?.drawDial(dirtyRect) }
}

private final class CardBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

final class ClockFaceView: NSView {
    var settings = ClockSettings() { didSet { updateCard(); invalidateDial(); window?.invalidateCursorRects(for: self) } }
    var fixedDate: Date? { didSet { invalidateDial() } }
    var onDragMoved: ((CGRect) -> Void)?
    var onDragFinished: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var dialFrame: CGRect? { didSet { invalidateDial() } }
    var dialCard: CGRect { (dialFrame ?? bounds).insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding) }
    var cardCornerRadius: CGFloat { min(CardGeometry.outerRadius, max(0, min(bounds.width, bounds.height) / 2 - ClockLayout.padding)) }
    var quickAccessCorner: ClockCorner? { didSet { if oldValue != quickAccessCorner { invalidateDial() } } }
    private var minutePathCache: (minute: String, card: CGRect, size: Double, path: CGPath)?
    private var hoverTracking: NSTrackingArea?
    private var dragStart: (pointer: CGPoint, dial: CGRect)?
    private let background = CardBackgroundView()
    private let drawing = DialDrawingView()
    var cardLayer: CALayer? { background.layer }

    // Keep callers of NSView's public invalidation API working as well as the
    // explicit dial invalidation below. Do not read NSView's getter after set:
    // this non-drawing parent may already report false.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { invalidateDial() }
        }
    }

    func invalidateDial() { drawing.needsDisplay = true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.wantsLayer = true
        background.setAccessibilityElement(false)
        drawing.setAccessibilityElement(false)
        drawing.face = self
        addSubview(background)
        addSubview(drawing)
        updateCard()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
        drawing.frame = bounds
        updateCard()
        CATransaction.commit()
        invalidateDial()
    }

    // AppKit's view cache includes the drawn dial and native controls, but not
    // a layer's background. Composite the very same live layer underneath it.
    override func cacheDisplay(in rect: NSRect, to bitmap: NSBitmapImageRep) {
        layoutSubtreeIfNeeded()
        super.cacheDisplay(in: rect, to: bitmap)
        guard let content = bitmap.cgImage, let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext,
              let layer = background.layer, rect.width > 0, rect.height > 0 else { return }
        let targetSpace = bitmap.colorSpace.cgColorSpace
        let colorSpace = targetSpace?.numberOfComponents == 3 ? targetSpace! : CGColorSpaceCreateDeviceRGB()
        guard let group = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        group.scaleBy(x: CGFloat(bitmap.pixelsWide) / rect.width, y: CGFloat(bitmap.pixelsHigh) / rect.height)
        group.translateBy(x: background.frame.minX - rect.minX, y: background.frame.minY - rect.minY)
        // render(in:) applies the receiver opacity to individual primitives.
        // Render its opaque form, then restore it before committing this
        // non-animated transaction so the live window never changes opacity.
        let opacity = layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.render(in: group)
        layer.opacity = opacity
        CATransaction.commit()
        guard let backgroundImage = group.makeImage() else { return }
        context.saveGState()
        context.clear(CGRect(origin: .zero, size: rect.size))
        context.saveGState()
        // Apply the original opacity once to the complete shadow and fill.
        context.setAlpha(CGFloat(opacity))
        context.draw(backgroundImage, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.draw(content, in: rect)
        context.restoreGState()
    }

    private func updateCard() {
        guard let layer = background.layer else { return }
        let palette = ClockPalette(settings.appearance, effectiveAppearance: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerCurve = .continuous
        layer.cornerRadius = cardCornerRadius
        layer.backgroundColor = palette.face.cgColor
        layer.borderWidth = 1
        layer.borderColor = (palette.dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.white.withAlphaComponent(0.8)).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = palette.dark ? 0.22 : 0.11
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.opacity = Float(settings.backgroundAlpha / settings.contentAlpha)
        CATransaction.commit()
    }

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

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateCard(); invalidateDial() }

    fileprivate func drawDial(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let card = dialCard
        let scale = card.width / 224
        let center = CGPoint(x: card.midX, y: card.midY)
        let palette = ClockPalette(settings.appearance, effectiveAppearance: effectiveAppearance)
        let ink = palette.ink
        let accent = palette.accent

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
        let calendar = settings.calendar(at: now)
        let readout = ClockReadout(date: now, calendar: calendar)
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

        let angles = ClockAngles(date: now, calendar: calendar)
        let halo = Self.haloStrength(settings: settings)
        if halo > 0 {
            let color = palette.face.withAlphaComponent(halo)
            stroke(from: point(center, -8 * scale, angles.hour), to: point(center, 53 * scale, angles.hour), width: 9 * scale, color: color)
            stroke(from: point(center, -10 * scale, angles.minute), to: point(center, 77 * scale, angles.minute), width: 7 * scale, color: color)
            if settings.showsSeconds {
                stroke(from: point(center, -19 * scale, angles.second), to: point(center, 82 * scale, angles.second), width: 4.5 * scale, color: color)
            }
        }
        stroke(from: point(center, -8 * scale, angles.hour), to: point(center, 53 * scale, angles.hour), width: 6 * scale, color: ink)
        stroke(from: point(center, -10 * scale, angles.minute), to: point(center, 77 * scale, angles.minute), width: 4 * scale, color: ink)
        if settings.showsSeconds {
            stroke(from: point(center, -19 * scale, angles.second), to: point(center, 82 * scale, angles.second), width: 1.5 * scale, color: accent)
        }
        let hubRadius: CGFloat = (settings.showsSeconds ? 4 : 3.5) * scale
        (settings.showsSeconds ? accent : ink).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: 2 * hubRadius, height: 2 * hubRadius)).fill()
    }

    static func haloStrength(settings: ClockSettings) -> CGFloat {
        guard settings.showsMinuteNumerals else { return 0 }
        return CGFloat(max(0, min(1, (settings.minuteNumeralAlpha - 0.6) / 0.4)))
    }

    static func cardinalPath(_ text: String, at center: CGPoint, font: NSFont) -> CGPath? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<count {
                if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
                }
            }
        }
        let bounds = path.boundingBoxOfPath
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        var transform = CGAffineTransform(translationX: center.x - bounds.midX, y: center.y - bounds.midY)
        return path.copy(using: &transform)
    }

    private func drawCentered(_ text: String, at center: CGPoint, font: NSFont, color: NSColor) {
        guard let path = Self.cardinalPath(text, at: center, font: font), let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
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
