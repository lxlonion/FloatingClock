import Foundation

private struct TimeZoneState: Hashable {
    let offset: Int
    let daylightOffset: Int

    init(_ zone: TimeZone, at date: Date, ignoringDaylightSavingTime: Bool = false) {
        offset = zone.secondsFromGMT(for: date)
        daylightOffset = ignoringDaylightSavingTime ? 0 : Int(zone.daylightSavingTimeOffset(for: date))
    }
}

private struct TimeZoneTransition: Hashable {
    let date: Date
    let state: TimeZoneState
}

private struct TimeZoneRule: Hashable {
    let initial: TimeZoneState
    let transitions: [TimeZoneTransition]

    var standardOffset: Int { initial.offset - initial.daylightOffset }
    var hasDaylightSavingTime: Bool {
        initial.daylightOffset != 0 || transitions.contains { $0.state.daylightOffset != 0 }
    }

    init(_ zone: TimeZone, from start: Date, to end: Date) {
        let startingState = TimeZoneState(zone, at: start)
        var changes: [TimeZoneTransition] = []
        var cursor = start
        while let date = zone.nextDaylightSavingTimeTransition(after: cursor), date < end {
            let state = TimeZoneState(zone, at: date)
            if state != (changes.last?.state ?? startingState) {
                changes.append(TimeZoneTransition(date: date, state: state))
            }
            cursor = date.addingTimeInterval(1)
        }
        // A region that has permanently adopted its former summer offset can
        // share the same choice as any region now keeping that offset.
        initial = changes.isEmpty ? TimeZoneState(zone, at: start, ignoringDaylightSavingTime: true) : startingState
        transitions = changes
    }
}

public enum ClockTimeZoneRegion: String, CaseIterable {
    case americas = "美洲"
    case europe = "欧洲"
    case africa = "非洲"
    case asia = "亚洲"
    case oceania = "大洋洲"
    case polar = "极地"

    fileprivate init?(identifier: String) {
        switch identifier {
        case "Atlantic/Bermuda", "Atlantic/South_Georgia", "Atlantic/Stanley",
             "Pacific/Easter", "Pacific/Galapagos":
            self = .americas
            return
        case "Atlantic/Cape_Verde", "Atlantic/St_Helena",
             "Indian/Antananarivo", "Indian/Comoro", "Indian/Mahe", "Indian/Mauritius", "Indian/Mayotte", "Indian/Reunion":
            self = .africa
            return
        case "Indian/Christmas", "Indian/Cocos":
            self = .oceania
            return
        default:
            break
        }
        switch identifier.split(separator: "/").first {
        case "America": self = .americas
        case "Atlantic", "Europe": self = .europe
        case "Africa": self = .africa
        case "Asia", "Indian": self = .asia
        case "Australia", "Pacific": self = .oceania
        case "Antarctica", "Arctic": self = .polar
        default: return nil
        }
    }
}

public struct ClockTimeZoneOption: Equatable {
    public let identifier: String
    public let standardOffset: Int
    public let hasDaylightSavingTime: Bool
    public let regions: [ClockTimeZoneRegion]
    public let help: String
    fileprivate let placeNames: [String]

    public var title: String { title(includingPlaceNames: true) }

    public func title(includingPlaceNames: Bool) -> String {
        let offset = ClockTimeZoneCatalog.offsetTitle(standardOffset)
        let places = includingPlaceNames && !placeNames.isEmpty ? " · " + placeNames.joined(separator: "／") : ""
        return offset + places + (hasDaylightSavingTime ? " - 夏令时" : "")
    }

    public var settings: ClockTimeZoneSettings {
        ClockTimeZoneSettings(identifier: identifier, usesDaylightSavingTime: !regions.isEmpty)
    }
}

/// Group places whose clocks follow the same rules over the next three years.
public struct ClockTimeZoneCatalog {
    public static let shared = Self()
    public let options: [ClockTimeZoneOption]
    public let commonOptions: [ClockTimeZoneOption]
    public let fixedOptions: [ClockTimeZoneOption]
    private let referenceDate: Date
    private let end: Date
    private let optionsByRule: [TimeZoneRule: ClockTimeZoneOption]

