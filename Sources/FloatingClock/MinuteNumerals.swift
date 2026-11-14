import AppKit
import CoreText

/// Comic Sans minute outlines, centered by visible ink rather than the font's line box.
enum MinuteNumerals {
    static let font = NSFont(name: "ComicSansMS", size: 100) ??
        NSFont(name: "Comic Sans MS", size: 100) ?? NSFont.systemFont(ofSize: 100)

    private static let outlines: [String: (path: CGPath, radius: CGFloat)] = {
        let font = Self.font as CTFont
        var result: [String: (path: CGPath, radius: CGFloat)] = [:]
        for minute in 0..<60 {
            let text = String(format: "%02d", minute)
            let characters = Array(text.utf16)
            let count = characters.count
            var glyphs = [CGGlyph](repeating: 0, count: count)
            guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, count) else { continue }
            var advances = [CGSize](repeating: .zero, count: count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, count)
            let path = CGMutablePath()
            var x: CGFloat = 0
            for index in 0..<count {
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: x, y: 0))
                }
                x += advances[index].width
            }
            result[text] = (path, containingRadius(of: path))
        }
        return result
    }()

    private static func containingRadius(of path: CGPath) -> CGFloat {
        let bounds = path.boundingBoxOfPath
        var radius: CGFloat = 0
        path.applyWithBlock { element in
            let value = element.pointee
            let count: Int
            switch value.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for index in 0..<count {
                let point = value.points[index]
                radius = max(radius, hypot(point.x - bounds.midX, point.y - bounds.midY))
            }
        }
        return radius
    }

    static func path(for minute: String, in card: CGRect, size: Double = 100) -> CGPath? {
        guard let shape = outlines[minute], shape.radius > 0 else { return nil }
        let outline = shape.path
        let bounds = outline.boundingBoxOfPath
        let scale = card.width / 224
        // The major ticks begin at outerRadius - 9; leave a small gap inside them.
        let availableRadius = card.width * 0.402 - 14 * scale
        let factor = availableRadius / shape.radius * CGFloat(size / 100)
        var transform = CGAffineTransform(a: factor, b: 0, c: 0, d: factor,
                                         tx: card.midX - bounds.midX * factor,
                                         ty: card.midY - bounds.midY * factor)
        return outline.copy(using: &transform)
    }
}
