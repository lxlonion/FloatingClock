import XCTest
import CoreGraphics
@testable import ClockCore

final class ClockCoreTests: XCTestCase {
    func testMinimumClockSizeMatchesTheTimerWidthAndMigratesOldSizes() throws {
        XCTAssertEqual(ClockSettings().faceSize + Double(ClockLayout.padding * 2), Double(ClockLayout.minimumPanelWidth))
        for size in [0.0, 140, 224, 259, 260, 300, 360, 420, 500] {
            let saved = Data("{\"faceSize\":\(size)}".utf8)
            let settings = try JSONDecoder().decode(ClockSettings.self, from: saved).normalized()
            XCTAssertEqual(settings.faceSize, min(420, max(260, size)))
            let dial = CGRect(x: 100, y: 500, width: settings.faceSize + 24, height: settings.faceSize + 24)
            let layout = TimerAttachmentLayout(clock: dial, trayHeight: 100, screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
            XCTAssertEqual(layout.frame.width, dial.width)
            XCTAssertEqual(layout.dialFrame.minX, 0)
        }
    }

    func testLinkedTransparencyCompensationPeaksAtTheMidpointAndMatchesAtBothEnds() {
        var settings = ClockSettings()
        var previous = 1.0
        for transparency in 0...90 {
            settings.transparency = Double(transparency)
            let content = settings.contentAlpha
            XCTAssertEqual(settings.backgroundAlpha, 1 - Double(transparency) / 100, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(content, settings.backgroundAlpha)
            XCTAssertLessThanOrEqual(content, settings.backgroundAlpha + 0.100001)
            XCTAssertGreaterThanOrEqual(content, 0.099999)
            XCTAssertLessThanOrEqual(content, previous)
            previous = content
        }
        for (transparency, background, content) in [(0.0, 1.0, 1.0), (45, 0.55, 0.65), (80, 0.2, 0.2395061728), (90, 0.1, 0.1)] {
            settings.transparency = transparency
            XCTAssertEqual(settings.backgroundAlpha, background, accuracy: 0.000001)
            XCTAssertEqual(settings.contentAlpha, content, accuracy: 0.000001)
        }
        settings.transparency = .nan
        XCTAssertTrue(settings.contentAlpha.isFinite)
    }

    func testAdjustingEitherLayerEntersManualModeAndOverallAdjustmentRelinksBoth() {
        var settings = ClockSettings()
        settings.transparency = 20
        let linkedContent = settings.contentTransparency
        settings.backgroundTransparency = 72
        XCTAssertTrue(settings.usesCustomTransparency)
        XCTAssertEqual(settings.contentTransparency, linkedContent)
        XCTAssertEqual(settings.backgroundTransparency, 72)

        settings.contentTransparency = 55
        XCTAssertEqual(settings.backgroundTransparency, 72)
        XCTAssertEqual(settings.transparency, 20)
        settings.transparency = 20
        XCTAssertFalse(settings.usesCustomTransparency)
        XCTAssertEqual(settings.contentTransparency, linkedContent)
        XCTAssertEqual(settings.backgroundTransparency, 20)

        settings.contentTransparency = 110
        settings.backgroundTransparency = -5
        XCTAssertEqual(settings.normalized().contentTransparency, 90)
        XCTAssertEqual(settings.normalized().backgroundTransparency, 0)
    }

    func testQuickAccessChoosesOppositeHorizontalCornerInEachScreenQuadrant() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        for (x, y, expected) in [(40.0, 600.0, ClockCorner.topRight), (1100, 600, .topLeft),
                                  (40, 50, .bottomRight), (1100, 50, .bottomLeft)] {
            XCTAssertEqual(QuickAccessLayout.corner(for: CGRect(x: x, y: y, width: 248, height: 248), on: screen), expected)
        }
    }

    func testQuickAccessUsesTheLocalDisplayOriginAndFitsEverySize() {
        let screen = CGRect(x: -1920, y: 1080, width: 1920, height: 1080)
        XCTAssertEqual(QuickAccessLayout.corner(for: CGRect(x: -1880, y: 1850, width: 248, height: 248), on: screen), .topRight)
        XCTAssertEqual(QuickAccessLayout.corner(for: CGRect(x: -300, y: 1120, width: 248, height: 248), on: screen), .bottomLeft)
        for side in [140.0, 164, 224, 284, 360, 420] {
            let card = CGRect(x: 12, y: 12, width: side, height: side)
            for corner in ClockCorner.allCases {
                let button = QuickAccessLayout.buttonFrame(in: card, corner: corner)
                XCTAssertTrue(card.contains(button))
                XCTAssertGreaterThanOrEqual(button.width, 18)
                XCTAssertLessThan(button.width, side / 7)
            }
        }
    }

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
        XCTAssertEqual(settings.backgroundAlpha, 0.1, accuracy: 0.0001)
        XCTAssertEqual(settings.contentAlpha, 0.1, accuracy: 0.0001)
        XCTAssertEqual(settings.normalized().faceSize, 260)
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
        settings.contentTransparency = 70
        settings.backgroundTransparency = 44
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

    func testUpdatingLegacyPreferencesPreservesUserSettings() throws {
        let data = Data(#"{"transparency":63,"faceSize":284,"appearance":"dark","isLocked":true,"showsSeconds":false,"showsDate":false,"origin":{"x":-1000,"y":80}}"#.utf8)
        let settings = try JSONDecoder().decode(ClockSettings.self, from: data)
        XCTAssertEqual(settings.style, .minimal)
        XCTAssertEqual(settings.transparency, 63)
        XCTAssertFalse(settings.usesCustomTransparency)
        XCTAssertEqual(settings.backgroundTransparency, 63)
        XCTAssertEqual(settings.contentTransparency, 54.6, accuracy: 0.0001)
        XCTAssertEqual(settings.faceSize, 284)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertTrue(settings.isLocked)
        XCTAssertFalse(settings.showsSeconds)
        XCTAssertFalse(settings.showsDate)
        XCTAssertEqual(settings.origin, StoredPoint(x: -1000, y: 80))
    }

    func testEveryStylePersistsAcrossRelaunch() {
        let suite = "FloatingClock.styles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for style in ClockStyle.allCases {
            var settings = ClockSettings()
            settings.style = style
            settings.showsMinuteNumerals = true
            settings.minuteNumeralOpacity = 72
            settings.minuteNumeralSize = 65
            SettingsStore(defaults: defaults).save(settings)
            XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings)
        }
    }