    public init(referenceDate: Date = Date()) {
        self.referenceDate = referenceDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.date(byAdding: .year, value: 3, to: referenceDate)!
        self.end = end
        let representatives = ClockTimeZonePlace.representatives
        let identifiers = Set(TimeZone.knownTimeZoneIdentifiers).union(representatives.map(\.identifier))
        var groups: [TimeZoneRule: [String]] = [:]
        var rulesByIdentifier: [String: TimeZoneRule] = [:]
        for identifier in identifiers.sorted() {
            guard let zone = TimeZone(identifier: identifier),
                  ClockTimeZoneRegion(identifier: identifier) != nil else { continue }
            let rule = TimeZoneRule(zone, from: referenceDate, to: end)
            groups[rule, default: []].append(identifier)
            rulesByIdentifier[identifier] = rule
        }

        let placesByRule = Dictionary(grouping: representatives) { rulesByIdentifier[$0.identifier] }
        let ordering = Dictionary(uniqueKeysWithValues: representatives.enumerated().map { ($1.identifier, $0) })
        let entries = groups.map { rule, identifiers in
            let places = placesByRule[rule] ?? []
            let identifier = places.first?.identifier ?? identifiers[0]
            let regions = identifiers.compactMap(ClockTimeZoneRegion.init(identifier:))
            return (rule, Self.regionalOption(identifier: identifier, rule: rule,
                                              names: places.prefix(2).map(\.name), regions: regions))
        }
        let byRule = Dictionary(uniqueKeysWithValues: entries)
        optionsByRule = byRule
        options = entries.map { $0.1 }.sorted {
            if $0.standardOffset != $1.standardOffset { return $0.standardOffset < $1.standardOffset }
            if $0.hasDaylightSavingTime != $1.hasDaylightSavingTime { return !$0.hasDaylightSavingTime }
            return (ordering[$0.identifier] ?? .max, $0.identifier) < (ordering[$1.identifier] ?? .max, $1.identifier)
        }
        let common = ["Asia/Shanghai", "America/New_York", "America/Los_Angeles", "Europe/London", "Asia/Tokyo", "Australia/Sydney"]
        var commonIdentifiers = Set<String>()
        commonOptions = common.compactMap { identifier in
            guard let rule = rulesByIdentifier[identifier], let option = byRule[rule],
                  commonIdentifiers.insert(option.identifier).inserted else { return nil }
            return option
        }

        let observedOffsets = groups.keys.flatMap { rule in
            [rule.standardOffset, rule.initial.offset] + rule.transitions.map { $0.state.offset }
        }
        fixedOptions = Set(observedOffsets).union((-12...14).map { $0 * 3600 }).sorted().compactMap(Self.fixedOption)
    }

    public func option(for identifier: String) -> ClockTimeZoneOption? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        // Foundation's fixed offsets and the Etc aliases have their own picker.
        if identifier.hasPrefix("Etc/") || identifier == "GMT" || identifier == "UTC" ||
            identifier.hasPrefix("GMT+") || identifier.hasPrefix("GMT-") ||
            identifier.hasPrefix("UTC+") || identifier.hasPrefix("UTC-") {
            return Self.fixedOption(zone.secondsFromGMT(for: referenceDate))
        }
        let rule = TimeZoneRule(zone, from: referenceDate, to: end)
        if let option = optionsByRule[rule] { return option }
        let region = ClockTimeZoneRegion(identifier: identifier) ?? .americas
        return Self.regionalOption(identifier: identifier, rule: rule, names: [], regions: [region])
    }

    public func option(for settings: ClockTimeZoneSettings, at date: Date) -> ClockTimeZoneOption? {
        guard let option = option(for: settings.identifier) else { return nil }
        guard !settings.usesDaylightSavingTime else { return option }
        let effectiveOffset = settings.timeZone(at: date).secondsFromGMT(for: date)
        if option.hasDaylightSavingTime || TimeZone(identifier: settings.identifier)?.secondsFromGMT(for: date) != effectiveOffset {
            return Self.fixedOption(effectiveOffset)
        }
        return option
    }

    public static func offsetTitle(_ seconds: Int) -> String {
        let magnitude = abs(seconds)
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", magnitude / 3600, magnitude % 3600 / 60)
    }

    private static func fixedOption(_ offset: Int) -> ClockTimeZoneOption? {
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        return ClockTimeZoneOption(identifier: zone.identifier, standardOffset: offset, hasDaylightSavingTime: false,
                                   regions: [], help: "全年使用 \(offsetTitle(offset))。", placeNames: [])
    }

    private static func regionalOption(identifier: String, rule: TimeZoneRule, names: [String],
                                       regions: [ClockTimeZoneRegion]) -> ClockTimeZoneOption {
        let city = identifier.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ") ?? identifier
        let offset = offsetTitle(rule.standardOffset)
        let formatter = Date.ISO8601FormatStyle(timeZone: .gmt)
        let upcoming = rule.transitions.prefix(4).map {
            "\($0.date.formatted(formatter)) → \(offsetTitle($0.state.offset))"
        }
        let heading = rule.transitions.isEmpty ? "全年使用 \(offset)。" : "标准偏移 \(offset)，按当地规则切换。"
        return ClockTimeZoneOption(identifier: identifier, standardOffset: rule.standardOffset,
                                   hasDaylightSavingTime: rule.hasDaylightSavingTime,
                                   regions: ClockTimeZoneRegion.allCases.filter(regions.contains),
                                   help: ([heading] + upcoming).joined(separator: "\n"),
                                   placeNames: names.isEmpty ? [city] : names)
    }
}
