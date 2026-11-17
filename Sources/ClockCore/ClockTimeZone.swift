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
        switch identifier {
        case "America/Los_Angeles": return usesDaylightSavingTime ? "太平洋时间" : "太平洋标准时间"
        case "America/New_York": return usesDaylightSavingTime ? "纽约时间" : "纽约标准时间"
        default: return Self.selectionTitle(for: identifier)
        }
    }

    public static func selectionTitle(for identifier: String) -> String {
        let name: String?
        switch identifier {
        case "America/Los_Angeles": name = "太平洋时间（洛杉矶）"
        case "America/New_York": name = "纽约时间"
        default: name = TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: Locale(identifier: "zh_Hans_CN"))
        }
        return name.map { "\($0) · \(identifier)" } ?? identifier
    }
}
