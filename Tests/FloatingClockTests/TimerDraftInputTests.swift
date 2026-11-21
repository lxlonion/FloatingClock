import AppKit
import XCTest
import ClockCore
@testable import FloatingClock

private final class DraftNotifications: TimerNotificationScheduling {
    private(set) var scheduled: [ClockTimer] = []

    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        scheduled.append(timer)
        completion(nil)
    }

    func cancel(_ id: UUID) {}
}

private final class DraftSession {
    let window: NSWindow
    let coordinator: TimerCoordinator
    let notifications = DraftNotifications()
    let row: TimerRowView
    private let suite = "FloatingClock.timerDraft.\(UUID())"
    private let defaults: UserDefaults

    var timer: ClockTimer { coordinator.timers[0] }
    var savedTimer: ClockTimer? { ClockTimerStore(defaults: defaults).load().first }

    init(input: String, mode: ClockTimerMode = .countdown, kind: ClockTimerInput = .duration, now: Date) throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let frame = NSRect(x: 0, y: 0, width: 284, height: 120)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let tray = TimerTrayView(frame: frame)
        window.contentView = tray
        var draft = ClockTimer()
        draft.input = input
        draft.mode = mode
        draft.inputKind = kind
        ClockTimerStore(defaults: defaults).save([draft])
        coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: notifications,
                                       now: { now }, instant: { TimerInstant(uptime: 100, bootID: "draft-input") })
        tray.coordinator = coordinator
        let settings = ClockSettings()
        coordinator.onChange = { [weak tray] in tray?.refresh(settings: settings) }
        coordinator.restore()
        tray.layout()
        row = try XCTUnwrap(tray.rows.first)
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func focus(_ input: TimerNumberInput) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(input.field))
        input.field.selectText(nil)
        return try XCTUnwrap(input.field.currentEditor() as? NSTextView)
    }

    func enter(_ text: String, in input: TimerNumberInput) throws -> NSTextView {
        let editor = try focus(input)
        editor.insertText(text, replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, text)
        return editor
    }

    func leaveEditing() {
        XCTAssertTrue(window.makeFirstResponder(nil))
    }
}

