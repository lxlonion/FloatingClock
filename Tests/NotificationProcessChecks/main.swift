import ClockCore
import Darwin
import Foundation
import UserNotifications

struct ArchivedRequest: Codable {
    let requestData: Data
    let deliveredAt: Date?

    init(_ request: UNNotificationRequest, deliveredAt: Date? = nil) {
        requestData = try! NSKeyedArchiver.archivedData(withRootObject: request, requiringSecureCoding: true)
        self.deliveredAt = deliveredAt
    }

    var request: UNNotificationRequest {
        try! NSKeyedUnarchiver.unarchivedObject(ofClass: UNNotificationRequest.self, from: requestData)!
    }
}

final class DiskCenter: TimerNotificationCenter {
    let path: URL
    private var pendingCallback: (([UNNotificationRequest]) -> Void)?
    private var authorizationCallback: ((Bool, Error?) -> Void)?
    var delayAuthorization = false
    private(set) var authorizationCount = 0
    private(set) var addCount = 0

    init(_ path: URL) { self.path = path }

    var entries: [ArchivedRequest] {
        get {
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            return try! PropertyListDecoder().decode([ArchivedRequest].self, from: Data(contentsOf: path))
        }
        set { try! PropertyListEncoder().encode(newValue).write(to: path, options: .atomic) }
    }

    var pendingRequests: [UNNotificationRequest] {
        entries.filter { $0.deliveredAt == nil }.map(\.request)
    }

    var deliveredRequests: [TimerDeliveredNotification] {
        entries.compactMap { entry in
            entry.deliveredAt.map { TimerDeliveredNotification(request: entry.request, date: $0) }
        }
    }

    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { pendingCallback = completion }

    func finishPending() {
        let completion = pendingCallback!
        pendingCallback = nil
        completion(pendingRequests)
    }

    func delivered(_ completion: @escaping ([TimerDeliveredNotification]) -> Void) { completion(deliveredRequests) }

    func authorize(_ completion: @escaping (Bool, Error?) -> Void) {
        authorizationCount += 1
        if delayAuthorization { authorizationCallback = completion }
        else { completion(true, nil) }
    }

    func finishAuthorization() {
        let completion = authorizationCallback!
        authorizationCallback = nil
        completion(true, nil)
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        addCount += 1
        entries = entries.filter { $0.deliveredAt != nil || $0.request.identifier != request.identifier }
            + [ArchivedRequest(request)]
        completion(nil)
    }

    func removePending(_ identifiers: [String]) {
        entries = entries.filter { $0.deliveredAt != nil || !identifiers.contains($0.request.identifier) }
    }

    func removeDelivered(_ identifiers: [String]) {
        entries = entries.filter { $0.deliveredAt == nil || !identifiers.contains($0.request.identifier) }
    }

    func deliver(_ request: UNNotificationRequest, at date: Date) {
        removePending([request.identifier])
        entries.append(ArchivedRequest(request, deliveredAt: date))
    }
}

enum Scenario: String {
    case pause, delete, keep
    case legacyPause = "legacy-pause"
    case legacyDelete = "legacy-delete"
    case observedPause = "observed-pause"
    case observedDelete = "observed-delete"
    case durationReanchor = "duration-reanchor"
    case targetAdopt = "target-adopt"
    case sameDelivered = "same-delivered"
    case newSameTime = "new-same-time"
    case newNextDay = "new-next-day"
    case deleteDelivered = "delete-delivered"

    var usesUnindexedRequest: Bool { self == .legacyPause || self == .legacyDelete }
    var usesObservedRequest: Bool { self == .observedPause || self == .observedDelete }
    var pauses: Bool { self == .pause || self == .legacyPause || self == .observedPause }
    var usesTarget: Bool { self == .targetAdopt || self == .sameDelivered || startsNewRun }
    var startsNewRun: Bool { self == .newSameTime || self == .newNextDay }
    var seedsDelivery: Bool { self == .sameDelivered || startsNewRun || self == .deleteDelivered }
}

