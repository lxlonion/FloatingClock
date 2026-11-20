import XCTest
@testable import ClockCore

final class SettingsRecoveryTests: XCTestCase {
    private let key = "FloatingClock.settings.v1"

    // This mirrors the startup position callback: load, update origin, save and relaunch.
    private func startupRoundTrip(_ json: String, check: (ClockSettings) -> Void) {
        let suite = "FloatingClock.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(json.utf8), forKey: key)
        let store = SettingsStore(defaults: defaults)
        var loaded = store.load()
        check(loaded)
        loaded.origin = StoredPoint(x: -300, y: 120)
        store.save(loaded)
        XCTAssertEqual(store.load(), loaded.normalized())
        check(store.load())
    }

    func testUnknownAppearanceAndWrongScalarTypesPreserveOtherPreferences() {
        startupRoundTrip(#"{"appearance":"future-theme","transparency":63,"faceSize":284,"style":"style2","isLocked":true,"showsSeconds":false,"showsDate":false,"origin":{"x":10,"y":20}}"#) { settings in
            XCTAssertEqual(settings.appearance, .light)
            XCTAssertEqual(settings.transparency, 63)
            XCTAssertEqual(settings.faceSize, 284)
            XCTAssertEqual(settings.style, .cardinalNumbers)
            XCTAssertTrue(settings.isLocked)
            XCTAssertFalse(settings.showsSeconds)
            XCTAssertFalse(settings.showsDate)
        }
        let corruptFields = ["transparency", "faceSize", "appearance", "style", "showsMinuteNumerals",
                             "minuteNumeralOpacity", "minuteNumeralSize", "isLocked", "showsSeconds", "showsDate",
                             "timerDisplayFormat", "selectedClockSlot"]
        for field in corruptFields {
            // An array has the wrong type for every known scalar field.
            startupRoundTrip("{\"\(field)\":[],\"origin\":{\"x\":10,\"y\":20},\"thirdClockTimeZone\":{\"identifier\":\"Asia/Tokyo\",\"usesDaylightSavingTime\":false}}") { settings in
                var withoutPosition = settings
                withoutPosition.origin = nil
                var expected = ClockSettings()
                expected.thirdClockTimeZone = ClockTimeZoneSettings(identifier: "Asia/Tokyo", usesDaylightSavingTime: false)
                XCTAssertEqual(withoutPosition, expected, field)
            }
        }
    }

    func testNestedFieldsRecoverIndependentlyAndNormalize() {
        startupRoundTrip(#"{"transparency":45,"customTransparency":{"content":"bad","background":75},"secondClockTimeZone":{"identifier":"Asia/Tokyo","usesDaylightSavingTime":"bad"},"thirdClockTimeZone":{"identifier":false,"usesDaylightSavingTime":false},"origin":{"x":"bad","y":20},"faceSize":500}"#) { settings in
            XCTAssertTrue(settings.usesCustomTransparency)
            XCTAssertEqual(settings.contentTransparency, 35, accuracy: 0.00001)
            XCTAssertEqual(settings.backgroundTransparency, 75)
            XCTAssertEqual(settings.secondClockTimeZone, ClockTimeZoneSettings(identifier: "Asia/Tokyo", usesDaylightSavingTime: false))
            XCTAssertEqual(settings.thirdClockTimeZone, ClockTimeZoneSettings(identifier: ClockTimeZoneSettings.newYork.identifier, usesDaylightSavingTime: false))
            XCTAssertEqual(settings.faceSize, 420)
        }
        startupRoundTrip(#"{"transparency":45,"customTransparency":{"content":55,"background":[]},"secondClockTimeZone":{"identifier":"invalid","usesDaylightSavingTime":true},"thirdClockTimeZone":false,"origin":{"x":10}}"#) { settings in
            XCTAssertEqual(settings.contentTransparency, 55)
            XCTAssertEqual(settings.backgroundTransparency, 45)
            XCTAssertEqual(settings.secondClockTimeZone, ClockTimeZoneSettings(identifier: ClockTimeZoneSettings.pacific.identifier, usesDaylightSavingTime: true))
            XCTAssertEqual(settings.thirdClockTimeZone, .newYork)
        }
        let preserved = try! JSONDecoder().decode(ClockSettings.self, from: Data(#"{"appearance":"unknown","origin":{"x":-1000,"y":80}}"#.utf8))
        XCTAssertEqual(preserved.origin, StoredPoint(x: -1000, y: 80))
        let malformed = try! JSONDecoder().decode(ClockSettings.self, from: Data(#"{"origin":{"x":10},"customTransparency":{"content":false,"background":[]}}"#.utf8))
        XCTAssertNil(malformed.origin)
        XCTAssertFalse(malformed.usesCustomTransparency)
    }

    func testLegacyStyleMigrationSurvivesStartupSave() {
        startupRoundTrip(#"{"style":"style3","transparency":63,"appearance":"dark","isLocked":true,"showsSeconds":false,"origin":{"x":-1000,"y":80}}"#) { settings in
            XCTAssertEqual(settings.style, .minimal)
            XCTAssertTrue(settings.showsMinuteNumerals)
            XCTAssertEqual(settings.transparency, 63)
            XCTAssertEqual(settings.appearance, .dark)
            XCTAssertTrue(settings.isLocked)
            XCTAssertFalse(settings.showsSeconds)
            XCTAssertFalse(settings.usesCustomTransparency)
        }
    }
}
