import Foundation
import CoreGraphics

public struct ClockAngles {
    public let hour: Double
    public let minute: Double
    public let second: Double

    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1_000_000_000
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60
        hour = hours / 12 * 2 * .pi
        minute = minutes / 60 * 2 * .pi
        second = seconds / 60 * 2 * .pi
    }
}

public enum ClockLayout {
    public static let padding: CGFloat = 12
    public static let minimumPanelWidth: CGFloat = 284
    public static let minimumFaceSize: CGFloat = minimumPanelWidth - padding * 2
    public static let maximumFaceSize: CGFloat = 420

    public static func clampedOrigin(_ origin: CGPoint, size: CGFloat, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return origin }
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let screen = screens.max { a, b in
            let areaA = intersectionArea(frame, a)
            let areaB = intersectionArea(frame, b)
            if areaA != areaB { return areaA < areaB }
            return distanceSquared(frame.origin, a) > distanceSquared(frame.origin, b)
        }!
        return CGPoint(
            x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size)),
            y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size))
        )
    }

    public static func defaultOrigin(size: CGFloat, screen: CGRect) -> CGPoint {
        clampedOrigin(CGPoint(x: screen.maxX - size - 24, y: screen.maxY - size - 24),
                      size: size, screens: [screen])
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
