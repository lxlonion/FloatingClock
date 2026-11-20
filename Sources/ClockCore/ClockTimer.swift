import Foundation

public enum TimerDisplayFormat: String, Codable, CaseIterable {
    case totalMinutes, hoursMinutes

    public var menuTitle: String {
        switch self {
        case .totalMinutes: return "总分钟 · 90分00秒"
        case .hoursMinutes: return "小时 / 分钟 · 1时30分00秒"
        }
    }

    public func string(seconds: TimeInterval, countingDown: Bool) -> String {
        let safe = seconds.isFinite ? max(0, min(seconds, Double(Int.max / 4))) : 0
        let value = Int(countingDown ? ceil(safe) : floor(safe))
        let secondsText = String(format: "%02d", value % 60)
        if self == .hoursMinutes, value >= 3600 {
            return "\(value / 3600)时\(String(format: "%02d", value / 60 % 60))分\(secondsText)秒"
        }
        return "\(String(format: "%02d", value / 60))分\(secondsText)秒"
    }
}

public enum ClockTimerMode: String, Codable { case countdown, elapsed }
public enum ClockTimerInput: String, Codable { case duration, targetTime }
public enum ClockTimerState: String, Codable { case idle, running, paused, completed }

public enum TimerInputError: Error, LocalizedError {
    case invalidDuration, invalidTarget, targetInPast, zeroCountdown

    public var errorDescription: String? {
        switch self {
        case .invalidDuration: return "请输入分钟，或 1小时30min、90:00"
        case .invalidTarget: return "请输入 18:30 或 2026-11-16 09:00"
        case .targetInPast: return "请选择未来的时间"
        case .zeroCountdown: return "倒计时必须大于 0；从零计时请切换为 −"
        }
    }
}

public enum TimerInputParser {
    public static let maximumDuration: TimeInterval = 999_999 * 60

    public static func duration(_ input: String) throws -> TimeInterval {
        let text = input.lowercased().filter { !$0.isWhitespace }
        guard !text.isEmpty else { throw TimerInputError.invalidDuration }
        if let value = Double(text), value.isFinite, value >= 0, value * 60 <= maximumDuration {
            return value * 60
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 || parts.count == 3 {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }),
                  numbers[0] <= 999_999, numbers.last! < 60,
                  (numbers.count == 2 || numbers[1] < 60) else { throw TimerInputError.invalidDuration }
            let seconds = numbers.count == 2 ? Double(numbers[0]) * 60 + Double(numbers[1]) :
                Double(numbers[0]) * 3600 + Double(numbers[1]) * 60 + Double(numbers[2])
            guard seconds <= maximumDuration else { throw TimerInputError.invalidDuration }
            return seconds
        }
        let regex = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)(小时|时|hours?|hrs?|h|分钟|分|minutes?|mins?|m|秒钟|秒|seconds?|secs?|s)"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var end = 0
        var total: TimeInterval = 0
        for match in matches {
            guard match.range.location == end,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else { throw TimerInputError.invalidDuration }
            let unit = String(text[unitRange])
            let multiplier: Double = unit.hasPrefix("h") || unit == "小时" || unit == "时" ? 3600 :
                (unit.hasPrefix("m") || unit == "分钟" || unit == "分" ? 60 : 1)
            total += number * multiplier
            end = NSMaxRange(match.range)
        }
        guard !matches.isEmpty, end == range.length, total.isFinite, total <= maximumDuration else {
            throw TimerInputError.invalidDuration
        }
        return total
    }

    public static func targetDate(_ input: String, now: Date, calendar: Calendar = .current) throws -> Date {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if (parts.count == 2 || parts.count == 3), !text.contains(" ") {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count, (0...23).contains(numbers[0]), (0...59).contains(numbers[1]),
                  (parts.count == 2 || (0...59).contains(numbers[2])) else { throw TimerInputError.invalidTarget }
            let components = DateComponents(hour: numbers[0], minute: numbers[1], second: parts.count == 3 ? numbers[2] : 0)
            guard let date = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) else {
                throw TimerInputError.invalidTarget
            }
            return date
        }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text), formatter.string(from: date) == text {
                guard date > now else { throw TimerInputError.targetInPast }
                return date
            }
        }
        throw TimerInputError.invalidTarget
    }
}

public struct ClockTimer: Codable, Equatable, Identifiable {
    public let id: UUID
    public var mode: ClockTimerMode = .countdown
    public var inputKind: ClockTimerInput = .duration
    public var input = "5"
    public private(set) var state: ClockTimerState = .idle
    public private(set) var duration: TimeInterval = 0
    public private(set) var accumulated: TimeInterval = 0
    public private(set) var startedAt: Date?
    private var overtime: Bool?
    public var isOvertime: Bool { overtime == true }
    public var countsDown: Bool { mode == .countdown && !isOvertime }

