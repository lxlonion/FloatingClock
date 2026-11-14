import CoreGraphics

public enum ClockCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

public enum QuickAccessLayout {
    /// Choose the side away from the nearest screen edge, keeping the vertical half.
    public static func corner(for clock: CGRect, on screen: CGRect) -> ClockCorner {
        let clockIsLeft = clock.midX < screen.midX
        let clockIsBottom = clock.midY < screen.midY
        if clockIsBottom { return clockIsLeft ? .bottomRight : .bottomLeft }
        return clockIsLeft ? .topRight : .topLeft
    }

    public static func buttonFrame(in card: CGRect, corner: ClockCorner) -> CGRect {
        let scale = card.width / 224
        let side = max(18, 20 * scale)
        let x = corner.isLeft ? card.minX + 30 * scale : card.maxX - 30 * scale
        let y = corner.isBottom ? card.minY + 23 * scale : card.maxY - 23 * scale
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }
}
