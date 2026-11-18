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

    func testRegionalAndFixedMenusHaveDistinctLabels() {
        let options = catalog.options
        XCTAssertLessThan(options.count, 90)
        XCTAssertLessThan(options.count, TimeZone.knownTimeZoneIdentifiers.count / 2)
        XCTAssertEqual(Set(options.map(\.title)).count, options.count)
        XCTAssertEqual(Set(options.map(\.identifier)).count, options.count)
        XCTAssertEqual(options.map(\.standardOffset), options.map(\.standardOffset).sorted())
        for option in options {
            XCTAssertTrue(option.title.hasPrefix(ClockTimeZoneCatalog.offsetTitle(option.standardOffset)))
            XCTAssertTrue(option.title.contains(" · "))
            XCTAssertFalse(option.regions.isEmpty)
            XCTAssertEqual(option.title.hasSuffix(" - 夏令时"), option.hasDaylightSavingTime)
            XCTAssertTrue(option.settings.usesDaylightSavingTime)
            XCTAssertFalse(option.help.isEmpty)
        }
        XCTAssertEqual(catalog.commonOptions.count, 6)
        XCTAssertEqual(catalog.commonOptions.first?.identifier, "Asia/Shanghai")
        XCTAssertEqual(catalog.fixedOptions.map(\.standardOffset), Array(Set(catalog.fixedOptions.map(\.standardOffset))).sorted())
        XCTAssertTrue(Set(options.map(\.standardOffset)).isSubset(of: Set(catalog.fixedOptions.map(\.standardOffset))))
        for option in catalog.fixedOptions {
            XCTAssertEqual(option.title, ClockTimeZoneCatalog.offsetTitle(option.standardOffset))
            XCTAssertTrue(option.regions.isEmpty)
            XCTAssertFalse(option.hasDaylightSavingTime)
            XCTAssertFalse(option.settings.usesDaylightSavingTime)
        }
    }

    func testEquivalentRegionalZonesAreMerged() throws {
        let eastEight = try XCTUnwrap(catalog.option(for: "Asia/Shanghai"))
        XCTAssertEqual(eastEight, catalog.option(for: "Asia/Singapore"))
        XCTAssertEqual(eastEight, catalog.option(for: "Australia/Perth"))
        XCTAssertEqual(eastEight.title, "UTC+08:00 · 上海／珀斯")
        XCTAssertTrue(eastEight.regions.contains(.asia))
        XCTAssertTrue(eastEight.regions.contains(.oceania))
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
        XCTAssertTrue(seasonal.title.hasPrefix("UTC−07:00 · 丹佛"))
        XCTAssertTrue(seasonal.title.hasSuffix(" - 夏令时"))
        let european = try XCTUnwrap(catalog.option(for: "Europe/Athens"))
        let differentSeason = try XCTUnwrap(catalog.option(for: "Africa/Cairo"))
        XCTAssertEqual(european.standardOffset, differentSeason.standardOffset)
        XCTAssertNotEqual(european.identifier, differentSeason.identifier)
        XCTAssertNotEqual(european.title, differentSeason.title)
        let london = try XCTUnwrap(catalog.option(for: "Europe/London"))
        let troll = try XCTUnwrap(catalog.option(for: "Antarctica/Troll"))
        XCTAssertEqual(london.title, "UTC+00:00 · 伦敦／里斯本 - 夏令时")
        XCTAssertEqual(troll.title, "UTC+00:00 · 特罗尔站（南极） - 夏令时")
        XCTAssertNotEqual(london, troll)
    }

    func testEveryKnownZoneMapsToAnExistingChoiceWithoutChangingTime() throws {
        let formatter = ISO8601DateFormatter()
        var dates = [referenceDate]
        for year in 2027...2029 {
            for month in [1, 4, 7, 10] {
                dates.append(formatter.date(from: String(format: "%04d-%02d-15T12:00:00Z", year, month))!)
            }
        }
        let start = referenceDate
        let end = formatter.date(from: "2029-11-18T12:00:00Z")!
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            let option = try XCTUnwrap(catalog.option(for: identifier), identifier)
            XCTAssertTrue(catalog.options.contains(option) || catalog.fixedOptions.contains(option), identifier)
            let source = try XCTUnwrap(TimeZone(identifier: identifier))
            let merged = try XCTUnwrap(TimeZone(identifier: option.identifier))
            var samples = dates
            var cursor = start
            while let transition = source.nextDaylightSavingTimeTransition(after: cursor), transition < end {
                samples += [transition.addingTimeInterval(-1), transition, transition.addingTimeInterval(1)]
                cursor = transition.addingTimeInterval(1)
            }
            for date in samples where date >= start && date < end {
                XCTAssertEqual(source.secondsFromGMT(for: date), merged.secondsFromGMT(for: date), "\(identifier) at \(date)")
                if option.hasDaylightSavingTime {
                    XCTAssertEqual(source.daylightSavingTimeOffset(for: date), merged.daylightSavingTimeOffset(for: date), "\(identifier) at \(date)")
                }
            }
        }
    }

    func testSavedFixedOffsetsAndInvalidIdentifiersAreHandled() throws {
        let identifier = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600 + 12 * 60)).identifier
        let custom = try XCTUnwrap(catalog.option(for: identifier))
        XCTAssertEqual(custom.standardOffset, 8 * 3600 + 12 * 60)
        XCTAssertEqual(custom.title, "UTC+08:12")
        XCTAssertTrue(custom.regions.isEmpty)
        XCTAssertNil(catalog.option(for: "invalid"))
        XCTAssertEqual(ClockTimeZoneSettings.selectionTitle(for: "Asia/Shanghai"), "UTC+08:00 · 上海／珀斯")
        var saved = ClockTimeZoneSettings(identifier: "US/Pacific", usesDaylightSavingTime: false)
        XCTAssertEqual(catalog.option(for: saved, at: referenceDate)?.title, "UTC−08:00")
        saved.usesDaylightSavingTime = true
        let losAngeles = try XCTUnwrap(catalog.option(for: "America/Los_Angeles"))
        XCTAssertEqual(catalog.option(for: saved, at: referenceDate), losAngeles)
    }
}
