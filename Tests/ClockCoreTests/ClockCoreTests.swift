import XCTest
import CoreGraphics
@testable import ClockCore

final class ClockCoreTests: XCTestCase {
    func testHandsIncludeFractionalTimeAndTwelveHourWrap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15, minute: 15, second: 30))!
        let angles = ClockAngles(date: date, calendar: calendar)
        XCTAssertEqual(angles.hour * 180 / .pi, 97.75, accuracy: 0.0001)
        XCTAssertEqual(angles.minute * 180 / .pi, 93, accuracy: 0.0001)
        XCTAssertEqual(angles.second * 180 / .pi, 180, accuracy: 0.0001)
    }

    func testTransparencyCannotMakeClockDisappear() {
        var settings = ClockSettings()
        settings.transparency = 100
        settings.faceSize = -1
        XCTAssertEqual(settings.normalized().transparency, 90)
        XCTAssertEqual(settings.alpha, 0.1, accuracy: 0.0001)
        XCTAssertEqual(settings.normalized().faceSize, 140)
        settings.transparency = .nan
        settings.origin = StoredPoint(x: .infinity, y: 10)
        XCTAssertEqual(settings.normalized().transparency, 20)
        XCTAssertNil(settings.normalized().origin)
    }

    func testSettingsSurviveRelaunchAndMalformedDataFallsBack() {
        let suite = "FloatingClock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ClockSettings()
        settings.transparency = 63
        settings.isLocked = true
        settings.faceSize = 284
        settings.appearance = .dark
        settings.showsSeconds = false
        settings.showsDate = false
        settings.origin = StoredPoint(x: -1000, y: 80)
        SettingsStore(defaults: defaults).save(settings)
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings)
        defaults.set(Data("invalid".utf8), forKey: "FloatingClock.settings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), ClockSettings())
    }

    func testNegativeCoordinateDisplayRemainsUsable() {
        let screens = [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 25, width: 1440, height: 850)]
        let origin = ClockLayout.clampedOrigin(CGPoint(x: -1800, y: 100), size: 248, screens: screens)
        XCTAssertEqual(origin, CGPoint(x: -1800, y: 100))
    }

    func testDisconnectedDisplayRecoversClockInsideVisibleFrame() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let origin = ClockLayout.clampedOrigin(CGPoint(x: -1800, y: 1500), size: 248, screens: [screen])
        XCTAssertEqual(origin, CGPoint(x: 0, y: 627))
        XCTAssertTrue(screen.contains(CGRect(origin: origin, size: CGSize(width: 248, height: 248))))
    }
}
