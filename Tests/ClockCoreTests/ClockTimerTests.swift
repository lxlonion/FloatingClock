import XCTest
@testable import ClockCore

final class ClockTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDurationAcceptsLongMinutesMixedUnitsAndColonNotation() throws {
        for text in ["90", "90分钟", "1小时30min", "1h 30m", "90:00", "1:30:00", "1.5小时"] {
            XCTAssertEqual(try TimerInputParser.duration(text), 5400, text)
        }
        XCTAssertEqual(try TimerInputParser.duration("1分30秒"), 90)
        XCTAssertEqual(try TimerInputParser.duration("0"), 0)
        XCTAssertEqual(try TimerInputParser.duration("0.5"), 30)
    }

    func testDurationRejectsMalformedAndUnboundedValues() {
        for text in ["", "abc", "1hgarbage", "-5", "1:60", "1:99:00", "NaN", "inf", "1e999", "1000000", "999999999999999:00", "1小时-1分钟"] {
            XCTAssertThrowsError(try TimerInputParser.duration(text), text)
        }
    }

    func testCountdownRoundsUpThenRunsOvertimeAndTransitionsOnce() throws {
        var timer = ClockTimer()
        timer.input = "2秒"
        try timer.start(at: now)
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(2))
        XCTAssertEqual(TimerDisplayFormat.totalMinutes.string(seconds: timer.seconds(at: now.addingTimeInterval(1.2)), countingDown: true), "00分01秒")
        XCTAssertFalse(timer.finishIfNeeded(at: now.addingTimeInterval(1.99)))
        XCTAssertTrue(timer.finishIfNeeded(at: now.addingTimeInterval(2)))
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(100)), 98)
        XCTAssertEqual(timer.state, .running)
        XCTAssertTrue(timer.isOvertime)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.finishIfNeeded(at: now.addingTimeInterval(100)))
    }


    func testOvertimeStopResumeAndResetPreserveOriginalInput() throws {
        var timer = ClockTimer()
        timer.input = "1分钟"
        try timer.start(at: now)
        // Stopping before the UI's next tick must first account for the crossing.
        timer.pause(at: now.addingTimeInterval(75))
        XCTAssertTrue(timer.isOvertime)
        XCTAssertEqual(timer.state, .paused)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(500)), 15)
        timer.resume(at: now.addingTimeInterval(500))
        XCTAssertNil(timer.deadline)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(510)), 25)
        timer.reset()
        XCTAssertFalse(timer.isOvertime)
        XCTAssertTrue(timer.countsDown)
        XCTAssertEqual(timer.input, "1分钟")
        try timer.start(at: now)
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(60))
    }

    func testOvertimeSurvivesSerializationAndLateWakeKeepsFullOverrun() throws {
        var timer = ClockTimer()
        timer.input = "1"
        try timer.start(at: now)
        var restored = try JSONDecoder().decode(ClockTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertTrue(restored.finishIfNeeded(at: now.addingTimeInterval(3600)))
        XCTAssertEqual(restored.seconds(at: now.addingTimeInterval(3600)), 3540)
        let overtime = try JSONDecoder().decode(ClockTimer.self, from: JSONEncoder().encode(restored))
        XCTAssertTrue(overtime.isOvertime)
        XCTAssertNil(overtime.deadline)
        XCTAssertEqual(overtime.seconds(at: now.addingTimeInterval(3660)), 3600)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timer)) as! [String: Any]
        json.removeValue(forKey: "overtime")
        let legacy = try JSONDecoder().decode(ClockTimer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.isOvertime)
        XCTAssertEqual(legacy.deadline, now.addingTimeInterval(60))
    }

    func testStoppingExactlyAtZeroKeepsOvertimePaused() throws {
        var timer = ClockTimer()
        timer.input = "1秒"
        try timer.start(at: now)
        timer.pause(at: now.addingTimeInterval(1))
        XCTAssertTrue(timer.isOvertime)
        XCTAssertEqual(timer.state, .paused)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(20)), 0)
        timer.resume(at: now.addingTimeInterval(20))
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(21)), 1)
    }

    func testNegativeZeroStartsElapsedAndStopResumePreservesElapsedTime() throws {
        var timer = ClockTimer()
        timer.input = "-0"
        try timer.start(at: now)
        XCTAssertEqual(timer.mode, .elapsed)
        XCTAssertNil(timer.deadline)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(90)), 90)
        timer.pause(at: now.addingTimeInterval(90))
        XCTAssertEqual(timer.state, .paused)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(900)), 90)
        timer.resume(at: now.addingTimeInterval(900))
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(910)), 100)
        XCTAssertFalse(timer.finishIfNeeded(at: now.addingTimeInterval(100_000)))
    }

    func testCountdownStopResumeSchedulesOnlyRemainingTime() throws {
        var timer = ClockTimer()
        timer.input = "90"
        try timer.start(at: now)
        timer.pause(at: now.addingTimeInterval(60))
        XCTAssertNil(timer.deadline)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(600)), 5340)
        timer.resume(at: now.addingTimeInterval(600))
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(5940))
    }

    func testZeroCountdownFailsWithoutChangingRunningState() throws {
        var timer = ClockTimer()
        timer.input = "0"
        XCTAssertThrowsError(try timer.start(at: now))
        XCTAssertEqual(timer.state, .idle)
        timer.mode = .elapsed
        try timer.start(at: now)
        XCTAssertEqual(timer.seconds(at: now), 0)
    }

    func testElapsedCanStartFromNonzeroAndUnicodeMinus() throws {
        var timer = ClockTimer()
        timer.input = "−1小时30min"
        try timer.start(at: now)
        XCTAssertEqual(timer.mode, .elapsed)
        XCTAssertEqual(timer.seconds(at: now.addingTimeInterval(30)), 5430)
        timer.reset()
        XCTAssertEqual(timer.state, .idle)
        XCTAssertEqual(timer.seconds(at: now), 0)
    }

    func testTargetTimeRollsToTomorrowAndExplicitPastDateFails() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-11-15T23:30:00+08:00")!
        XCTAssertEqual(try TimerInputParser.targetDate("00:15", now: date, calendar: calendar), formatter.date(from: "2026-11-16T00:15:00+08:00")!)
        XCTAssertEqual(try TimerInputParser.targetDate("23:30:10", now: date, calendar: calendar).timeIntervalSince(date), 10)
        XCTAssertEqual(try TimerInputParser.targetDate("2026-11-16 09:00", now: date, calendar: calendar), formatter.date(from: "2026-11-16T09:00:00+08:00")!)
        for text in ["2026-11-14 09:00", "24:00", "12:60", "12:00:99", "2026-02-30 09:00"] {
            XCTAssertThrowsError(try TimerInputParser.targetDate(text, now: date, calendar: calendar), text)
        }
    }

    func testTargetTimerUsesDeadlineAndSurvivesLongSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var timer = ClockTimer()
        timer.inputKind = .targetTime
        timer.input = "2030-01-01 12:00"
        try timer.start(at: now, calendar: calendar)
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.deadline, try TimerInputParser.targetDate(timer.input, now: now, calendar: calendar))
        XCTAssertTrue(timer.finishIfNeeded(at: now.addingTimeInterval(1_000_000_000)))
        XCTAssertEqual(timer.state, .running)
        XCTAssertTrue(timer.isOvertime)
    }

    func testDisplayFormatAndLegacyPreferenceMigration() throws {
        XCTAssertEqual(TimerDisplayFormat.totalMinutes.string(seconds: 5400, countingDown: true), "90分00秒")
        XCTAssertEqual(TimerDisplayFormat.hoursMinutes.string(seconds: 5400, countingDown: true), "1时30分00秒")
        XCTAssertEqual(TimerDisplayFormat.totalMinutes.string(seconds: 0, countingDown: false), "00分00秒")
        XCTAssertEqual(TimerDisplayFormat.totalMinutes.string(seconds: 59.9, countingDown: false), "00分59秒")
        let legacy = try JSONDecoder().decode(ClockSettings.self, from: Data(#"{"transparency":63}"#.utf8))
        XCTAssertEqual(legacy.timerDisplayFormat, .totalMinutes)
        var settings = legacy
        settings.timerDisplayFormat = .hoursMinutes
        XCTAssertEqual(try JSONDecoder().decode(ClockSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testTimerStoreRestoresActiveTimersAndCapsAtThree() throws {
        let suite = "FloatingClock.timerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var timer = ClockTimer()
        timer.input = "90"
        try timer.start(at: now)
        let store = ClockTimerStore(defaults: defaults)
        store.save([timer, ClockTimer(), ClockTimer(), ClockTimer()])
        let restored = store.load()
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored[0], timer)
        XCTAssertEqual(restored[0].seconds(at: now.addingTimeInterval(3600)), 1800)
        defaults.set(Data("invalid".utf8), forKey: "FloatingClock.timers.v1")
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAttachmentGrowsAwayFromScreenEdgesAndCollapsesToOriginalDial() {
        let screen = CGRect(x: -1920, y: 1080, width: 1920, height: 1080)
        for (y, above) in [(1100.0, true), (1850.0, false)] {
            let dial = CGRect(x: -1800, y: y, width: 248, height: 248)
            let layout = TimerAttachmentLayout(clock: dial, trayHeight: 254, screen: screen)
            XCTAssertEqual(layout.isAbove, above)
            XCTAssertTrue(screen.contains(layout.frame))
            XCTAssertEqual(layout.dialFrame.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY), dial)
            XCTAssertEqual(layout.trayFrame.height, 254)
            XCTAssertEqual(TimerAttachmentLayout(clock: dial, trayHeight: 0, screen: screen).frame, dial)
        }
    }

    func testSmallDialExpandsToUsableRowWidthAndStaysOnDisplay() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        for x in [0.0, 1276] {
            let layout = TimerAttachmentLayout(clock: CGRect(x: x, y: 600, width: 164, height: 164), trayHeight: 254, screen: screen)
            XCTAssertEqual(layout.frame.width, 284)
            XCTAssertTrue(screen.contains(layout.frame))
            XCTAssertTrue(layout.frame.contains(layout.dialFrame.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)))
        }
    }
}
