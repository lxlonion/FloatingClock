import AppKit
import ClockCore
import UserNotifications

protocol TimerNotificationScheduling: AnyObject {
    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void)
    func cancel(_ id: UUID)
}

final class TimerNotifications: NSObject, TimerNotificationScheduling, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var generations: [UUID: UUID] = [:]

    override init() {
        super.init()
        center.delegate = self
        center.getPendingNotificationRequests { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                let active = Set(self.generations.map { self.identifier($0.key, generation: $0.value) })
                let stale = requests.map(\.identifier).filter { $0.hasPrefix("FloatingClock.timer.") && !active.contains($0) }
                self.center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
    }

    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        guard let deadline = timer.deadline else { return }
        cancel(timer.id)
        let generation = UUID()
        let requestID = identifier(timer.id, generation: generation)
        generations[timer.id] = generation
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self, self.generations[timer.id] == generation else { return }
                guard granted, error == nil else {
                    completion("通知未开启，请在系统设置的「通知」中允许漂浮时钟。")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "时间到了"
                content.body = timer.inputKind == .targetTime ? "已到达设定时间 \(timer.input)。" :
                    "\(TimerDisplayFormat.hoursMinutes.string(seconds: timer.duration, countingDown: true)) 的倒计时已结束。"
                content.sound = .default
                let delay = deadline.timeIntervalSinceNow
                let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
                let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
                self.center.add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.generations[timer.id] == generation else {
                            // Deletion/stop can race the asynchronous notification registration.
                            self.center.removePendingNotificationRequests(withIdentifiers: [requestID])
                            self.center.removeDeliveredNotifications(withIdentifiers: [requestID])
                            return
                        }
                        completion(error == nil ? nil : "通知安排失败：\(error!.localizedDescription)")
                    }
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let generation = generations.removeValue(forKey: id) else { return }
        let requestID = identifier(id, generation: generation)
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private func identifier(_ id: UUID, generation: UUID) -> String { "FloatingClock.timer.\(id.uuidString).\(generation.uuidString)" }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Owns timekeeping independently of the clock's visibility and drawing timer.
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
        for index in timers.indices {
            timers[index].finishIfNeeded(at: now)
            if timers[index].state == .running { schedule(timers[index]) }
        }
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
            // A click at/after the deadline must not withdraw an already due notification.
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