    public init(id: UUID = UUID()) { self.id = id }

    public var isValid: Bool {
        duration.isFinite && accumulated.isFinite && duration >= 0 && accumulated >= 0 &&
        (inputKind == .targetTime || duration <= TimerInputParser.maximumDuration) &&
        (state != .running || startedAt?.timeIntervalSince1970.isFinite == true)
    }

    public func elapsed(at date: Date) -> TimeInterval {
        accumulated + (state == .running ? max(0, date.timeIntervalSince(startedAt ?? date)) : 0)
    }

    public func seconds(at date: Date) -> TimeInterval {
        if mode == .countdown {
            return isOvertime ? max(0, elapsed(at: date) - duration) : max(0, duration - elapsed(at: date))
        }
        return elapsed(at: date)
    }

    public var deadline: Date? {
        guard countsDown, state == .running, let startedAt else { return nil }
        return startedAt.addingTimeInterval(duration - accumulated)
    }

    public mutating func start(at date: Date, calendar: Calendar = .current) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var selectedMode = mode
        if text.hasPrefix("-") || text.hasPrefix("−") { selectedMode = .elapsed; text.removeFirst() }
        else if text.hasPrefix("+") { selectedMode = .countdown; text.removeFirst() }
        let value: TimeInterval
        if inputKind == .targetTime, selectedMode == .countdown {
            value = try TimerInputParser.targetDate(text, now: date, calendar: calendar).timeIntervalSince(date)
        } else {
            value = try TimerInputParser.duration(text)
        }
        guard selectedMode == .elapsed || value > 0 else { throw TimerInputError.zeroCountdown }
        mode = selectedMode
        if mode == .elapsed { inputKind = .duration }
        input = text
        duration = value
        accumulated = mode == .elapsed ? value : 0
        startedAt = date
        overtime = nil
        state = .running
    }

    public mutating func pause(at date: Date) {
        guard state == .running else { return }
        finishIfNeeded(at: date)
        accumulated = elapsed(at: date)
        startedAt = nil
        state = .paused
    }

    public mutating func resume(at date: Date) {
        guard state == .paused else { return }
        startedAt = date
        state = .running
    }

    @discardableResult public mutating func finishIfNeeded(at date: Date) -> Bool {
        guard state == .running, countsDown, seconds(at: date) <= 0 else { return false }
        overtime = true
        return true
    }

    public mutating func reset() {
        state = .idle
        duration = 0
        accumulated = 0
        startedAt = nil
        overtime = nil
    }
}

public final class ClockTimerStore {
    private let defaults: UserDefaults
    private let key = "FloatingClock.timers.v1"
    private let recoveryKey = "FloatingClock.timers.v1.recovered"
    private var usesRecoverySnapshot: Bool?
    private var damagedSnapshot: Any?
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [ClockTimer] {
        let snapshot = defaults.object(forKey: recoveryKey)
        guard let archive = snapshot ?? defaults.object(forKey: key) else {
            usesRecoverySnapshot = false
            damagedSnapshot = nil
            return []
        }
        let decoded = (archive as? Data).flatMap { try? JSONDecoder().decode(TimerArchive.self, from: $0) }
        var ids = Set<UUID>()
        let uniqueTimers = (decoded?.timers ?? []).filter { ids.insert($0.id).inserted }
        let damaged = decoded == nil || decoded?.hasInvalidRecords == true ||
            uniqueTimers.count != decoded?.timers.count || uniqueTimers.count > 3
        usesRecoverySnapshot = snapshot != nil || damaged
        // Preserve a damaged recovery snapshot too, before a subsequent save replaces it.
        damagedSnapshot = snapshot != nil && damaged ? archive : nil
        return Array(uniqueTimers.prefix(3))
    }

    public func save(_ timers: [ClockTimer]) {
        if usesRecoverySnapshot == nil { _ = load() }
        guard let data = try? JSONEncoder().encode(Array(timers.prefix(3))) else { return }
        if usesRecoverySnapshot == true {
            if let damagedSnapshot {
                defaults.set(damagedSnapshot, forKey: "\(recoveryKey).backup.\(UUID().uuidString)")
                self.damagedSnapshot = nil
            }
            defaults.set(data, forKey: recoveryKey)
        } else {
            defaults.set(data, forKey: key)
        }
    }
}

private struct TimerArchive: Decodable {
    let timers: [ClockTimer]
    let hasInvalidRecords: Bool

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var timers: [ClockTimer] = []
        var hasInvalidRecords = false
        while !container.isAtEnd {
            let record = try container.superDecoder()
            if let timer = try? ClockTimer(from: record), timer.isValid {
                timers.append(timer)
            } else {
                hasInvalidRecords = true
            }
        }
        self.timers = timers
        self.hasInvalidRecords = hasInvalidRecords
    }
}
