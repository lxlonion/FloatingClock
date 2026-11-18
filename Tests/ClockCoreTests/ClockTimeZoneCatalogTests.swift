import XCTest
@testable import ClockCore

final class ClockTimeZoneCatalogTests: XCTestCase {
    private let referenceDate = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!
    private lazy var catalog = ClockTimeZoneCatalog(referenceDate: referenceDate)

    func testOffsetLabelsIncludeSignsAndFractionalHours() {
        for (offset, title) in [(0, "UTC+00:00"), (28800, "UTC+08:00"), (-28800, "UTC−08:00"),
                                (20700, "UTC+05:45"), (34200, "UTC+09:30"), (-12600, "UTC−03:30"), (45900, "UTC+12:45")] {
            XCTAssertEqual(ClockTimeZoneCatalog.offsetTitle(offset), title)
        }
    }

    func testListIsCompactSortedAndHasNoGeographicLabels() {
        let options = catalog.options
        XCTAssertLessThan(options.count, 90)
        XCTAssertLessThan(options.count, TimeZone.knownTimeZoneIdentifiers.count / 2)
        XCTAssertEqual(Set(options.map(\.title)).count, options.count)
        XCTAssertEqual(Set(options.map(\.identifier)).count, options.count)
        XCTAssertEqual(options.map(\.standardOffset), options.map(\.standardOffset).sorted())
        for option in options {
            XCTAssertTrue(option.title.hasPrefix(ClockTimeZoneCatalog.offsetTitle(option.standardOffset)))
            XCTAssertFalse(["America/", "Asia/", "Europe/", "Africa/", "Pacific/", "Australia/"].contains { option.title.contains($0) })
            XCTAssertFalse(option.title.contains(option.identifier))
            XCTAssertFalse(option.help.isEmpty)
        }
        for offset in Set(options.map(\.standardOffset)) {
            let fixed = options.filter { $0.standardOffset == offset && !$0.hasDaylightSavingTime }
            XCTAssertEqual(fixed.count, 1)
            XCTAssertEqual(fixed.first?.identifier, TimeZone(secondsFromGMT: offset)?.identifier)
        }
    }

    func testEquivalentRegionalZonesAreMerged() throws {
        let eastEight = try XCTUnwrap(catalog.option(for: "Asia/Shanghai"))
        XCTAssertEqual(eastEight, catalog.option(for: "Asia/Singapore"))
        XCTAssertEqual(eastEight, catalog.option(for: "Australia/Perth"))
        XCTAssertEqual(eastEight.title, "UTC+08:00 · 无夏令时")
        XCTAssertEqual(catalog.option(for: "Asia/Kathmandu"), catalog.option(for: "Asia/Katmandu"))
        XCTAssertEqual(catalog.option(for: "America/New_York"), catalog.option(for: "America/Detroit"))
        XCTAssertEqual(catalog.option(for: "Europe/Paris"), catalog.option(for: "Europe/Berlin"))
        XCTAssertEqual(catalog.option(for: "US/Pacific"), catalog.option(for: "America/Los_Angeles"))
    }

    func testSameOffsetWithDifferentDSTBehaviorStaysSeparate() throws {
        let fixed = try XCTUnwrap(catalog.option(for: "America/Phoenix"))
        let seasonal = try XCTUnwrap(catalog.option(for: "America/Denver"))
        XCTAssertEqual(fixed.standardOffset, seasonal.standardOffset)
        XCTAssertNotEqual(fixed, seasonal)
        XCTAssertFalse(fixed.hasDaylightSavingTime)
        XCTAssertTrue(seasonal.hasDaylightSavingTime)
        let european = try XCTUnwrap(catalog.option(for: "Europe/Athens"))
        let differentSeason = try XCTUnwrap(catalog.option(for: "Africa/Cairo"))
        XCTAssertEqual(european.standardOffset, differentSeason.standardOffset)
        XCTAssertNotEqual(european.identifier, differentSeason.identifier)
        XCTAssertNotEqual(european.title, differentSeason.title)
    }

    func testEveryKnownZoneMapsToAnExistingChoiceWithoutChangingTime() throws {
        let formatter = ISO8601DateFormatter()
        var dates = [referenceDate]
        for year in 2026...2028 {
            for month in [1, 4, 7, 10] {
                dates.append(formatter.date(from: String(format: "%04d-%02d-15T12:00:00Z", year, month))!)
            }
        }
        let start = formatter.date(from: "2026-01-01T00:00:00Z")!
        let end = formatter.date(from: "2029-01-01T00:00:00Z")!
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            let option = try XCTUnwrap(catalog.option(for: identifier), identifier)
            XCTAssertTrue(catalog.options.contains(option), identifier)
            let source = try XCTUnwrap(TimeZone(identifier: identifier))
            let merged = try XCTUnwrap(TimeZone(identifier: option.identifier))
            var samples = dates
            var cursor = start
            while let transition = source.nextDaylightSavingTimeTransition(after: cursor), transition < end {
                samples += [transition.addingTimeInterval(-1), transition, transition.addingTimeInterval(1)]
                cursor = transition.addingTimeInterval(1)
            }
            for date in samples {
                XCTAssertEqual(source.secondsFromGMT(for: date), merged.secondsFromGMT(for: date), "\(identifier) at \(date)")
                XCTAssertEqual(source.daylightSavingTimeOffset(for: date), merged.daylightSavingTimeOffset(for: date), "\(identifier) at \(date)")
            }
        }
    }

    func testSavedFixedOffsetsAndInvalidIdentifiersAreHandled() throws {
        let identifier = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600 + 12 * 60)).identifier
        let custom = try XCTUnwrap(catalog.option(for: identifier))
        XCTAssertEqual(custom.standardOffset, 8 * 3600 + 12 * 60)
        XCTAssertEqual(custom.title, "UTC+08:12 · 无夏令时")
        XCTAssertNil(catalog.option(for: "invalid"))
        XCTAssertEqual(ClockTimeZoneSettings.selectionTitle(for: "Asia/Shanghai"), "UTC+08:00 · 无夏令时")
        XCTAssertEqual(ClockTimeZoneSettings.pacific.displayName, "UTC−08:00 · 标准时间")
    }
}
