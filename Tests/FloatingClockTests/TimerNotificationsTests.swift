import XCTest
import ClockCore
import UserNotifications
@testable import FloatingClock

private final class FakeNotificationCenter: TimerNotificationCenter {
    var requests: [String: UNNotificationRequest] = [:]
    var pendingCallback: (([UNNotificationRequest]) -> Void)?
    var addCallback: ((Error?) -> Void)?
    var added: UNNotificationRequest?
    var delayAuthorization = false
    var authorizationCallback: ((Bool, Error?) -> Void)?
    var removed: [String] = []
    var deliveredIDs: [String] = []
    func pending(_ completion: @escaping ([UNNotificationRequest]) -> Void) { pendingCallback = completion }
    func delivered(_ completion: @escaping ([String]) -> Void) { completion(deliveredIDs) }
    func authorize(_ completion: @escaping (Bool, Error?) -> Void) {
        if delayAuthorization { authorizationCallback = completion } else { completion(true, nil) }
    }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) { added = request; addCallback = completion }
    func removePending(_ identifiers: [String]) { removed += identifiers; identifiers.forEach { requests[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) {}
    func finishPending() { pendingCallback?(Array(requests.values)); pendingCallback = nil }
    func finishAdd(_ error: Error? = nil) {
        if error == nil, let added { requests[added.identifier] = added }
        addCallback?(error)
        addCallback = nil
    }
}

final class TimerNotificationsTests: XCTestCase {
    private func flush() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
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
        let old = oldRequest(timer)
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
