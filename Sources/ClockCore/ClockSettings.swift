import Foundation

public enum ClockAppearance: String, Codable, CaseIterable {
    case light, dark, system
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
    public var isLocked = false
    public var showsSeconds = true
    public var showsDate = true
    public var origin: StoredPoint?

    public init() {}

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
