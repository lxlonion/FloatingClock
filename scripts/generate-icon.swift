import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = size / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let rect = CGRect(x: 72, y: 72, width: 880, height: 880)
    let face = NSBezierPath(roundedRect: rect, xRadius: 192, yRadius: 192)
    NSColor(calibratedRed: 0.975, green: 0.967, blue: 0.945, alpha: 1).setFill()
    face.fill()
    let ink = NSColor(calibratedWhite: 0.17, alpha: 1)
    func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: 512 + sin(angle) * radius, y: 512 + cos(angle) * radius)
    }
    func line(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat, _ color: NSColor) {
        let path = NSBezierPath()
        path.move(to: a); path.line(to: b)
        path.lineWidth = width; path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    }
    for index in 0..<12 {
        let angle = Double(index) / 12 * 2 * .pi
        line(point(322, angle), point(350, angle), 12, ink.withAlphaComponent(0.65))
    }
    line(point(-28, 10.14 / 12 * 2 * .pi), point(204, 10.14 / 12 * 2 * .pi), 27, ink)
    line(point(-36, 8.6 / 60 * 2 * .pi), point(284, 8.6 / 60 * 2 * .pi), 18, ink)
    let accent = NSColor(calibratedRed: 0.79, green: 0.31, blue: 0.18, alpha: 1)
    line(point(-72, 36.0 / 60 * 2 * .pi), point(310, 36.0 / 60 * 2 * .pi), 7, accent)
    accent.setFill()
    NSBezierPath(ovalIn: CGRect(x: 495, y: 495, width: 34, height: 34)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let bitmap = drawIcon(size: CGFloat(size * factor))
        let suffix = factor == 2 ? "@2x" : ""
        let url = destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