final class TimerDraftInputTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRestoredSignedDraftsKeepTheirDirectionOnPlayAndReturn() throws {
        let fixtures: [(String, ClockTimerMode, ClockTimerInput, ClockTimerMode, Int, Bool)] = [
            (" \t−5\n", .countdown, .duration, .elapsed, 5, false),
            ("−0", .countdown, .duration, .elapsed, 0, true),
            ("-7", .countdown, .targetTime, .elapsed, 7, true),
            ("+5", .elapsed, .duration, .countdown, 5, false)
        ]
        for (input, savedMode, kind, mode, minutes, pressReturn) in fixtures {
            let session = try DraftSession(input: input, mode: savedMode, kind: kind, now: now)
            let row = session.row
            XCTAssertEqual(row.signButton.title, mode == .elapsed ? "−" : "+", input)
            XCTAssertEqual(row.kindButton.isEnabled, mode == .countdown, input)
            XCTAssertFalse(row.durationInput.isHidden, input)
            XCTAssertEqual(row.durationInput.minutes.value, minutes, input)
            _ = try session.focus(row.durationInput.minutes)
            session.leaveEditing()
            XCTAssertEqual(session.timer.input, input)
            XCTAssertEqual(session.savedTimer?.input, input)
            XCTAssertEqual(session.savedTimer?.mode, savedMode)

            if pressReturn {
                let editor = try session.focus(row.durationInput.minutes)
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                row.primaryButton.performClick(nil)
            }
            let seconds = Double(minutes * 60)
            XCTAssertEqual(session.timer.state, .running, input)
            XCTAssertEqual(session.timer.mode, mode, input)
            XCTAssertEqual(session.timer.inputKind, .duration, input)
            XCTAssertEqual(session.timer.duration, seconds, input)
            XCTAssertEqual(session.timer.accumulated, mode == .elapsed ? seconds : 0, input)
            XCTAssertEqual(session.timer.deadline, mode == .countdown ? now.addingTimeInterval(seconds) : nil, input)
            XCTAssertEqual(session.notifications.scheduled.count, mode == .countdown ? 1 : 0, input)
            XCTAssertEqual(session.savedTimer, session.timer, input)
        }
    }

    func testRestartAfterResetKeepsDirectionOfLegacyDoubleSignedInput() throws {
        let target = try TimerInputParser.targetDate("0:01", now: now)
        let fixtures: [(String, ClockTimerMode, ClockTimerInput, TimeInterval, String)] = [
            ("-+5", .elapsed, .duration, 300, "5"),
            ("− +5", .elapsed, .duration, 300, "5"),
            ("+-0:01", .countdown, .duration, 1, "0:01"),
            ("+-0:01", .countdown, .targetTime, target.timeIntervalSince(now), "0:01")
        ]
        for (input, mode, kind, seconds, savedInput) in fixtures {
            let session = try DraftSession(input: input, kind: kind, now: now)
            let row = session.row
            let deadline = mode == .countdown ? now.addingTimeInterval(seconds) : nil
            for startCount in 1...2 {
                XCTAssertEqual(row.signButton.title, mode == .elapsed ? "−" : "+", input)
                row.primaryButton.performClick(nil)
                XCTAssertEqual(session.timer.state, .running, input)
                XCTAssertEqual(session.timer.mode, mode, input)
                XCTAssertEqual(session.timer.inputKind, kind, input)
                XCTAssertEqual(session.timer.duration, seconds, input)
                XCTAssertEqual(session.timer.accumulated, mode == .elapsed ? seconds : 0, input)
                XCTAssertEqual(session.timer.deadline, deadline, input)
                XCTAssertEqual(session.notifications.scheduled.count, mode == .countdown ? startCount : 0, input)
                XCTAssertEqual(session.savedTimer?.input, savedInput, input)

                row.primaryButton.performClick(nil)
                XCTAssertEqual(session.timer.state, .paused, input)
                row.resetButton.performClick(nil)
                XCTAssertEqual(session.timer.state, .idle, input)
                XCTAssertEqual(session.savedTimer?.mode, mode, input)
            }
        }
    }

    func testEditedLegacyDraftKeepsItsDirectionUntilSignButtonOverridesIt() throws {
        let session = try DraftSession(input: "-5分30.5秒", now: now)
        let row = session.row
        _ = try session.enter("7", in: row.durationInput.minutes)
        session.leaveEditing()
        XCTAssertEqual(session.timer.draft.mode, .elapsed)
        XCTAssertEqual(session.savedTimer?.draft.mode, .elapsed)
        XCTAssertEqual(try TimerInputParser.duration(session.timer.draft.text), 450.5)
        XCTAssertEqual(row.signButton.title, "−")

        row.signButton.performClick(nil)
        XCTAssertEqual(session.savedTimer?.input, "450.5秒")
        XCTAssertEqual(session.savedTimer?.mode, .countdown)
        XCTAssertEqual(row.signButton.title, "+")

        _ = try session.enter("8", in: row.durationInput.minutes)
        row.primaryButton.performClick(nil)
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.mode, .countdown)
        XCTAssertEqual(session.timer.duration, 510.5)
        XCTAssertEqual(session.notifications.scheduled.first?.deadline, now.addingTimeInterval(510.5))
    }

    func testSignButtonChangesLegacyExplicitCountdownToZeroElapsed() throws {
        let session = try DraftSession(input: "+5", mode: .elapsed, now: now)
        XCTAssertEqual(session.row.signButton.title, "+")
        session.row.signButton.performClick(nil)
        XCTAssertEqual(session.row.signButton.title, "−")
        XCTAssertEqual(session.savedTimer?.mode, .elapsed)
        XCTAssertEqual(session.savedTimer?.input, "0")

        session.row.primaryButton.performClick(nil)
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.mode, .elapsed)
        XCTAssertEqual(session.timer.duration, 0)
        XCTAssertTrue(session.notifications.scheduled.isEmpty)
    }

    func testNumberFieldRequiresDirectionButtonAndNormalizesUnsignedMinutes() throws {
        let session = try DraftSession(input: "5", now: now)
        let row = session.row
        for text in ["-5", "−5", "+5"] {
            let editor = try session.focus(row.durationInput.minutes)
            editor.insertText(text, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "5")
        }
        session.leaveEditing()

        row.signButton.performClick(nil)
        _ = try session.enter("90", in: row.durationInput.minutes)
        session.leaveEditing()
        XCTAssertEqual(session.savedTimer?.input, "5400.0秒")
        XCTAssertEqual(session.savedTimer?.mode, .elapsed)
        let refreshed = expectation(description: "Deferred field update")
        DispatchQueue.main.async { refreshed.fulfill() }
        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(row.durationInput.hours.value, 1)
        XCTAssertEqual(row.durationInput.minutes.value, 30)
    }

    func testOversizedDurationSurvivesFocusStartAndResetUntilEdited() throws {
        let raw = "\t999998分钟30.5秒\n"
        let session = try DraftSession(input: raw, now: now)
        let row = session.row
        let seconds = try TimerInputParser.duration(raw)
        XCTAssertEqual(row.durationInput.preservedDuration, seconds)
        _ = try session.focus(row.durationInput.hours)
        session.leaveEditing()
        XCTAssertEqual(session.savedTimer?.input, raw)

        row.primaryButton.performClick(nil)
        XCTAssertEqual(session.timer.duration, seconds)
        row.primaryButton.performClick(nil)
        row.resetButton.performClick(nil)
        XCTAssertEqual(row.durationInput.preservedDuration, seconds)

        let editor = try session.enter("1", in: row.durationInput.hours)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.duration, 3600 + 9999 * 60 + 30.5)
        XCTAssertEqual(session.savedTimer, session.timer)
    }

    func testTinyFractionalSecondsStillStartAfterEditingMinutesToZero() throws {
        let session = try DraftSession(input: "1分钟0.00001秒", now: now)
        let editor = try session.enter("0", in: session.row.durationInput.minutes)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.duration, 0.00001, accuracy: 1e-12)
        XCTAssertEqual(session.savedTimer, session.timer)
    }

    func testExplicitTargetDateAndSecondsSurviveFocusAndMinuteEdit() throws {
        let future = now.addingTimeInterval(172_837)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = formatter.string(from: future)
        let raw = " \t+\(text)\n"
        let session = try DraftSession(input: raw, mode: .elapsed, kind: .targetTime, now: now)
        let row = session.row
        XCTAssertEqual(row.signButton.title, "+")
        XCTAssertEqual(row.targetInput.targetDetail, text)
        XCTAssertFalse(row.nextTargetButton.isHidden)
        let originalMinute = row.targetInput.minutes.value
        _ = try session.focus(row.targetInput.minutes)
        session.leaveEditing()
        XCTAssertEqual(session.savedTimer?.input, raw)

        let nextMinute = (originalMinute + 1) % 60
        let expected = future.addingTimeInterval(Double(nextMinute - originalMinute) * 60)
        let editor = try session.enter(String(nextMinute), in: row.targetInput.minutes)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.mode, .countdown)
        XCTAssertEqual(session.timer.inputKind, .targetTime)
        XCTAssertEqual(session.timer.input, formatter.string(from: expected))
        XCTAssertEqual(session.timer.deadline, expected)
        XCTAssertEqual(session.notifications.scheduled.first?.deadline, expected)
    }

    func testKindButtonPreservesLegacyExplicitCountdownWhenSwitchingToDuration() throws {
        let session = try DraftSession(input: "+12:34:56", mode: .elapsed, kind: .targetTime, now: now)
        XCTAssertEqual(session.row.targetInput.targetDetail, "12:34:56")
        session.row.kindButton.performClick(nil)
        XCTAssertFalse(session.row.durationInput.isHidden)
        XCTAssertEqual(session.row.signButton.title, "+")
        XCTAssertEqual(session.savedTimer?.mode, .countdown)
        XCTAssertEqual(session.savedTimer?.inputKind, .duration)
        XCTAssertEqual(session.savedTimer?.input, "5")
        session.row.primaryButton.performClick(nil)
        XCTAssertEqual(session.timer.state, .running)
        XCTAssertEqual(session.timer.deadline, now.addingTimeInterval(300))
    }
}
