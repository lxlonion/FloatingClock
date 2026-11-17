import XCTest
@testable import ClockCore

final class ClockTimeZoneTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

    func testDefaultsAndLegacySettingsKeepSystemClockWithTwoPresets() throws {
        for settings in [ClockSettings(), try JSONDecoder().decode(ClockSettings.self, from: Data("{}".utf8))] {
            XCTAssertEqual(settings.selectedClockSlot, .system)
            XCTAssertEqual(settings.secondClockTimeZone, .pacific)
            XCTAssertEqual(settings.thirdClockTimeZone, .newYork)
            XCTAssertEqual(ClockSlot.allCases.count, 3)
        }
        let legacy = try JSONDecoder().decode(ClockSettings.self, from: Data(#"{"transparency":52,"isLocked":true}"#.utf8))
        XCTAssertEqual(legacy.transparency, 52)
        XCTAssertTrue(legacy.isLocked)
    }

    func testSystemSlotUsesSystemCalendarIncludingItsDaylightSavingRules() {
        let settings = ClockSettings()
        var system = Calendar(identifier: .gregorian)
        for identifier in ["Asia/Shanghai", "America/New_York", "Australia/Lord_Howe"] {
            system.timeZone = TimeZone(identifier: identifier)!
            for now in [date("2026-01-15T12:00:00Z"), date("2026-07-15T12:00:00Z")] {
                XCTAssertEqual(settings.calendar(at: now, systemCalendar: system), system)
            }
        }
    }

    func testPacificDefaultIsStandardTimeAllYearAndCanEnableDST() {
        var settings = ClockSettings()
        settings.selectedClockSlot = .second
        let winter = date("2026-01-15T12:00:00Z")
        let summer = date("2026-07-15T12:00:00Z")
        for now in [winter, summer] {
            XCTAssertEqual(settings.calendar(at: now).timeZone.secondsFromGMT(for: now), -8 * 3600)
        }
        settings.secondClockTimeZone.usesDaylightSavingTime = true
        XCTAssertEqual(settings.calendar(at: winter).timeZone.secondsFromGMT(for: winter), -8 * 3600)
        XCTAssertEqual(settings.calendar(at: summer).timeZone.secondsFromGMT(for: summer), -7 * 3600)
        for (text, hours) in [("2026-03-08T09:59:59Z", -8), ("2026-03-08T10:00:00Z", -7),
                              ("2026-11-01T08:59:59Z", -7), ("2026-11-01T09:00:00Z", -8)] {
            let now = date(text)
            XCTAssertEqual(settings.calendar(at: now).timeZone.secondsFromGMT(for: now), hours * 3600)
        }
    }

    func testNewYorkDefaultAutomaticallyFollowsBothDSTTransitions() {
        var settings = ClockSettings()
        settings.selectedClockSlot = .third
        let cases = [("2026-03-08T06:59:59Z", -5), ("2026-03-08T07:00:00Z", -4),
                     ("2026-11-01T05:59:59Z", -4), ("2026-11-01T06:00:00Z", -5)]
        for (text, hours) in cases {
            let now = date(text)
            XCTAssertEqual(settings.calendar(at: now).timeZone.secondsFromGMT(for: now), hours * 3600)
        }
        settings.thirdClockTimeZone.usesDaylightSavingTime = false
        for (text, _) in cases {
            let now = date(text)
            XCTAssertEqual(settings.calendar(at: now).timeZone.secondsFromGMT(for: now), -5 * 3600)
        }
    }

    func testDisablingDSTHandlesHalfHourAdjustmentsAndZonesWithoutDST() {
        let now = date("2026-01-15T12:00:00Z")
        var zone = ClockTimeZoneSettings(identifier: "Australia/Lord_Howe", usesDaylightSavingTime: true)
        XCTAssertEqual(zone.timeZone(at: now).secondsFromGMT(for: now), 11 * 3600)
        zone.usesDaylightSavingTime = false
        XCTAssertEqual(zone.timeZone(at: now).secondsFromGMT(for: now), 10 * 3600 + 1800)
        zone.identifier = "Asia/Kathmandu"
        XCTAssertEqual(zone.timeZone(at: now).secondsFromGMT(for: now), 5 * 3600 + 2700)
        zone.usesDaylightSavingTime = true
        XCTAssertEqual(zone.timeZone(at: now).secondsFromGMT(for: now), 5 * 3600 + 2700)
    }

    func testSlotCalendarKeepsHandsDateAndMinuteReadoutConsistentAcrossMidnight() {
        var settings = ClockSettings()
        let now = date("2026-07-15T04:20:00Z")
        settings.selectedClockSlot = .second
        let pacificCalendar = settings.calendar(at: now)
        let pacific = ClockReadout(date: now, calendar: pacificCalendar)
        XCTAssertEqual(pacific.day, "14")
        XCTAssertEqual(pacific.weekday, "周二")
        XCTAssertEqual(pacific.minute, "20")
        XCTAssertEqual(pacificCalendar.component(.hour, from: now), 20)
        XCTAssertEqual(ClockAngles(date: now, calendar: pacificCalendar).hour, (8 + 20.0 / 60) / 12 * 2 * .pi, accuracy: 0.00001)
        settings.selectedClockSlot = .third
        let newYorkCalendar = settings.calendar(at: now)
        let newYork = ClockReadout(date: now, calendar: newYorkCalendar)
        XCTAssertEqual(newYork.day, "15")
        XCTAssertEqual(newYork.weekday, "周三")
        XCTAssertEqual(newYorkCalendar.component(.hour, from: now), 0)
        settings.thirdClockTimeZone = ClockTimeZoneSettings(identifier: "Asia/Kathmandu", usesDaylightSavingTime: true)
        XCTAssertEqual(ClockReadout(date: now, calendar: settings.calendar(at: now)).minute, "05")
    }

    func testSlotSelectionAndIndependentTimeZoneOptionsPersist() {
        let suite = "FloatingClock.timezones.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ClockSettings()
        settings.selectedClockSlot = .third
        settings.secondClockTimeZone = ClockTimeZoneSettings(identifier: "Europe/London", usesDaylightSavingTime: true)
        settings.thirdClockTimeZone = ClockTimeZoneSettings(identifier: "Asia/Tokyo", usesDaylightSavingTime: false)
        settings.transparency = 62
        SettingsStore(defaults: defaults).save(settings)
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings)
    }

    func testMalformedNewFieldsDoNotDiscardExistingPreferences() throws {
        let saved = Data(#"{"transparency":62,"selectedClockSlot":"unknown","secondClockTimeZone":{"identifier":"invalid","usesDaylightSavingTime":true},"thirdClockTimeZone":null}"#.utf8)
        let settings = try JSONDecoder().decode(ClockSettings.self, from: saved).normalized()
        XCTAssertEqual(settings.transparency, 62)
        XCTAssertEqual(settings.selectedClockSlot, .system)
        XCTAssertEqual(settings.secondClockTimeZone.identifier, ClockTimeZoneSettings.pacific.identifier)
        XCTAssertTrue(settings.secondClockTimeZone.usesDaylightSavingTime)
        XCTAssertEqual(settings.thirdClockTimeZone, .newYork)
        var invalid = settings
        invalid.thirdClockTimeZone.identifier = "invalid"
        XCTAssertEqual(invalid.normalized().thirdClockTimeZone, .newYork)
        let malformed = Data(#"{"transparency":38,"secondClockTimeZone":{"identifier":15},"thirdClockTimeZone":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ClockSettings.self, from: malformed)
        XCTAssertEqual(decoded.transparency, 38)
        XCTAssertEqual(decoded.secondClockTimeZone, .pacific)
        XCTAssertEqual(decoded.thirdClockTimeZone, .newYork)
    }
}
