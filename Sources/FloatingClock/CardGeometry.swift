import CoreGraphics

enum CardGeometry {
    static let outerRadius: CGFloat = 32
    static let inset: CGFloat = 8
    static func innerRadius(height: CGFloat) -> CGFloat {
        min(max(0, outerRadius - inset), height / 2)
    }
}
