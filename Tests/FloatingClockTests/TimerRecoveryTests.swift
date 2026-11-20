import XCTest
import ClockCore
@testable import FloatingClock

private final class RecoveryNotifications: TimerNotificationScheduling {
    var scheduled: [UUID] = []
    var scheduledTimers: [ClockTimer] = []
    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        scheduled.append(timer.id)
        scheduledTimers.append(timer)
        completion(nil)
    }
    func cancel(_ id: UUID) {}
}

final class TimerRecoveryTests: XCTestCase {
    private let key = "FloatingClock.timers.v1"
    private let recoveryKey = "FloatingClock.timers.v1.recovered"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveClockJumpAndRelaunchScheduleCorrectRemainingTime() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var wall = now
        var uptime: TimeInterval = 100
        let scheduler = RecoveryNotifications()
        var coordinator: TimerCoordinator? = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: scheduler,
            now: { wall }, instant: { TimerInstant(uptime: uptime, bootID: "A") })
        let id = try XCTUnwrap(coordinator!.add())
        coordinator!.editInput(id, text: "60秒")
        coordinator!.primaryAction(id)
        wall = now.addingTimeInterval(3600)
        uptime = 110
        coordinator!.tick()
        XCTAssertFalse(coordinator!.timers[0].isOvertime)
        XCTAssertEqual(coordinator!.timers[0].seconds(at: wall, instant: TimerInstant(uptime: uptime, bootID: "A")), 50)
        coordinator = nil
        wall = now.addingTimeInterval(-3600)
        uptime = 120
        let nextScheduler = RecoveryNotifications()
        let restarted = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: nextScheduler,
            now: { wall }, instant: { TimerInstant(uptime: uptime, bootID: "A") })
        restarted.restore()
        XCTAssertEqual(restarted.timers[0].seconds(at: wall, instant: TimerInstant(uptime: uptime, bootID: "A")), 40)
        XCTAssertEqual(nextScheduler.scheduledTimers.first?.deadline, wall.addingTimeInterval(40))
        uptime = 165
        restarted.tick()
        XCTAssertTrue(restarted.timers[0].isOvertime)
        XCTAssertEqual(restarted.timers[0].seconds(at: wall, instant: TimerInstant(uptime: uptime, bootID: "A")), 5)
    }

    func testLegacyAndNewBootRecoveryUseWallAnchor() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = ClockTimer()
        legacy.input = "60秒"
        try legacy.start(at: now)
        var oldBoot = ClockTimer()
        oldBoot.input = "60秒"
        try oldBoot.start(at: now, instant: TimerInstant(uptime: 100, bootID: "A"))
        ClockTimerStore(defaults: defaults).save([legacy, oldBoot])
        let scheduler = RecoveryNotifications()
        let wall = now.addingTimeInterval(20)
        let coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: scheduler,
            now: { wall }, instant: { TimerInstant(uptime: 200, bootID: "B") })
        coordinator.restore()
        XCTAssertEqual(scheduler.scheduledTimers.map(\.deadline), [wall.addingTimeInterval(40), wall.addingTimeInterval(40)])
        XCTAssertEqual(coordinator.timers.map { $0.seconds(at: wall, instant: TimerInstant(uptime: 205, bootID: "B")) }, [35, 35])
    }

    func testCoordinatorRecoversValidRecordsAndPersistsChangesAcrossRestarts() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var running = ClockTimer()
        running.input = "90"
        try running.start(at: now)
        var paused = ClockTimer()
        paused.input = "20"
        try paused.start(at: now)
        paused.pause(at: now.addingTimeInterval(10))
        let third = ClockTimer()
        let fourth = ClockTimer()
        let originalRecords = try JSONSerialization.jsonObject(with: JSONEncoder().encode([running, paused, third, fourth])) as! [[String: Any]]
        var invalidEnum = originalRecords[0]
        invalidEnum["state"] = "unknown"
        var invalidState = originalRecords[1]
        invalidState["duration"] = -1
        let archive = try JSONSerialization.data(withJSONObject: [invalidEnum, originalRecords[0], invalidState,
                                                                   originalRecords[1], originalRecords[0],
                                                                   originalRecords[2], originalRecords[3]])
        defaults.set(archive, forKey: key)
        let scheduler = RecoveryNotifications()
        var coordinator: TimerCoordinator? = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: scheduler)
        coordinator!.restore(at: now.addingTimeInterval(20))
        XCTAssertEqual(coordinator!.timers.map(\.id), [running.id, paused.id, third.id])
        XCTAssertEqual(scheduler.scheduled, [running.id])
        let recoveredRunning = try XCTUnwrap(coordinator!.timers.first)
        XCTAssertEqual(recoveredRunning.deadline, running.deadline)
        XCTAssertEqual(recoveredRunning.seconds(at: now.addingTimeInterval(20)), 5380)
        XCTAssertEqual(defaults.data(forKey: key), archive)
        coordinator!.remove(paused.id)
        coordinator!.editInput(third.id, text: "12")
        let added = try XCTUnwrap(coordinator!.add())
        coordinator!.editInput(added, text: "7")
        XCTAssertEqual(defaults.data(forKey: key), archive)
        coordinator = nil

        let nextScheduler = RecoveryNotifications()
        var restarted: TimerCoordinator? = TimerCoordinator(store: ClockTimerStore(defaults: UserDefaults(suiteName: suite)!), notifications: nextScheduler)
        restarted!.restore(at: now.addingTimeInterval(30))
        XCTAssertEqual(restarted!.timers.map(\.id), [running.id, third.id, added])
        XCTAssertEqual(restarted!.timers.map(\.input), ["90", "12", "7"])
        let restartedRunning = try XCTUnwrap(restarted!.timers.first)
        XCTAssertEqual(restartedRunning.deadline, running.deadline)
        XCTAssertEqual(restartedRunning.seconds(at: now.addingTimeInterval(30)), 5370)
        XCTAssertEqual(nextScheduler.scheduled, [running.id])
        restarted!.remove(running.id)
        restarted = nil
        let final = TimerCoordinator(store: ClockTimerStore(defaults: UserDefaults(suiteName: suite)!), notifications: RecoveryNotifications())
        final.restore(at: now.addingTimeInterval(40))
        XCTAssertEqual(final.timers.map(\.id), [third.id, added])
        XCTAssertEqual(defaults.data(forKey: key), archive)
    }

    func testMalformedArchiveAndSnapshotArePreservedOnSave() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = Data("not json".utf8)
        defaults.set(archive, forKey: key)
        let coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
        coordinator.restore(at: now)
        XCTAssertEqual(defaults.data(forKey: key), archive)
        let damagedSnapshot = Data("[bad snapshot".utf8)
        defaults.set(damagedSnapshot, forKey: recoveryKey)
        let restarted = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
        restarted.restore(at: now)
        XCTAssertEqual(defaults.data(forKey: key), archive)
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { $0.key.hasPrefix(recoveryKey + ".backup.") && ($0.value as? Data) == damagedSnapshot })
    }

    func testHealthyLegacyArchiveContinuesUsingOriginalKey() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ClockTimer()
        defaults.set(try JSONEncoder().encode([original]), forKey: key)
        let coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
        coordinator.restore(at: now)
        coordinator.editInput(original.id, text: "11")
        let saved = try JSONDecoder().decode([ClockTimer].self, from: XCTUnwrap(defaults.data(forKey: key)))
        XCTAssertEqual(saved.first?.input, "11")
        XCTAssertNil(defaults.data(forKey: recoveryKey))
    }

    func testDuplicateAndExcessRecordsPreserveOriginalArchive() throws {
        let first = ClockTimer()
        let second = ClockTimer()
        let third = ClockTimer()
        let fourth = ClockTimer()
        for records in [[first, first, second], [first, second, third, fourth]] {
            let suite = "FloatingClock.recovery.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = try JSONEncoder().encode(records)
            defaults.set(original, forKey: key)
            let coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
            coordinator.restore(at: now)
            XCTAssertEqual(coordinator.timers.map(\.id), records.count == 3 ? [first.id, second.id] : [first.id, second.id, third.id])
            XCTAssertEqual(defaults.data(forKey: key), original)
            coordinator.remove(first.id)
            let restarted = TimerCoordinator(store: ClockTimerStore(defaults: UserDefaults(suiteName: suite)!), notifications: RecoveryNotifications())
            restarted.restore(at: now)
            XCTAssertFalse(restarted.timers.contains { $0.id == first.id })
            XCTAssertEqual(defaults.data(forKey: key), original)
        }
    }

    func testNonDataArchiveAndSnapshotArePreserved() throws {
        let suite = "FloatingClock.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy non-data value", forKey: key)
        let coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
        coordinator.restore(at: now)
        let added = try XCTUnwrap(coordinator.add())
        XCTAssertEqual(defaults.string(forKey: key), "legacy non-data value")
        let restarted = TimerCoordinator(store: ClockTimerStore(defaults: UserDefaults(suiteName: suite)!), notifications: RecoveryNotifications())
        restarted.restore(at: now)
        XCTAssertEqual(restarted.timers.map(\.id), [added])

        defaults.set(["unexpected", "snapshot"], forKey: recoveryKey)
        let damaged = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: RecoveryNotifications())
        damaged.restore(at: now)
        XCTAssertEqual(defaults.string(forKey: key), "legacy non-data value")
        XCTAssertTrue(defaults.dictionaryRepresentation().contains {
            $0.key.hasPrefix(recoveryKey + ".backup.") && ($0.value as? [String]) == ["unexpected", "snapshot"]
        })
    }
}
