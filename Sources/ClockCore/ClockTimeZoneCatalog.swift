import Foundation

private struct TimeZoneState: Hashable {
    let offset: Int
    let daylightOffset: Int

    init(_ zone: TimeZone, at date: Date) {
        offset = zone.secondsFromGMT(for: date)
        daylightOffset = Int(zone.daylightSavingTimeOffset(for: date))
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
        initial = TimeZoneState(zone, at: start)
        var changes: [TimeZoneTransition] = []
        var cursor = start
        while let date = zone.nextDaylightSavingTimeTransition(after: cursor), date < end {
            changes.append(TimeZoneTransition(date: date, state: TimeZoneState(zone, at: date)))
            cursor = date.addingTimeInterval(1)
        }
        transitions = changes
    }
}

public struct ClockTimeZoneOption: Equatable {
    public let identifier: String
    public let standardOffset: Int
    public let hasDaylightSavingTime: Bool
    public fileprivate(set) var title: String
    public let help: String
}

/// Merge geographic aliases only when their offsets AND transition rules agree.
/// Include this year and the next two years so future rule changes stay distinct.
public struct ClockTimeZoneCatalog {
    public static let shared = Self()
    public let options: [ClockTimeZoneOption]
    private let start: Date
    private let end: Date
    private let year: Int
    private let referenceDate: Date
    private let optionsByRule: [TimeZoneRule: ClockTimeZoneOption]

    public init(referenceDate: Date = Date()) {
        self.referenceDate = referenceDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: referenceDate)
        self.year = year
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 3, to: start)!
        self.start = start
        self.end = end
        var groups: [TimeZoneRule: [String]] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            groups[TimeZoneRule(zone, from: start, to: end), default: []].append(identifier)
        }
        // Provide one fixed-offset choice for every standard offset, including
        // offsets otherwise represented only by a region with seasonal changes.
        let offsets = Set(groups.keys.map(\.standardOffset)).union((-12...14).map { $0 * 3600 })
        for offset in offsets {
            guard let zone = TimeZone(secondsFromGMT: offset) else { continue }
            groups[TimeZoneRule(zone, from: start, to: end), default: []].insert(zone.identifier, at: 0)
        }
        let preferred = ["America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Berlin", "Australia/Sydney", "Pacific/Auckland"]
        var entries: [(TimeZoneRule, ClockTimeZoneOption)] = groups.map { rule, identifiers in
            let identifier: String
            if rule.transitions.isEmpty && !rule.hasDaylightSavingTime {
                identifier = TimeZone(secondsFromGMT: rule.standardOffset)!.identifier
            } else {
                identifier = preferred.first { identifiers.contains($0) } ?? identifiers.sorted().first!
            }
            return (rule, Self.makeOption(identifier: identifier, rule: rule, year: year, referenceDate: referenceDate))
        }
        entries.sort {
            if $0.1.standardOffset != $1.1.standardOffset { return $0.1.standardOffset < $1.1.standardOffset }
            if $0.1.hasDaylightSavingTime != $1.1.hasDaylightSavingTime { return !$0.1.hasDaylightSavingTime }
            if $0.1.title != $1.1.title { return $0.1.title < $1.1.title }
            return $0.1.identifier < $1.1.identifier
        }
        // Some rules share the same dates but switch at different hours. Keep
        // them separate and expose exact UTC transition times in the tooltip.
        let titleCounts = Dictionary(grouping: entries, by: { $0.1.title }).mapValues(\.count)
        var titleNumbers: [String: Int] = [:]
        for index in entries.indices {
            let title = entries[index].1.title
            if titleCounts[title, default: 0] > 1 {
                titleNumbers[title, default: 0] += 1
                entries[index].1.title += " · 规则 \(titleNumbers[title]!)"
            }
        }
        options = entries.map { $0.1 }
        optionsByRule = Dictionary(uniqueKeysWithValues: entries)
    }

    public func option(for identifier: String) -> ClockTimeZoneOption? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        let rule = TimeZoneRule(zone, from: start, to: end)
        return optionsByRule[rule] ?? Self.makeOption(identifier: identifier, rule: rule,
            year: year, referenceDate: referenceDate)
    }

    public static func offsetTitle(_ seconds: Int) -> String {
        let magnitude = abs(seconds)
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", magnitude / 3600, magnitude % 3600 / 60)
    }

    private static func makeOption(identifier: String, rule: TimeZoneRule, year: Int, referenceDate: Date) -> ClockTimeZoneOption {
        let prefix = offsetTitle(rule.standardOffset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var starts: String?
        var stops: String?
        var previous = rule.initial
        for transition in rule.transitions {
            // Express the date on the local clock just before the change.
            let local = transition.date.addingTimeInterval(TimeInterval(previous.offset))
            if calendar.component(.year, from: local) == year {
                let date = String(format: "%02d/%02d", calendar.component(.month, from: local), calendar.component(.day, from: local))
                if transition.state.daylightOffset != 0 { starts = starts ?? date }
                else { stops = stops ?? date }
            }
            previous = transition.state
        }
        let kind: String
        if rule.hasDaylightSavingTime {
            let season: String
            if let starts, let stops { season = "\(starts)—\(stops)" }
            else if let starts { season = "\(starts) 起" }
            else if let stops { season = "至 \(stops)" }
            else { season = rule.initial.daylightOffset != 0 ? "全年" : "后续切换" }
            kind = "有夏令时（\(season)）"
        } else {
            kind = rule.transitions.isEmpty ? "无夏令时" : "时差调整规则"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        let upcoming = rule.transitions.filter { $0.date >= referenceDate }.prefix(4).map {
            "\(formatter.string(from: $0.date)) → \(offsetTitle($0.state.offset))"
        }
        let help = (["标准时间偏移：\(prefix)。相同偏移和切换规则的时区已合并。"] + upcoming).joined(separator: "\n")
        return ClockTimeZoneOption(identifier: identifier, standardOffset: rule.standardOffset,
                                  hasDaylightSavingTime: rule.hasDaylightSavingTime, title: "\(prefix) · \(kind)", help: help)
    }
}
