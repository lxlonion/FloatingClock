import Foundation
import Darwin
import ClockCore
import UserNotifications

// A file-backed stand-in for the OS: it outlives either application process.
final class DiskCenter: TimerNotificationCenter {
    let path: URL
    var callback: (([UNNotificationRequest]) -> Void)?
    init(_ path: URL) { self.path = path }
    func read() -> [String: Any] { (NSDictionary(contentsOf: path) as? [String: Any]) ?? [:] }
    func write(_ data: [String: Any]) { precondition((data as NSDictionary).write(to: path, atomically: true)) }
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { callback = completion }
    func finishPending() {
        let entries = read()
        let requests = entries.map { id, _ in UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)) }
        callback?(requests)
        callback = nil
    }
    func delivered(_ completion: @escaping ([TimerDeliveredNotification]) -> Void) { completion([]) }
    func authorize(_ completion: @escaping (Bool, Error?) -> Void) { completion(true, nil) }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        var entries = read(); entries[request.identifier] = true; write(entries); completion(nil)
    }
    func removePending(_ identifiers: [String]) {
        var entries = read(); identifiers.forEach { entries.removeValue(forKey: $0) }; write(entries)
    }
    func removeDelivered(_ identifiers: [String]) {}
}
func flush() {
    for _ in 0..<8 {
        var done = false
        DispatchQueue.main.async { done = true }
        while !done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
let args = CommandLine.arguments
precondition(args.count == 5)
let stage = args[1], suite = args[2], directory = URL(fileURLWithPath: args[3]), action = args[4]
let defaults = UserDefaults(suiteName: suite)!
let center = DiskCenter(directory.appendingPathComponent("requests.plist"))
let store = ClockTimerStore(defaults: defaults)
if stage == "start" {
    let scheduler = TimerNotifications(center: center)
    let coordinator = TimerCoordinator(store: store, notifications: scheduler)
    let id = coordinator.add()!
    coordinator.primaryAction(id)
    flush()
    precondition(center.read().count == 1)
    if action.hasPrefix("legacy-") || action.hasPrefix("observed-") {
        let current = center.read().keys.first!
        let prefix = current.split(separator: ".").dropLast().joined(separator: ".")
        center.write(["\(prefix).\(UUID().uuidString)": true])
    }
    defaults.synchronize()
} else if stage == "observe" {
    let scheduler = TimerNotifications(center: center)
    let coordinator = TimerCoordinator(store: store, notifications: scheduler)
    coordinator.restore()
    center.finishPending()
    flush()
    precondition(!store.loadNotificationRequestIndex().isEmpty)
    precondition(center.read().count == 1)
} else if stage == "verify" {
    precondition(center.read().isEmpty)
    defaults.removePersistentDomain(forName: suite)
} else {
    let scheduler = TimerNotifications(center: center)
    let coordinator = TimerCoordinator(store: store, notifications: scheduler)
    let id = coordinator.timers.first!.id
    coordinator.restore()
    if action.hasSuffix("pause") { coordinator.primaryAction(id) }
    if action.hasSuffix("delete") { coordinator.remove(id) }
    if action.hasPrefix("observed-") {
        // Simulate a force quit before the pending callback can run.
        precondition(center.read().isEmpty)
        fflush(nil)
        _exit(0)
    }
    if action == "keep" {
        precondition(!coordinator.prepareForTermination {})
        precondition(center.read().count == 1)
    } else {
        // The normal new-format identifier is removable before the pending reply.
        precondition(center.read().count == (action.hasPrefix("legacy-") ? 1 : 0))
        var replied = false
        precondition(coordinator.prepareForTermination { replied = true })
        precondition(!replied)
        center.finishPending()
        flush()
        precondition(replied && center.read().isEmpty)
    }
    defaults.removePersistentDomain(forName: suite)
}
print("PASS process \(stage) \(action)")
