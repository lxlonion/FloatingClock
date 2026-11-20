import XCTest
import ClockCore
import UserNotifications
@testable import FloatingClock

private final class FakeNotificationCenter: TimerNotificationCenter {
    var requests: [String: UNNotificationRequest] = [:]
    var pendingCallback: (([UNNotificationRequest]) -> Void)?
    var addCallback: ((Error?) -> Void)?
    var added: UNNotificationRequest?
    var commitsAtAdd = false
    var delayAuthorization = false
    var authorizationCallback: ((Bool, Error?) -> Void)?
    var removed: [String] = []
    var deliveredIDs: [String] = []
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { pendingCallback = completion }
    func delivered(_ completion: @escaping ([String]) -> Void) { completion(deliveredIDs) }
    func authorize(_ completion: @escaping (Bool, Error?) -> Void) {
        if delayAuthorization { authorizationCallback = completion } else { completion(true, nil) }
    }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        added = request
        if commitsAtAdd { requests[request.identifier] = request }
        addCallback = completion
    }
    func removePending(_ identifiers: [String]) { removed += identifiers; identifiers.forEach { requests[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) { deliveredIDs.removeAll { identifiers.contains($0) } }
    func finishPending() { pendingCallback?(Array(requests.values)); pendingCallback = nil }
    func finishAdd(_ error: Error? = nil) {
        if error == nil, let added { requests[added.identifier] = added }
        addCallback?(error)
        addCallback = nil
    }
}

final class TimerNotificationsTests: XCTestCase {
    private func flush() {
        for _ in 0..<5 {
            let done = expectation(description: "main queue")
            DispatchQueue.main.async { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    private func running() throws -> ClockTimer {
        var timer = ClockTimer()
        timer.input = "10"
        try timer.start(at: Date())
        return timer
    }

    private func oldRequest(_ timer: ClockTimer, offset: TimeInterval = 0) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = "10分00秒 的倒计时已结束。"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timer.deadline!.timeIntervalSinceNow + offset, repeats: false)
        return UNNotificationRequest(identifier: "FloatingClock.timer.\(timer.id.uuidString).\(UUID().uuidString)", content: content, trigger: trigger)
    }

    func testRecoveryAdoptsMatchingRequestAndKeepsItWithoutAuthorization() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let legacy = oldRequest(timer)
        let content = UNMutableNotificationContent()
        content.body = legacy.content.body
        content.userInfo = ["FloatingClock.deadline.v1": timer.deadline!.timeIntervalSince1970, "FloatingClock.kind.v1": timer.inputKind.rawValue]
        let old = UNNotificationRequest(identifier: legacy.identifier, content: content, trigger: legacy.trigger)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        center.finishPending()
        flush()
        XCTAssertNotNil(center.requests[old.identifier])
        XCTAssertNil(center.added)
        scheduler.cancel(timer.id)
        XCTAssertNil(center.requests[old.identifier])
    }

    func testReplacementFailureRetainsOldRequestAndSuccessCleansIt() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer, offset: 30)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        center.finishPending()
        flush(); flush()
        XCTAssertNotNil(center.requests[old.identifier])
        center.finishAdd(NSError(domain: "test", code: 1))
        flush()
        XCTAssertNotNil(center.requests[old.identifier])
        scheduler.schedule(timer) { _ in }
        flush()
        center.finishAdd()
        flush()
        XCTAssertEqual(center.added?.identifier, old.identifier)
        XCTAssertNotNil(center.requests[old.identifier])
    }

    func testCancelBeforeRecoveryAndLateAddDoNotLeaveNotifications() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer, offset: 30)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        scheduler.cancel(timer.id)
        center.finishPending()
        flush()
        XCTAssertNil(center.requests[old.identifier])
        scheduler.schedule(timer) { _ in }
        flush()
        scheduler.cancel(timer.id)
        center.finishAdd()
        flush()
        XCTAssertNil(center.requests[center.added!.identifier])
    }

    func testLateReplacementCallbackChecksWhetherOldRequestWasDelivered() throws {
        for oldWasDelivered in [false, true] {
            let timer = try running()
            let center = FakeNotificationCenter()
            let content = UNMutableNotificationContent()
            content.body = "old"
            let old = UNNotificationRequest(identifier: "FloatingClock.timer.\(timer.id.uuidString).\(UUID().uuidString)", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.requests[old.identifier] = old
            let scheduler = TimerNotifications(center: center)
            scheduler.beginRecovery()
            scheduler.schedule(timer) { _ in }
            scheduler.endRecovery()
            center.finishPending()
            flush(); flush()
            XCTAssertNotNil(center.addCallback)
            let passed = expectation(description: "old deadline passes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { passed.fulfill() }
            wait(for: [passed], timeout: 3)
            if oldWasDelivered { center.deliveredIDs = [old.identifier] }
            center.finishAdd()
            flush(); flush()
            XCTAssertEqual(center.requests[old.identifier] != nil, !oldWasDelivered)
        }
    }

    func testDueRequestSurvivesRecoveryUntilExplicitRemoval() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.preserveDueNotification(timer.id)
        scheduler.endRecovery()
        center.finishPending()
        flush()
        XCTAssertNotNil(center.requests[old.identifier])
        scheduler.cancel(timer.id)
        XCTAssertNil(center.requests[old.identifier])
    }

    func testQuittingBeforeRecoveryLeavesOldRequestIntact() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer)
        center.requests[old.identifier] = old
        var scheduler: TimerNotifications? = TimerNotifications(center: center)
        scheduler!.beginRecovery()
        scheduler!.schedule(timer) { _ in }
        scheduler!.endRecovery()
        scheduler = nil
        center.finishPending()
        flush()
        XCTAssertNotNil(center.requests[old.identifier])
    }

    func testDurationAuthorizationDelayUsesContinuousTimeAcrossWallClockJumps() throws {
        for wallJump: TimeInterval in [-3600, 3600] {
            let timer = try running()
            let center = FakeNotificationCenter()
            center.delayAuthorization = true
            var wall = Date()
            var continuous: TimeInterval = 100
            let scheduler = TimerNotifications(center: center, now: { wall }, continuousTime: { continuous })
            scheduler.schedule(timer) { _ in }
            wall = wall.addingTimeInterval(wallJump)
            continuous += 10
            center.authorizationCallback?(true, nil)
            flush()
            let trigger = try XCTUnwrap(center.added?.trigger as? UNTimeIntervalNotificationTrigger)
            XCTAssertEqual(trigger.timeInterval, 590, accuracy: 1)
        }
    }

    func testRecoveryWaitAndAuthorizationShareContinuousAnchor() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        center.delayAuthorization = true
        var wall = Date()
        var continuous: TimeInterval = 100
        let scheduler = TimerNotifications(center: center, now: { wall }, continuousTime: { continuous })
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        wall = wall.addingTimeInterval(3600)
        continuous += 10
        center.finishPending()
        flush()
        wall = wall.addingTimeInterval(-7200)
        continuous += 5
        center.authorizationCallback?(true, nil)
        flush()
        let trigger = try XCTUnwrap(center.added?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 585, accuracy: 1)
    }

    func testAuthorizationFinishingAfterDeadlineRequestsImmediateDelivery() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        center.delayAuthorization = true
        var continuous: TimeInterval = 100
        let scheduler = TimerNotifications(center: center, continuousTime: { continuous })
        scheduler.schedule(timer) { _ in }
        continuous += 700
        center.authorizationCallback?(true, nil)
        flush()
        XCTAssertNotNil(center.added)
        XCTAssertNil(center.added?.trigger)
    }

    func testResumedTargetBodyShowsNextDay() throws {
        let center = FakeNotificationCenter()
        let scheduler = TimerNotifications(center: center)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: Date().addingTimeInterval(86400))!
        var timer = ClockTimer()
        timer.inputKind = .targetTime
        timer.input = "23:59:30"
        try timer.start(at: start, calendar: calendar)
        timer.pause(at: start.addingTimeInterval(60))
        timer.resume(at: start.addingTimeInterval(1200))
        scheduler.schedule(timer) { _ in }
        flush()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertTrue(center.added!.content.body.contains(formatter.string(from: timer.deadline!)))
        XCTAssertEqual(calendar.component(.hour, from: timer.deadline!), 0)
    }

    func testCancelRemovesAlreadyCommittedAddBeforeCallback() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        center.commitsAtAdd = true
        let scheduler = TimerNotifications(center: center)
        scheduler.schedule(timer) { _ in }
        flush()
        let id = try XCTUnwrap(center.added?.identifier)
        XCTAssertNotNil(center.requests[id])
        scheduler.cancel(timer.id)
        XCTAssertNil(center.requests[id])
        center.finishAdd()
        flush()
        XCTAssertNil(center.requests[id])
    }

    func testLegacyIntervalWithoutMetadataIsReplacedEvenIfQueryLooksMatching() throws {
        let timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        center.finishPending()
        flush()
        XCTAssertNotNil(center.added)
        XCTAssertNotNil(center.requests[old.identifier])
        XCTAssertEqual(center.added?.content.userInfo["FloatingClock.deadline.v1"] as? Double,
                       timer.deadline!.timeIntervalSince1970)
    }

    func testRecoveryStopThenResumeCancelsOldRequestBeforeNewOne() throws {
        var timer = try running()
        let center = FakeNotificationCenter()
        let old = oldRequest(timer)
        center.requests[old.identifier] = old
        let scheduler = TimerNotifications(center: center)
        scheduler.beginRecovery()
        scheduler.schedule(timer) { _ in }
        scheduler.endRecovery()
        scheduler.cancel(timer.id)
        let paused = Date().addingTimeInterval(10)
        timer.pause(at: paused)
        timer.resume(at: paused.addingTimeInterval(120))
        scheduler.schedule(timer) { _ in }
        center.finishPending()
        flush()
        XCTAssertNil(center.requests[old.identifier])
        let replacement = try XCTUnwrap(center.added)
        XCTAssertNotEqual(replacement.identifier, old.identifier)
        center.finishAdd()
        flush()
        XCTAssertNotNil(center.requests[replacement.identifier])
    }

    func testDeliveredOldRequestBeforeSnapshotOrDuringAuthorizationIsNotDuplicated() throws {
        for beforeSnapshot in [false, true] {
            var wall = Date()
            var continuous: TimeInterval = 100
            var timer = ClockTimer()
            timer.input = "5s"
            try timer.start(at: wall.addingTimeInterval(-4))
            let center = FakeNotificationCenter()
            center.delayAuthorization = true
            let old = oldRequest(timer)
            center.requests[old.identifier] = old
            let scheduler = TimerNotifications(center: center, now: { wall }, continuousTime: { continuous })
            scheduler.beginRecovery()
            scheduler.schedule(timer) { _ in }
            scheduler.endRecovery()
            if beforeSnapshot {
                center.requests[old.identifier] = nil
                center.deliveredIDs = [old.identifier]
            }
            center.finishPending()
            flush()
            if !beforeSnapshot {
                center.requests[old.identifier] = nil
                center.deliveredIDs = [old.identifier]
            }
            wall = wall.addingTimeInterval(2)
            continuous += 2
            center.authorizationCallback?(true, nil)
            flush()
            XCTAssertNil(center.added)
            XCTAssertTrue(center.deliveredIDs.contains(old.identifier))
        }
    }

    func testCoordinatorPreservesPendingOvertimeForRunningAndPausedTimers() throws {
        for paused in [false, true] {
            let now = Date()
            var timer = ClockTimer()
            timer.input = "1s"
            try timer.start(at: now.addingTimeInterval(-2))
            if paused { timer.pause(at: now) } else { timer.finishIfNeeded(at: now) }
            let suite = "FloatingClock.notification-overtime.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ClockTimerStore(defaults: defaults)
            store.save([timer])
            let content = UNMutableNotificationContent()
            let old = UNNotificationRequest(identifier: "FloatingClock.timer.\(timer.id.uuidString).\(UUID().uuidString)", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            let center = FakeNotificationCenter()
            center.requests[old.identifier] = old
            let scheduler = TimerNotifications(center: center, now: { now })
            let coordinator = TimerCoordinator(store: store, notifications: scheduler)
            coordinator.restore(at: now)
            center.finishPending()
            flush()
            XCTAssertNotNil(center.requests[old.identifier])
        }
    }

    func testSecondNewYorkFallbackHourUsesUnambiguousUTCComponents() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(utc.date(from: DateComponents(year: 2027, month: 11, day: 7, hour: 4, minute: 30)))
        var timer = ClockTimer()
        timer.inputKind = .targetTime
        timer.input = "01:30"
        try timer.start(at: start, calendar: local)
        timer.pause(at: start)
        timer.resume(at: start.addingTimeInterval(3600))
        XCTAssertEqual(timer.deadline, utc.date(from: DateComponents(year: 2027, month: 11, day: 7, hour: 6, minute: 30)))
        let center = FakeNotificationCenter()
        let scheduler = TimerNotifications(center: center, now: { start })
        scheduler.schedule(timer) { _ in }
        flush()
        let trigger = try XCTUnwrap(center.added?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(), 0)
        XCTAssertEqual(trigger.dateComponents.hour, 6)
        XCTAssertEqual(trigger.dateComponents.minute, 30)
        XCTAssertEqual(trigger.nextTriggerDate(), timer.deadline)
    }

    func testTargetBodyUsesResumedDeadlineIncludingSecondsAndDate() throws {
        let center = FakeNotificationCenter()
        let scheduler = TimerNotifications(center: center)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: Date().addingTimeInterval(86400))!
        var timer = ClockTimer()
        timer.inputKind = .targetTime
        timer.input = "18:40"
        try timer.start(at: start, calendar: calendar)
        timer.pause(at: start.addingTimeInterval(120))
        timer.resume(at: start.addingTimeInterval(720))
        scheduler.schedule(timer) { _ in }
        flush()
        XCTAssertTrue(center.added!.content.body.contains("18:50"))
        XCTAssertTrue(center.added!.trigger is UNCalendarNotificationTrigger)
        timer.pause(at: start.addingTimeInterval(721))
        timer.resume(at: start.addingTimeInterval(722))
        scheduler.schedule(timer) { _ in }
        flush()
        XCTAssertTrue(center.added!.content.body.contains("18:50:01"))
    }
}
