import AppKit
import ClockCore
import Darwin
import UserNotifications

protocol TimerNotificationScheduling: AnyObject {
    func beginRecovery()
    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void)
    func cancel(_ id: UUID)
    func endRecovery()
    func preserveDueNotification(_ id: UUID)
}

extension TimerNotificationScheduling {
    func beginRecovery() {}
    func endRecovery() {}
    func preserveDueNotification(_ id: UUID) {}
}

// This boundary keeps the production scheduling path testable without requesting system permission.
protocol TimerNotificationCenter: AnyObject {
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void)
    func delivered(_ completion: @escaping ([String]) -> Void)
    func authorize(_ completion: @escaping (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

private final class SystemTimerNotificationCenter: TimerNotificationCenter {
    let center = UNUserNotificationCenter.current()
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { center.getPendingNotificationRequests(completionHandler: completion) }
    func delivered(_ completion: @escaping ([String]) -> Void) { center.getDeliveredNotifications { completion($0.map { $0.request.identifier }) } }
    func authorize(_ completion: @escaping (Bool, Error?) -> Void) { center.requestAuthorization(options: [.alert, .sound], completionHandler: completion) }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) { center.add(request, withCompletionHandler: completion) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

final class TimerNotifications: NSObject, TimerNotificationScheduling, UNUserNotificationCenterDelegate {
    private let center: TimerNotificationCenter
    private let now: () -> Date
    private let continuousTime: () -> TimeInterval
    private var generations: [UUID: UUID] = [:]
    private var known: [UUID: Set<String>] = [:]
    private var recovering = false
    private var dueIDs: Set<UUID> = []
    private var inFlight: Set<String> = []
    private var knownFireDates: [String: Date] = [:]
    private var knownContinuousFireTimes: [String: TimeInterval] = [:]
    private var recoveryOperations: [UUID: (ClockTimer?, ((String?) -> Void)?, (TimeInterval, TimeInterval)?)] = [:]

    override convenience init() {
        let system = SystemTimerNotificationCenter()
        self.init(center: system)
        system.center.delegate = self
    }

    init(center: TimerNotificationCenter, now: @escaping () -> Date = Date.init,
         continuousTime: @escaping () -> TimeInterval = TimerNotifications.systemContinuousTime) {
        self.center = center
        self.now = now
        self.continuousTime = continuousTime
        super.init()
    }

    private static func systemContinuousTime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    func beginRecovery() { recovering = true }

    func preserveDueNotification(_ id: UUID) { dueIDs.insert(id) }

    func endRecovery() {
        center.pending { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                for request in requests {
                    if let id = self.timerID(request.identifier) {
                        self.known[id, default: []].insert(request.identifier)
                        let fire = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() ??
                            (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                        self.knownFireDates[request.identifier] = fire
                        if request.trigger is UNTimeIntervalNotificationTrigger, let fire {
                            self.knownContinuousFireTimes[request.identifier] = self.continuousTime() + fire.timeIntervalSince(self.now())
                        }
                    }
                }
                self.recovering = false
                let operations = self.recoveryOperations
                self.recoveryOperations.removeAll()
                // Requests for timers that are no longer running are obsolete. Do not erase delivered alerts.
                for id in Array(self.known.keys) where operations[id] == nil && !self.dueIDs.contains(id) {
                    self.center.removePending(Array(self.known.removeValue(forKey: id) ?? []))
                }
                for (id, operation) in operations {
                    guard let timer = operation.0, let completion = operation.1 else { self.cancel(id); continue }
                    let candidates = requests.filter { self.known[id]?.contains($0.identifier) == true }
                    let anchor = operation.2!
                    let recoveryDeadline = timer.inputKind == .targetTime ? timer.deadline! :
                        self.now().addingTimeInterval(anchor.0 - max(0, self.continuousTime() - anchor.1))
                    if let match = candidates.first(where: {
                        let fire = ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() ??
                            ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                        guard let fire else { return false }
                        return abs(fire.timeIntervalSince(recoveryDeadline)) < 1 && self.bodyMatches($0.content.body, timer: timer, deadline: recoveryDeadline)
                    }) {
                        let extras = (self.known[id] ?? []).subtracting([match.identifier])
                        self.center.removePending(Array(extras))
                        self.known[id] = [match.identifier]
                        completion(nil)
                    } else {
                        self.schedulePrepared(timer, completion: completion, remaining: anchor.0, scheduledAt: anchor.1)
                    }
                }
            }
        }
    }

    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        guard let deadline = timer.deadline else { return }
        let remaining = deadline.timeIntervalSince(now())
        let scheduledAt = continuousTime()
        if recovering { recoveryOperations[timer.id] = (timer, completion, (remaining, scheduledAt)); return }
        schedulePrepared(timer, completion: completion, remaining: remaining, scheduledAt: scheduledAt)
    }

    private func schedulePrepared(_ timer: ClockTimer, completion: @escaping (String?) -> Void,
                                  remaining: TimeInterval, scheduledAt: TimeInterval) {
        guard let deadline = timer.deadline else { return }
        let generation = UUID()
        // Replacing an existing identifier lets the system replace it atomically, including
        // if the process exits before the add callback arrives.
        let requestID = (known[timer.id] ?? []).first(where: { !inFlight.contains($0) }) ?? identifier(timer.id, generation: generation)
        generations[timer.id] = generation
        center.authorize { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self, self.generations[timer.id] == generation else { return }
                guard granted, error == nil else {
                    completion("通知未开启，请在系统设置的「通知」中允许漂浮时钟。")
                    return
                }
                if self.oldHasFired(requestID) {
                    completion(nil)
                    return
                }
                let delay = timer.inputKind == .targetTime ? deadline.timeIntervalSince(self.now()) :
                    remaining - max(0, self.continuousTime() - scheduledAt)
                let content = UNMutableNotificationContent()
                content.title = "时间到了"
                content.body = self.body(for: timer, deadline: deadline)
                content.sound = .default
                let trigger: UNNotificationTrigger?
                if delay <= 0 {
                    // Authorization can finish after the deadline. With no old request to
                    // deliver the alert, request immediate delivery instead of losing it.
                    trigger = nil
                } else if timer.inputKind == .targetTime {
                    // Round up fractional seconds so a notification never fires early.
                    let fire = Date(timeIntervalSince1970: ceil(deadline.timeIntervalSince1970))
                    var calendar = Calendar.current
                    calendar.timeZone = .current
                    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
                    components.calendar = calendar
                    components.timeZone = calendar.timeZone
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                } else {
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
                }
                let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
                self.inFlight.insert(requestID)
                self.center.add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.inFlight.remove(requestID)
                        guard self.generations[timer.id] == generation else {
                            // A reused old identifier remains protected until its successor succeeds.
                            if self.known[timer.id]?.contains(requestID) == true { return }
                            self.center.removePending([requestID])
                            self.center.removeDelivered([requestID])
                            return
                        }
                        if let error { completion("通知安排失败：\(error.localizedDescription)"); return }
                        let old = self.known[timer.id] ?? []
                        if self.oldHasFired(requestID) {
                            // A successful replacement may have beaten the old firing, or the old
                            // notification may already be delivered. Only suppress a duplicate in
                            // the latter case; blindly removing it here would lose the alert.
                            self.center.delivered { [weak self] delivered in
                                DispatchQueue.main.async {
                                    guard let self, self.generations[timer.id] == generation else { return }
                                    if delivered.contains(requestID) { self.center.removePending([requestID]) }
                                }
                            }
                        }
                        self.known[timer.id] = [requestID]
                        self.knownFireDates[requestID] = deadline
                        self.knownContinuousFireTimes[requestID] = timer.inputKind == .duration ? scheduledAt + remaining : nil
                        self.center.removePending(Array(old.subtracting([requestID])))
                        completion(nil)
                    }
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        generations[id] = nil
        if recovering { dueIDs.remove(id); recoveryOperations[id] = (nil, nil, nil); return }
        let identifiers = Array(known.removeValue(forKey: id) ?? [])
        center.removePending(identifiers)
        center.removeDelivered(identifiers)
    }

    private func oldHasFired(_ id: String) -> Bool {
        if let fire = knownContinuousFireTimes[id] { return fire <= continuousTime() }
        if let fire = knownFireDates[id] { return fire <= now() }
        return false
    }

    private func bodyMatches(_ body: String, timer: ClockTimer, deadline: Date) -> Bool {
        if body == self.body(for: timer, deadline: deadline) { return true }
        guard timer.inputKind == .targetTime, body == "已到达设定时间 \(timer.input)。" else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["HH:mm", "HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if formatter.string(from: deadline) == timer.input { return true }
        }
        return false
    }

    private func body(for timer: ClockTimer, deadline: Date) -> String {
        guard timer.inputKind == .targetTime else {
            return "\(TimerDisplayFormat.hoursMinutes.string(seconds: timer.duration, countingDown: true)) 的倒计时已结束。"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let fire = Date(timeIntervalSince1970: ceil(deadline.timeIntervalSince1970))
        let seconds = Calendar.current.component(.second, from: fire)
        formatter.dateFormat = seconds == 0 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss"
        return "已到达设定时间 \(formatter.string(from: fire))。"
    }

    private func identifier(_ id: UUID, generation: UUID) -> String { "FloatingClock.timer.\(id.uuidString).\(generation.uuidString)" }
    private func timerID(_ identifier: String) -> UUID? {
        let prefix = "FloatingClock.timer."
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), UUID(uuidString: String(parts[1])) != nil else { return nil }
        return id
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

final class TimerCoordinator {
    private(set) var timers: [ClockTimer]
    private(set) var errors: [UUID: String] = [:]
    private var notificationErrors: [UUID: String] = [:]
    private var notificationGenerations: [UUID: UUID] = [:]
    var notificationMessage: String? { timers.compactMap { notificationErrors[$0.id] }.first }
    var onChange: (() -> Void)?
    private let store: ClockTimerStore
    private let notifications: TimerNotificationScheduling
    private var ticker: Timer?

    init(store: ClockTimerStore = ClockTimerStore(), notifications: TimerNotificationScheduling) {
        self.store = store
        self.notifications = notifications
        timers = store.load()
    }

    func restore(at now: Date = Date()) {
        notifications.beginRecovery()
        for index in timers.indices {
            if let deadline = timers[index].deadline, deadline <= now { notifications.preserveDueNotification(timers[index].id) }
            timers[index].finishIfNeeded(at: now)
            if timers[index].state == .running { schedule(timers[index]) }
        }
        notifications.endRecovery()
        changed()
    }

    @discardableResult func add() -> UUID? {
        guard timers.count < 3 else { return nil }
        let timer = ClockTimer()
        timers.append(timer)
        changed()
        return timer.id
    }

    func remove(_ id: UUID) {
        notifications.cancel(id)
        notificationGenerations[id] = nil
        timers.removeAll { $0.id == id }
        errors[id] = nil
        notificationErrors[id] = nil
        changed()
    }

    func editInput(_ id: UUID, text: String) {
        guard let index = editableIndex(id) else { return }
        timers[index].input = text
        errors[id] = nil
        changed()
    }

    func toggleMode(_ id: UUID) {
        guard let index = editableIndex(id) else { return }
        let mode: ClockTimerMode = timers[index].countsDown ? .elapsed : .countdown
        notifications.cancel(id)
        notificationGenerations[id] = nil
        notificationErrors[id] = nil
        timers[index].reset()
        timers[index].mode = mode
        if timers[index].mode == .elapsed {
            timers[index].inputKind = .duration
            timers[index].input = "0"
        }
        errors[id] = nil
        changed()
    }

    func setInputKind(_ id: UUID, kind: ClockTimerInput, at now: Date = Date(), calendar: Calendar = .current) {
        guard let index = editableIndex(id) else { return }
        guard timers[index].inputKind != kind else { return }
        notifications.cancel(id)
        notificationGenerations[id] = nil
        notificationErrors[id] = nil
        timers[index].reset()
        timers[index].inputKind = kind
        if kind == .targetTime {
            timers[index].mode = .countdown
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "HH:mm"
            timers[index].input = formatter.string(from: now.addingTimeInterval(60))
        } else { timers[index].input = timers[index].mode == .elapsed ? "0" : "5" }
        errors[id] = nil
        changed()
    }

    func primaryAction(_ id: UUID, at now: Date = Date()) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        errors[id] = nil
        switch timers[index].state {
        case .running:
            timers[index].pause(at: now)
            if !timers[index].isOvertime {
                notifications.cancel(id)
                notificationGenerations[id] = nil
                notificationErrors[id] = nil
            }
        case .paused:
            timers[index].resume(at: now)
            schedule(timers[index])
        case .idle, .completed:
            do {
                try timers[index].start(at: now)
                schedule(timers[index])
            } catch { errors[id] = error.localizedDescription }
        }
        changed()
    }

    func reset(_ id: UUID) {
        guard let index = editableIndex(id) else { return }
        notifications.cancel(id)
        notificationGenerations[id] = nil
        timers[index].reset()
        errors[id] = nil
        notificationErrors[id] = nil
        changed()
    }

    func tick(at now: Date = Date()) {
        var completed = false
        for index in timers.indices {
            if timers[index].finishIfNeeded(at: now) { completed = true }
        }
        if completed { changed() } else { onChange?() }
    }

    private func editableIndex(_ id: UUID) -> Int? {
        guard let index = timers.firstIndex(where: { $0.id == id }), timers[index].state != .running else { return nil }
        return index
    }

    private func schedule(_ timer: ClockTimer) {
        guard timer.deadline != nil else { return }
        let generation = UUID()
        notificationGenerations[timer.id] = generation
        notificationErrors[timer.id] = nil
        notifications.schedule(timer) { [weak self] message in
            guard let self, self.notificationGenerations[timer.id] == generation,
                  self.timers.contains(where: { $0.id == timer.id }) else { return }
            self.notificationErrors[timer.id] = message
            self.onChange?()
        }
    }

    private func changed() {
        store.save(timers)
        if timers.contains(where: { $0.state == .running }) {
            if ticker == nil {
                let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
                timer.tolerance = 0.04
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        onChange?()
    }

    deinit { ticker?.invalidate() }
}
