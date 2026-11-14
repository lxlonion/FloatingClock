import Foundation

public enum ClockAppearance: String, Codable, CaseIterable {
    case light, dark, system
}

public enum ClockStyle: String, Codable, CaseIterable {
    case minimal = "style1"
    case cardinalNumbers = "style2"
    case minuteReadout = "style3"

    public var menuTitle: String {
        switch self {
        case .minimal: return "样式一 · 极简刻度"
        case .cardinalNumbers: return "样式二 · 12 / 3 / 6 / 9"
        case .minuteReadout: return "样式三 · 中央大数字"
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
    public var faceSize: Double = 224
    public var appearance: ClockAppearance = .light
    public var style: ClockStyle = .minimal
    public var isLocked = false
    public var showsSeconds = true
    public var showsDate = true
    public var origin: StoredPoint?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case transparency, faceSize, appearance, style, isLocked, showsSeconds, showsDate, origin
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transparency = try values.decodeIfPresent(Double.self, forKey: .transparency) ?? transparency
        faceSize = try values.decodeIfPresent(Double.self, forKey: .faceSize) ?? faceSize
        appearance = try values.decodeIfPresent(ClockAppearance.self, forKey: .appearance) ?? appearance
        // Version 1.0 saved no style key. Keep every existing preference during the update.
        style = (try? values.decode(ClockStyle.self, forKey: .style)) ?? .minimal
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? isLocked
        showsSeconds = try values.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? showsSeconds
        showsDate = try values.decodeIfPresent(Bool.self, forKey: .showsDate) ?? showsDate
        origin = try values.decodeIfPresent(StoredPoint.self, forKey: .origin)
    }

    public var alpha: Double { 1 - normalized().transparency / 100 }

    public func normalized() -> Self {
        var result = self
        result.transparency = transparency.isFinite ? min(90, max(0, transparency.rounded())) : 20
        result.faceSize = faceSize.isFinite ? min(360, max(140, faceSize)) : 224
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
