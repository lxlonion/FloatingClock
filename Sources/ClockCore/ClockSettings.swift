import Foundation

public enum ClockAppearance: String, Codable, CaseIterable {
    case light, dark, system
}

public enum ClockStyle: String, Codable, CaseIterable {
    case minimal = "style1"
    case cardinalNumbers = "style2"

    public var menuTitle: String {
        switch self {
        case .minimal: return "样式一 · 极简刻度"
        case .cardinalNumbers: return "样式二 · 12 / 3 / 6 / 9"
        }
    }
}

public struct StoredPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ClockSettings: Codable, Equatable {
    public var transparency: Double = 20
    public var faceSize: Double = Double(ClockLayout.minimumFaceSize)
    public var appearance: ClockAppearance = .light
    public var style: ClockStyle = .minimal
    public var showsMinuteNumerals = false
    public var minuteNumeralOpacity: Double = 40
    public var minuteNumeralSize: Double = 100
    public var isLocked = false
    public var showsSeconds = true
    public var showsDate = true
    public var timerDisplayFormat: TimerDisplayFormat = .totalMinutes
    public var selectedClockSlot: ClockSlot = .system
    public var secondClockTimeZone: ClockTimeZoneSettings = .pacific
    public var thirdClockTimeZone: ClockTimeZoneSettings = .newYork
    public var origin: StoredPoint?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case transparency, faceSize, appearance, style, showsMinuteNumerals, minuteNumeralOpacity, minuteNumeralSize
        case isLocked, showsSeconds, showsDate, timerDisplayFormat, origin
        case selectedClockSlot, secondClockTimeZone, thirdClockTimeZone
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transparency = try values.decodeIfPresent(Double.self, forKey: .transparency) ?? transparency
        faceSize = try values.decodeIfPresent(Double.self, forKey: .faceSize) ?? faceSize
        appearance = try values.decodeIfPresent(ClockAppearance.self, forKey: .appearance) ?? appearance
        let savedStyle = try values.decodeIfPresent(String.self, forKey: .style)
        style = savedStyle.flatMap(ClockStyle.init(rawValue:)) ?? .minimal
        // The removed third style becomes style one with the shared minute layer enabled.
        showsMinuteNumerals = try values.decodeIfPresent(Bool.self, forKey: .showsMinuteNumerals) ?? (savedStyle == "style3")
        minuteNumeralOpacity = try values.decodeIfPresent(Double.self, forKey: .minuteNumeralOpacity) ?? minuteNumeralOpacity
        minuteNumeralSize = try values.decodeIfPresent(Double.self, forKey: .minuteNumeralSize) ?? minuteNumeralSize
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? isLocked
        showsSeconds = try values.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? showsSeconds
        showsDate = try values.decodeIfPresent(Bool.self, forKey: .showsDate) ?? showsDate
        timerDisplayFormat = (try? values.decode(TimerDisplayFormat.self, forKey: .timerDisplayFormat)) ?? timerDisplayFormat
        selectedClockSlot = (try? values.decode(ClockSlot.self, forKey: .selectedClockSlot)) ?? selectedClockSlot
        secondClockTimeZone = (try? values.decode(ClockTimeZoneSettings.self, forKey: .secondClockTimeZone)) ?? secondClockTimeZone
        thirdClockTimeZone = (try? values.decode(ClockTimeZoneSettings.self, forKey: .thirdClockTimeZone)) ?? thirdClockTimeZone
        origin = try values.decodeIfPresent(StoredPoint.self, forKey: .origin)
    }

    public func title(for slot: ClockSlot) -> String {
        let name: String
        switch slot {
        case .system: name = "系统时区"
        case .second: name = secondClockTimeZone.displayName
        case .third: name = thirdClockTimeZone.displayName
        }
        return "\(slot.title) · \(name)"
    }

    public func menuTitle(for slot: ClockSlot, at date: Date = Date(), systemTimeZone: TimeZone = .autoupdatingCurrent) -> String {
        let zoneSettings: ClockTimeZoneSettings
        switch slot {
        case .system:
            zoneSettings = ClockTimeZoneSettings(identifier: systemTimeZone.identifier, usesDaylightSavingTime: true)
        case .second: zoneSettings = secondClockTimeZone
        case .third: zoneSettings = thirdClockTimeZone
        }
        let option = ClockTimeZoneCatalog.shared.option(for: zoneSettings, at: date)
        let name = option?.title(includingPlaceNames: false)
            ?? ClockTimeZoneCatalog.offsetTitle(zoneSettings.timeZone(at: date).secondsFromGMT(for: date))
        return "\(slot.title) · \(name)"
    }

    public func calendar(at date: Date, systemCalendar: Calendar = .autoupdatingCurrent) -> Calendar {
        var calendar = systemCalendar
        switch selectedClockSlot {
        case .system: break
        case .second: calendar.timeZone = secondClockTimeZone.timeZone(at: date)
        case .third: calendar.timeZone = thirdClockTimeZone.timeZone(at: date)
        }
        return calendar
    }

    public var backgroundAlpha: Double { 1 - normalized().transparency / 100 }
    public var contentAlpha: Double {
        let transparency = normalized().transparency
        let progress = transparency / 90
        // A quadratic compensation grows smoothly from zero to ten percentage
        // points, keeping content at 20% opacity at maximum transparency.
        return 1 - transparency / 100 + 0.1 * progress * (2 - progress)
    }
    public var minuteNumeralAlpha: Double { normalized().minuteNumeralOpacity / 100 }

    public func normalized() -> Self {
        var result = self
        result.transparency = transparency.isFinite ? min(90, max(0, transparency.rounded())) : 20
        result.faceSize = faceSize.isFinite ? min(Double(ClockLayout.maximumFaceSize), max(Double(ClockLayout.minimumFaceSize), faceSize)) : Double(ClockLayout.minimumFaceSize)
        result.minuteNumeralOpacity = minuteNumeralOpacity.isFinite ? min(100, max(0, minuteNumeralOpacity.rounded())) : 40
        result.minuteNumeralSize = minuteNumeralSize.isFinite ? min(100, max(40, minuteNumeralSize.rounded())) : 100
        result.secondClockTimeZone = secondClockTimeZone.normalized(fallback: .pacific)
        result.thirdClockTimeZone = thirdClockTimeZone.normalized(fallback: .newYork)
        if let origin, !origin.x.isFinite || !origin.y.isFinite { result.origin = nil }
        return result
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "FloatingClock.settings.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> ClockSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ClockSettings.self, from: data)
        else { return ClockSettings() }
        return settings.normalized()
    }

    public func save(_ settings: ClockSettings) {
        if let data = try? JSONEncoder().encode(settings.normalized()) {
            defaults.set(data, forKey: key)
        }
    }
}
