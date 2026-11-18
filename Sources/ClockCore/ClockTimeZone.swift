import Foundation

public enum ClockSlot: String, Codable, CaseIterable {
    case system, second, third

    public var title: String {
        switch self {
        case .system: return "槽位 1"
        case .second: return "槽位 2"
        case .third: return "槽位 3"
        }
    }
}

public struct ClockTimeZoneSettings: Codable, Equatable {
    public var identifier: String
    public var usesDaylightSavingTime: Bool

    public static let pacific = Self(identifier: "America/Los_Angeles", usesDaylightSavingTime: false)
    public static let newYork = Self(identifier: "America/New_York", usesDaylightSavingTime: true)

    public init(identifier: String, usesDaylightSavingTime: Bool) {
        self.identifier = identifier
        self.usesDaylightSavingTime = usesDaylightSavingTime
    }

    public func normalized(fallback: Self) -> Self {
        var result = self
        if TimeZone(identifier: identifier) == nil { result.identifier = fallback.identifier }
        return result
    }

    public func timeZone(at date: Date) -> TimeZone {
        let zone = TimeZone(identifier: identifier) ?? TimeZone(identifier: Self.pacific.identifier)!
        guard !usesDaylightSavingTime else { return zone }
        // Remove the actual regional DST adjustment, not a hard-coded hour:
        // some regions use a half-hour adjustment or negative winter DST.
        let standardOffset = zone.secondsFromGMT(for: date) - Int(zone.daylightSavingTimeOffset(for: date))
        return TimeZone(secondsFromGMT: standardOffset) ?? zone
    }

    public var displayName: String {
        if usesDaylightSavingTime, let option = ClockTimeZoneCatalog.shared.option(for: identifier), option.hasDaylightSavingTime {
            return option.title
        }
        let zone = timeZone(at: Date())
        return "\(ClockTimeZoneCatalog.offsetTitle(zone.secondsFromGMT())) · 标准时间"
    }

    public static func selectionTitle(for identifier: String) -> String {
        ClockTimeZoneCatalog.shared.option(for: identifier)?.title ?? identifier
    }
}