func flush() {
    for _ in 0..<12 {
        var done = false
        DispatchQueue.main.async { done = true }
        while !done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

let args = CommandLine.arguments
if args.count == 3, args[1] == "cleanup" {
    let defaults = UserDefaults(suiteName: args[2])!
    defaults.removePersistentDomain(forName: args[2])
    precondition(defaults.synchronize())
    exit(EXIT_SUCCESS)
}

precondition(args.count == 5)
let stage = args[1]
let defaults = UserDefaults(suiteName: args[2])!
let center = DiskCenter(URL(fileURLWithPath: args[3]))
let scenario = Scenario(rawValue: args[4])!
let store = ClockTimerStore(defaults: defaults)
let deadlineKey = "FloatingClock.deadline.v1"
let kindKey = "FloatingClock.kind.v1"
let occurrenceKey = "FloatingClock.occurrence.v1"
let start = Date(timeIntervalSince1970: 1_900_000_000)
var wall = start
var uptime: TimeInterval = 100

if stage == "verify" {
    precondition(center.entries.isEmpty)
    precondition(store.loadNotificationRequestIndex().isEmpty)
} else {
    let scheduler = TimerNotifications(center: center, now: { wall }, continuousTime: { uptime })
    let coordinator = TimerCoordinator(store: store, notifications: scheduler, now: { wall },
                                       instant: { TimerInstant(uptime: uptime, bootID: "cross-process-test") })
    switch stage {
    case "start":
        let id = coordinator.add()!
        if scenario.usesTarget {
            coordinator.setInputKind(id, kind: .targetTime, at: start)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            coordinator.editInput(id, text: formatter.string(from: start.addingTimeInterval(60)))
        } else {
            coordinator.editInput(id, text: "60s")
        }
        coordinator.primaryAction(id)
        flush()
        precondition(center.addCount == 1 && center.pendingRequests.count == 1)
        var timer = coordinator.timers[0]
        let occurrence = timer.notificationOccurrenceID!
        let deadline = timer.deadline!
        let request = center.pendingRequests[0]
        precondition(request.content.userInfo[occurrenceKey] as? String == occurrence.uuidString)
        precondition(request.content.userInfo[kindKey] as? String == timer.inputKind.rawValue)
        precondition(request.content.userInfo[deadlineKey] as? Double == deadline.timeIntervalSince1970)
        precondition(!request.content.body.isEmpty)
        if scenario.usesTarget {
            precondition(request.trigger is UNCalendarNotificationTrigger)
        } else {
            precondition(request.trigger is UNTimeIntervalNotificationTrigger)
        }
        if scenario.usesUnindexedRequest || scenario.usesObservedRequest {
            let prefix = request.identifier.split(separator: ".").dropLast().joined(separator: ".")
            let content = request.content.mutableCopy() as! UNMutableNotificationContent
            content.userInfo = [:]
            let old = UNNotificationRequest(identifier: "\(prefix).\(UUID().uuidString)", content: content, trigger: request.trigger)
            center.entries = [ArchivedRequest(old)]
            precondition(store.loadNotificationRequestIndex().isEmpty)
        }
        if scenario.seedsDelivery { center.deliver(request, at: deadline) }
        if scenario.startsNewRun {
            let nextStart = scenario == .newNextDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start
            timer.reset()
            try timer.start(at: nextStart)
            precondition(timer.notificationOccurrenceID != occurrence)
            precondition((timer.deadline == deadline) == (scenario == .newSameTime))
            store.save([timer])
        }
        precondition(defaults.synchronize())
    case "observe":
        let timer = coordinator.timers[0]
        let original = center.pendingRequests[0].identifier
        precondition(store.loadNotificationRequestIndex().isEmpty)
        coordinator.restore()
        center.finishPending()
        flush()
        let index = store.loadNotificationRequestIndex()
        precondition(index[timer.id.uuidString]?[timer.notificationOccurrenceID!.uuidString] == [original])
        precondition(center.addCount == 1 && center.pendingRequests.map(\.identifier) == [original])
    case "restore":
        let timer = coordinator.timers[0]
        let occurrence = timer.notificationOccurrenceID!.uuidString
        let deadline = timer.deadline!
        wall = start.addingTimeInterval(10)
        uptime += 10
        switch scenario {
        case .durationReanchor, .targetAdopt:
            let original = center.pendingRequests[0]
            precondition(original.content.userInfo[occurrenceKey] as? String == occurrence)
            if scenario == .durationReanchor { wall = wall.addingTimeInterval(3600) }
            coordinator.restore()
            let restoredDeadline = coordinator.timers[0].deadline!
            precondition(restoredDeadline.timeIntervalSince(deadline) == (scenario == .durationReanchor ? 3600 : 0))
            precondition(!coordinator.prepareForTermination {})
            center.finishPending()
            flush()
            precondition(center.authorizationCount == 0 && center.addCount == 0)
            precondition(center.pendingRequests.map(\.identifier) == [original.identifier])
        case .sameDelivered, .newSameTime, .newNextDay:
            let original = center.deliveredRequests[0]
            precondition((original.request.content.userInfo[occurrenceKey] as? String == occurrence) == (scenario == .sameDelivered))
            precondition((original.date == deadline) == (scenario != .newNextDay))
            wall = deadline.addingTimeInterval(-1)
            center.delayAuthorization = true
            coordinator.restore()
            center.finishPending()
            flush()
            precondition(center.authorizationCount == 1)
            if scenario != .newNextDay { wall = deadline.addingTimeInterval(1) }
            center.finishAuthorization()
            flush()
            precondition(center.deliveredRequests.map(\.request.identifier) == [original.request.identifier])
            if scenario == .sameDelivered {
                precondition(center.addCount == 0 && center.pendingRequests.isEmpty)
            } else {
                precondition(center.addCount == 1 && center.pendingRequests.count == 1)
                let added = center.pendingRequests[0]
                precondition(added.content.userInfo[occurrenceKey] as? String == occurrence)
                precondition(added.identifier != original.request.identifier)
                precondition(scenario == .newSameTime ? added.trigger == nil : added.trigger is UNCalendarNotificationTrigger)
            }
        case .keep:
            let original = center.pendingRequests[0]
            coordinator.restore()
            precondition(!coordinator.prepareForTermination {})
            precondition(center.pendingRequests.map(\.identifier) == [original.identifier])
        case .pause, .delete, .legacyPause, .legacyDelete, .observedPause, .observedDelete, .deleteDelivered:
            if scenario.usesObservedRequest {
                let index = store.loadNotificationRequestIndex()
                precondition(index[timer.id.uuidString]?[occurrence] == center.pendingRequests.map(\.identifier))
            }
            if scenario == .deleteDelivered { precondition(center.deliveredRequests.count == 1) }
            else { precondition(center.pendingRequests.count == 1) }
            coordinator.restore()
            if scenario.pauses {
                coordinator.primaryAction(timer.id)
                precondition(coordinator.timers[0].state == .paused)
            } else {
                coordinator.remove(timer.id)
                precondition(coordinator.timers.isEmpty)
            }
            precondition(center.deliveredRequests.isEmpty)
            precondition(center.pendingRequests.count == (scenario.usesUnindexedRequest ? 1 : 0))
            if scenario.usesObservedRequest {
                print("PASS process \(stage) \(scenario.rawValue)")
                fflush(nil)
                _exit(EXIT_SUCCESS)
            }
            var replied = false
            precondition(coordinator.prepareForTermination { replied = true } && !replied)
            center.finishPending()
            flush()
            precondition(replied && center.entries.isEmpty && center.addCount == 0)
        }
    default:
        preconditionFailure("unknown stage")
    }
}
print("PASS process \(stage) \(scenario.rawValue)")