    func testRemovedThirdStyleMigratesToSharedMinuteLayer() throws {
        let data = Data(#"{"style":"style3","transparency":63,"faceSize":284,"appearance":"dark","isLocked":true,"showsSeconds":false,"showsDate":false,"origin":{"x":-1000,"y":80}}"#.utf8)
        let settings = try JSONDecoder().decode(ClockSettings.self, from: data)
        XCTAssertEqual(settings.style, .minimal)
        XCTAssertTrue(settings.showsMinuteNumerals)
        XCTAssertEqual(settings.minuteNumeralOpacity, 40)
        XCTAssertEqual(settings.minuteNumeralSize, 100)
        XCTAssertEqual(settings.transparency, 63)
        XCTAssertEqual(settings.faceSize, 284)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertTrue(settings.isLocked)
        XCTAssertFalse(settings.showsSeconds)
        XCTAssertFalse(settings.showsDate)
        XCTAssertEqual(settings.origin, StoredPoint(x: -1000, y: 80))
    }

    func testExistingDialStylesDoNotEnableMinuteLayerOnUpgrade() throws {
        for style in ClockStyle.allCases {
            let data = Data("{\"style\":\"\(style.rawValue)\",\"transparency\":27}".utf8)
            let settings = try JSONDecoder().decode(ClockSettings.self, from: data)
            XCTAssertEqual(settings.style, style)
            XCTAssertFalse(settings.showsMinuteNumerals)
            XCTAssertEqual(settings.transparency, 27)
            XCTAssertEqual(settings.minuteNumeralSize, 100)
        }
    }

    func testMinuteOpacityBoundsDoNotChangeWindowTransparency() {
        var settings = ClockSettings()
        settings.transparency = 63
        settings.minuteNumeralOpacity = 120
        XCTAssertEqual(settings.normalized().minuteNumeralOpacity, 100)
        XCTAssertEqual(settings.minuteNumeralAlpha, 1)
        XCTAssertEqual(settings.backgroundAlpha, 0.37, accuracy: 0.0001)
        settings.minuteNumeralOpacity = -10
        XCTAssertEqual(settings.minuteNumeralAlpha, 0)
        settings.minuteNumeralOpacity = .nan
        XCTAssertEqual(settings.normalized().minuteNumeralOpacity, 40)
        XCTAssertEqual(settings.transparency, 63)
    }

    func testDayWeekdayAndMinuteFollowLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let formatter = ISO8601DateFormatter()
        let saturday = ClockReadout(date: formatter.date(from: "2026-11-14T10:15:36+08:00")!, calendar: calendar)
        XCTAssertEqual(saturday.day, "14")
        XCTAssertEqual(saturday.weekday, "周六")
        XCTAssertEqual(saturday.minute, "15")
        let sunday = ClockReadout(date: formatter.date(from: "2026-11-14T16:00:00Z")!, calendar: calendar)
        XCTAssertEqual(sunday.day, "15")
        XCTAssertEqual(sunday.weekday, "周日")
        XCTAssertEqual(sunday.minute, "00")
    }

    func testMinuteSizeBoundsAndUpgradePreserveTheExistingDial() throws {
        let old = try JSONDecoder().decode(ClockSettings.self, from: Data(
            #"{"showsMinuteNumerals":true,"minuteNumeralOpacity":67,"faceSize":284}"#.utf8))
        XCTAssertEqual(old.minuteNumeralSize, 100)
        XCTAssertEqual(old.minuteNumeralOpacity, 67)
        XCTAssertTrue(old.showsMinuteNumerals)
        var settings = old
        settings.minuteNumeralSize = 120
        XCTAssertEqual(settings.normalized().minuteNumeralSize, 100)
        settings.minuteNumeralSize = 0
        XCTAssertEqual(settings.normalized().minuteNumeralSize, 40)
        settings.minuteNumeralSize = .nan
        XCTAssertEqual(settings.normalized().minuteNumeralSize, 100)
        XCTAssertEqual(settings.normalized().faceSize, old.faceSize)
        XCTAssertEqual(settings.normalized().minuteNumeralOpacity, old.minuteNumeralOpacity)
    }

    func testDisconnectedDisplayRecoversClockInsideVisibleFrame() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let origin = ClockLayout.clampedOrigin(CGPoint(x: -1800, y: 1500), size: 248, screens: [screen])
        XCTAssertEqual(origin, CGPoint(x: 0, y: 627))
        XCTAssertTrue(screen.contains(CGRect(origin: origin, size: CGSize(width: 248, height: 248))))
    }
}
