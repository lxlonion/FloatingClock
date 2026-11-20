import AppKit
import ClockCore
import Darwin
import UserNotifications

protocol TimerNotificationScheduling: AnyObject {
    func configure(store: ClockTimerStore, timers: [ClockTimer])
    func track(_ timer: ClockTimer)
    func beginRecovery()
    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void)
    func cancel(_ id: UUID)
    func endRecovery()
    func preserveDueNotification(_ id: UUID)
    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool
}

extension TimerNotificationScheduling {
    func configure(store: ClockTimerStore, timers: [ClockTimer]) {}
    func track(_ timer: ClockTimer) {}
    func beginRecovery() {}
    func endRecovery() {}
    func preserveDueNotification(_ id: UUID) {}
    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool { false }
}

// This boundary keeps the production scheduling path testable without requesting system permission.
struct TimerDeliveredNotification {
    let request: UNNotificationRequest
    let date: Date
}

protocol TimerNotificationCenter: AnyObject {
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void)
    func delivered(_ completion: @escaping ([TimerDeliveredNotification]) -> Void)
    func authorize(_ completion: @escaping (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

private final class SystemTimerNotificationCenter: TimerNotificationCenter {
    let center = UNUserNotificationCenter.current()
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { center.getPendingNotificationRequests(completionHandler: completion) }
    func delivered(_ completion: @escaping ([TimerDeliveredNotification]) -> Void) { center.getDeliveredNotifications { completion($0.map { TimerDeliveredNotification(request: $0.request, date: $0.date) }) } }
    func authorize(_ completion: @escaping (Bool, Error?) -> Void) { center.requestAuthorization(options: [.alert, .sound], completionHandler: completion) }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) { center.add(request, withCompletionHandler: completion) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

final class TimerNotifications: NSObject, TimerNotificationScheduling, UNUserNotificationCenterDelegate {
    private struct Schedule {
        let timer: ClockTimer
        let completion: (String?) -> Void
        let remaining: TimeInterval
        let scheduledAt: TimeInterval
        let isRecovery: Bool
    }

    private let center: TimerNotificationCenter
    private let now: () -> Date
    private let continuousTime: () -> TimeInterval
    private var generations: [UUID: UUID] = [:]
    private var known: [UUID: Set<String>] = [:]
    private var inFlight: [UUID: Set<String>] = [:]
    private var occurrenceIDs: [UUID: UUID] = [:]
    private var indexStore: ClockTimerStore?
    private var requestIndex: [String: [String: [String]]] = [:]
    private var pendingSubmissions: [UUID: UUID] = [:]
    private var drainTimerIDs: Set<UUID> = []
    private var canceledInFlight: Set<String> = []
    private var cancellationDrainRequired = false
    private var terminationWaiters: [() -> Void] = []
    private var recovering = false
    private var dueIDs: Set<UUID> = []
    private var recoverySchedules: [UUID: Schedule] = [:]
    private var recoveryCancellations: Set<UUID> = []
    private var protectedRecoveryRequests: [UUID: Set<String>] = [:]
    private let deadlineKey = "FloatingClock.deadline.v1"
    private let kindKey = "FloatingClock.kind.v1"
    private let occurrenceKey = "FloatingClock.occurrence.v1"

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

    func configure(store: ClockTimerStore, timers: [ClockTimer]) {
        indexStore = store
        let loaded = store.loadNotificationRequestIndex()
        let active = Set(timers.map { $0.id.uuidString })
        for (timerKey, occurrences) in loaded {
            guard let id = UUID(uuidString: timerKey) else { continue }
            for (occurrence, identifiers) in occurrences where UUID(uuidString: occurrence) != nil {
                let valid = identifiers.filter { timerID($0) == id }
                if active.contains(timerKey) {
                    if !valid.isEmpty { requestIndex[timerKey, default: [:]][occurrence] = Array(Set(valid)) }
                } else {
                    center.removePending(valid)
                }
            }
        }
        if requestIndex != loaded { persistIndex() }
        timers.forEach { track($0) }
    }

    func track(_ timer: ClockTimer) {
        occurrenceIDs[timer.id] = timer.notificationOccurrenceID
        guard let occurrences = requestIndex[timer.id.uuidString] else { return }
        let current = timer.notificationOccurrenceID?.uuidString
        let stale = Set(occurrences.filter { $0.key != current }.flatMap { $0.value })
        if !stale.isEmpty {
            center.removePending(Array(stale))
            forget(stale, timerID: timer.id)
        }
    }

    private func persistIndex() { indexStore?.saveNotificationRequestIndex(requestIndex) }

    private func remember(_ identifiers: [String], timer: ClockTimer) {
        guard indexStore != nil, let occurrence = timer.notificationOccurrenceID else { return }
        let stableID = identifier(timer.id, generation: occurrence)
        let extra = identifiers.filter { timerID($0) == timer.id && $0 != stableID }
        guard !extra.isEmpty else { return }
        let timerKey = timer.id.uuidString, occurrenceKey = occurrence.uuidString
        let previous = Set(requestIndex[timerKey]?[occurrenceKey] ?? [])
        let updated = previous.union(extra)
        guard updated != previous else { return }
        requestIndex[timerKey, default: [:]][occurrenceKey] = Array(updated)
        persistIndex()
    }

    private func forget(_ identifiers: Set<String>, timerID id: UUID) {
        guard var occurrences = requestIndex[id.uuidString] else { return }
        for (occurrence, indexed) in occurrences {
            let remaining = indexed.filter { !identifiers.contains($0) }
            if remaining.isEmpty { occurrences.removeValue(forKey: occurrence) }
            else { occurrences[occurrence] = remaining }
        }
        if occurrences.isEmpty { requestIndex.removeValue(forKey: id.uuidString) }
        else { requestIndex[id.uuidString] = occurrences }
        persistIndex()
    }

    func beginRecovery() { recovering = true }
    func preserveDueNotification(_ id: UUID) { dueIDs.insert(id) }

    func endRecovery() {
        center.pending { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                for request in requests {
                    if let id = self.timerID(request.identifier) { self.known[id, default: []].insert(request.identifier) }
                }
                // Do not wait for the delivered query before canceling a pending
                // request: it could fire while that unrelated callback is delayed.
                for id in self.recoveryCancellations { self.removeKnown(id) }
                for (id, schedule) in self.recoverySchedules where !self.recoveryCancellations.contains(id) {
                    self.remember(Array(self.known[id] ?? []), timer: schedule.timer)
                }
                // Include delivered requests that disappeared before the pending snapshot.
                self.center.delivered { [weak self] delivered in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.finishRecovery(requests: requests, delivered: delivered)
                    }
                }
            }
        }
    }

    private func finishRecovery(requests: [UNNotificationRequest], delivered: [TimerDeliveredNotification]) {
        let available = Set(requests.map(\.identifier) + delivered.map { $0.request.identifier })
            .union(inFlight.values.flatMap { $0 })
        for (timerKey, occurrences) in requestIndex {
            guard let id = UUID(uuidString: timerKey) else { continue }
            let missing = Set(occurrences.values.flatMap { $0 }).subtracting(available)
            if !missing.isEmpty { forget(missing, timerID: id) }
        }
        recovering = false
        let schedules = recoverySchedules
        let canceled = recoveryCancellations
        recoverySchedules.removeAll()
        recoveryCancellations.removeAll()
        for id in canceled {
            removeKnown(id)
            center.removeDelivered(delivered.map { $0.request.identifier }.filter { timerID($0) == id })
        }
        for id in Array(known.keys) where schedules[id] == nil && !dueIDs.contains(id) {
            center.removePending(Array(known.removeValue(forKey: id) ?? []))
        }
        for (id, schedule) in schedules {
            if canceled.contains(id) {
                submit(schedule)
                continue
            }
            let candidates = requests.filter { known[id]?.contains($0.identifier) == true }
            protectedRecoveryRequests[id] = Set(candidates.filter { isCrediblePending($0, timer: schedule.timer) }.map(\.identifier))
            if let match = candidates.first(where: { matches($0, timer: schedule.timer) }) {
                let extras = (known[id] ?? []).subtracting([match.identifier])
                center.removePending(Array(extras))
                forget(extras, timerID: id)
                known[id] = [match.identifier]
                schedule.completion(nil)
            } else {
                submit(schedule)
            }
        }
        finishCancellationDrainIfPossible()
    }

    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        guard let deadline = timer.deadline else { return }
        track(timer)
        let schedule = Schedule(timer: timer, completion: completion, remaining: deadline.timeIntervalSince(now()),
                                scheduledAt: continuousTime(), isRecovery: recovering && !recoveryCancellations.contains(timer.id))
        if recovering { recoverySchedules[timer.id] = schedule; return }
        submit(schedule)
    }

    private func submit(_ schedule: Schedule) {
        let timer = schedule.timer
        guard let deadline = timer.deadline else { return }
        let generation = UUID()
        let busy = inFlight[timer.id] ?? []
        // The occurrence survives process restarts, so cancellation can identify an
        // installed request without waiting for the system's pending snapshot.
        let stableID = identifier(timer.id, generation: timer.notificationOccurrenceID ?? generation)
        let requestID = (known[timer.id] ?? []).first(where: { !busy.contains($0) })
            ?? (busy.contains(stableID) ? identifier(timer.id, generation: generation) : stableID)
        if let previous = generations[timer.id] { pendingSubmissions.removeValue(forKey: previous) }
        generations[timer.id] = generation
        pendingSubmissions[generation] = timer.id
        center.authorize { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self, self.generations[timer.id] == generation else { return }
                guard granted, error == nil else {
                    self.complete(schedule, generation: generation, message: "通知未开启，请在系统设置的「通知」中允许漂浮时钟。")
                    return
                }
                if schedule.isRecovery {
                    // Check again after authorization: an old alert can fire during either wait.
                    self.center.delivered { [weak self] delivered in
                        DispatchQueue.main.async {
                            guard let self, self.generations[timer.id] == generation else { return }
                            if delivered.contains(where: { self.matchesDelivered($0, timer: timer) }) {
                                self.center.removePending(Array(self.known[timer.id] ?? []))
                                self.known[timer.id] = []
                                self.complete(schedule, generation: generation, message: nil)
                            } else {
                                self.add(schedule, deadline: deadline, requestID: requestID, generation: generation)
                            }
                        }
                    }
                } else {
                    self.add(schedule, deadline: deadline, requestID: requestID, generation: generation)
                }
            }
        }
    }

    private func add(_ schedule: Schedule, deadline: Date, requestID: String, generation: UUID) {
        let timer = schedule.timer
        let delay = timer.inputKind == .targetTime ? deadline.timeIntervalSince(now()) :
            schedule.remaining - max(0, continuousTime() - schedule.scheduledAt)
        if delay <= 0, schedule.isRecovery, !(protectedRecoveryRequests[timer.id] ?? []).isEmpty {
            // A credible pending request can fire after the delivered snapshot. Do not
            // issue an immediate duplicate while the system processes that request.
            complete(schedule, generation: generation, message: nil)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "时间到了"
        content.body = body(for: timer, deadline: deadline)
        content.sound = .default
        // The deadline and kind describe the occurrence; interval nextTriggerDate is not
        // its installation time and must never be used to infer this metadata.
        var metadata: [String: Any] = [deadlineKey: deadline.timeIntervalSince1970, kindKey: timer.inputKind.rawValue]
        if let occurrence = timer.notificationOccurrenceID { metadata[occurrenceKey] = occurrence.uuidString }
        content.userInfo = metadata
        let trigger: UNNotificationTrigger?
        if delay <= 0 {
            trigger = nil
        } else if timer.inputKind == .targetTime {
            let fire = Date(timeIntervalSince1970: ceil(deadline.timeIntervalSince1970))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        }
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
        // Persist an opaque non-derived ID before submitting it to the system.
        remember([requestID], timer: timer)
        inFlight[timer.id, default: []].insert(requestID)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight[timer.id]?.remove(requestID)
                self.canceledInFlight.remove(requestID)
                guard self.generations[timer.id] == generation else {
                    if self.known[timer.id]?.contains(requestID) != true {
                        self.center.removePending([requestID])
                        self.center.removeDelivered([requestID])
                    }
                    self.finishCancellationDrainIfPossible()
                    return
                }
                if let error { self.complete(schedule, generation: generation, message: "通知安排失败：\(error.localizedDescription)"); return }
                let old = self.known[timer.id] ?? []
                self.known[timer.id] = [requestID]
                let obsolete = old.subtracting([requestID])
                self.center.removePending(Array(obsolete))
                self.forget(obsolete, timerID: timer.id)
                if schedule.isRecovery {
                    self.center.delivered { [weak self] delivered in
                        DispatchQueue.main.async {
                            guard let self, self.generations[timer.id] == generation else { return }
                            if delivered.contains(where: { self.matchesDelivered($0, timer: timer) }) {
                                self.center.removePending([requestID])
                            }
                        }
                    }
                }
                self.complete(schedule, generation: generation, message: nil)
            }
        }
    }

    private func complete(_ schedule: Schedule, generation: UUID, message: String?) {
        pendingSubmissions.removeValue(forKey: generation)
        schedule.completion(message)
        finishCancellationDrainIfPossible()
    }

    func cancel(_ id: UUID) {
        if recovering || !(inFlight[id] ?? []).isEmpty {
            cancellationDrainRequired = true
            drainTimerIDs.insert(id)
        }
        if let generation = generations[id] { pendingSubmissions.removeValue(forKey: generation) }
        canceledInFlight.formUnion(inFlight[id] ?? [])
        if let occurrence = occurrenceIDs.removeValue(forKey: id) {
            let stableID = identifier(id, generation: occurrence)
            let indexed = Set(requestIndex[id.uuidString]?[occurrence.uuidString] ?? [])
            let identifiers = indexed.union([stableID])
            center.removePending(Array(identifiers))
            center.removeDelivered(Array(identifiers))
            forget(indexed, timerID: id)
        }
        generations[id] = nil
        protectedRecoveryRequests[id] = nil
        dueIDs.remove(id)
        if recovering {
            recoveryCancellations.insert(id)
            recoverySchedules[id] = nil
        }
        removeKnown(id)
        finishCancellationDrainIfPossible()
    }

    // Only cancellations with unresolved system work defer termination. This also
    // waits for a resumed timer's replacement to be installed before quitting.
    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool {
        guard cancellationDrainRequired else { return false }
        terminationWaiters.append(completion)
        return true
    }

    private func finishCancellationDrainIfPossible() {
        guard cancellationDrainRequired, recoveryCancellations.isEmpty,
              canceledInFlight.isEmpty, !pendingSubmissions.values.contains(where: { drainTimerIDs.contains($0) }) else { return }
        cancellationDrainRequired = false
        drainTimerIDs.removeAll()
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func removeKnown(_ id: UUID) {
        let identifiers = (known.removeValue(forKey: id) ?? []).union(inFlight[id] ?? [])
        center.removePending(Array(identifiers))
        center.removeDelivered(Array(identifiers))
    }

    private func matches(_ request: UNNotificationRequest, timer: ClockTimer) -> Bool {
        guard let deadline = timer.deadline, let occurrence = timer.notificationOccurrenceID,
              request.content.userInfo[occurrenceKey] as? String == occurrence.uuidString,
              request.content.userInfo[kindKey] as? String == timer.inputKind.rawValue,
              request.content.body == body(for: timer, deadline: deadline) else { return false }
        if timer.inputKind == .targetTime {
            guard let stored = request.content.userInfo[deadlineKey] as? Double,
                  abs(stored - deadline.timeIntervalSince1970) < 0.001 else { return false }
            return request.trigger is UNCalendarNotificationTrigger
        }
        // Same occurrence survives a wall-clock reanchor; the interval itself is unchanged.
        return request.trigger is UNTimeIntervalNotificationTrigger
    }

    private func isCrediblePending(_ request: UNNotificationRequest, timer: ClockTimer) -> Bool {
        guard timerID(request.identifier) == timer.id else { return false }
        if let occurrence = request.content.userInfo[occurrenceKey] as? String {
            return occurrence == timer.notificationOccurrenceID?.uuidString
        }
        guard let deadline = timer.legacyNotificationDeadline else { return false }
        let legacyBody = timer.inputKind == .targetTime ? "已到达设定时间 \(timer.input)。" :
            "\(TimerDisplayFormat.hoursMinutes.string(seconds: timer.duration, countingDown: true)) 的倒计时已结束。"
        guard request.content.body == legacyBody || request.content.body == body(for: timer, deadline: deadline) else { return false }
        if let stored = request.content.userInfo[deadlineKey] as? Double,
           abs(stored - deadline.timeIntervalSince1970) >= 0.001 { return false }
        return true
    }

    private func matchesDelivered(_ delivered: TimerDeliveredNotification, timer: ClockTimer) -> Bool {
        let request = delivered.request
        guard timerID(request.identifier) == timer.id else { return false }
        if let requestOccurrence = request.content.userInfo[occurrenceKey] as? String {
            return requestOccurrence == timer.notificationOccurrenceID?.uuidString
        }
        // Legacy requests have no occurrence ID. Only a migrated legacy archive can
        // claim one, and only after its expected deadline with corroborating content.
        guard let deadline = timer.legacyNotificationDeadline, now() >= deadline,
              abs(delivered.date.timeIntervalSince(deadline)) <= 5 else { return false }
        let legacyBody = timer.inputKind == .targetTime ? "已到达设定时间 \(timer.input)。" :
            "\(TimerDisplayFormat.hoursMinutes.string(seconds: timer.duration, countingDown: true)) 的倒计时已结束。"
        guard request.content.body == legacyBody || request.content.body == body(for: timer, deadline: deadline) else { return false }
        if let stored = request.content.userInfo[deadlineKey] as? Double,
           abs(stored - deadline.timeIntervalSince1970) >= 0.001 { return false }
        return true
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
    private let nowProvider: () -> Date
    private let instantProvider: () -> TimerInstant

    init(store: ClockTimerStore = ClockTimerStore(), notifications: TimerNotificationScheduling,
         now: @escaping () -> Date = Date.init, instant: @escaping () -> TimerInstant = TimerInstant.current) {
        self.store = store
        self.notifications = notifications
        self.nowProvider = now
        self.instantProvider = instant
        timers = store.load()
        notifications.configure(store: store, timers: timers)
    }

    func restore() { restore(at: nowProvider(), instant: instantProvider()) }
    func restore(at now: Date) { restore(at: now, instant: nil) }

    private func restore(at now: Date, instant: TimerInstant?) {
        notifications.beginRecovery()
        for index in timers.indices {
            timers[index].prepareNotificationOccurrence()
            notifications.track(timers[index])
            if instant != nil { timers[index].reanchor(at: now, instant: instant) }
            if timers[index].isOvertime || (timers[index].deadline.map { $0 <= now } ?? false) {
                notifications.preserveDueNotification(timers[index].id)
            }
            timers[index].finishIfNeeded(at: now, instant: instant)
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

    func primaryAction(_ id: UUID) { primaryAction(id, at: nowProvider(), instant: instantProvider()) }
    func primaryAction(_ id: UUID, at now: Date) { primaryAction(id, at: now, instant: nil) }

    private func primaryAction(_ id: UUID, at now: Date, instant: TimerInstant?) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        errors[id] = nil
        switch timers[index].state {
        case .running:
            timers[index].pause(at: now, instant: instant)
            if !timers[index].isOvertime {
                notifications.cancel(id)
                notificationGenerations[id] = nil
                notificationErrors[id] = nil
            }
        case .paused:
            timers[index].resume(at: now, instant: instant)
            schedule(timers[index])
        case .idle, .completed:
            do {
                try timers[index].start(at: now, instant: instant)
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

    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool {
        notifications.prepareForTermination(completion)
    }

    func tick() { tick(at: nowProvider(), instant: instantProvider()) }
    func tick(at now: Date) { tick(at: now, instant: nil) }

    private func tick(at now: Date, instant: TimerInstant?) {
        var changedTimer = false
        for index in timers.indices {
            // Persist a fresh wall anchor after a clock change, so recovery on a
            // later boot has the best available estimate of the elapsed time.
            if let instant, timers[index].state == .running, timers[index].inputKind == .duration,
               abs(timers[index].elapsed(at: now, instant: instant) - timers[index].elapsed(at: now)) > 1 {
                timers[index].reanchor(at: now, instant: instant)
                changedTimer = true
            }
            if timers[index].finishIfNeeded(at: now, instant: instant) { changedTimer = true }
        }
        if changedTimer { changed() } else { onChange?() }
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
