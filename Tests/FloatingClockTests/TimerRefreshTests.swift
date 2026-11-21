import AppKit
import ClockCore
import XCTest
@testable import FloatingClock

private final class RefreshClock {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var wallOffset: TimeInterval = 0
    var continuousOffset: TimeInterval = 0
    private(set) var wallSamples = 0
    private(set) var continuousSamples = 0

    func now() -> Date {
        wallSamples += 1
        return start.addingTimeInterval(wallOffset)
    }

    func instant() -> TimerInstant {
        continuousSamples += 1
        return TimerInstant(uptime: 100 + continuousOffset, bootID: "timer-refresh")
    }

    func advance(by seconds: TimeInterval) {
        wallOffset = seconds
        continuousOffset = seconds
    }
}

private final class RefreshNotifications: TimerNotificationScheduling {
    var completion: ((String?) -> Void)?

    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func cancel(_ id: UUID) {}
}

private final class RefreshSession {
    private let suite = "FloatingClock.timerRefresh.\(UUID())"
    private let defaults: UserDefaults
    let clock = RefreshClock()
    let notifications = RefreshNotifications()
    let coordinator: TimerCoordinator
    let panel: ClockPanel
    private(set) var fullRefreshes = 0

    var savedTimers: [ClockTimer] { ClockTimerStore(defaults: defaults).load() }

    init() throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        coordinator = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: notifications,
                                       now: clock.now, instant: clock.instant)
        panel = ClockPanel(settings: ClockSettings())
        panel.timerCoordinator = coordinator
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.fullRefreshes += 1
            self.panel.refreshTimers()
        }
        coordinator.restore()
    }

    func addRow(input: String? = nil) throws -> TimerRowView {
        let id = try XCTUnwrap(coordinator.add())
        if let input { coordinator.editInput(id, text: input) }
        return try XCTUnwrap(panel.timerTray.rows.first(where: { $0.id == id }))
    }

    deinit {
        panel.hideClock()
        defaults.removePersistentDomain(forName: suite)
    }
}

final class TimerRefreshTests: XCTestCase {
    func testOrdinaryTicksWriteOnlyChangedReadoutsAndPreserveEditing() throws {
        let session = try RefreshSession()
        let panel = session.panel
        panel.layoutScreenFrameOverride = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let running = try session.addRow(input: "8秒")
        session.coordinator.primaryAction(running.id)
        let paused = try session.addRow(input: "3秒")
        session.coordinator.primaryAction(paused.id)
        session.coordinator.primaryAction(paused.id)
        let idle = try session.addRow()
        panel.showClock()
        panel.face.layoutSubtreeIfNeeded()
        let field = idle.durationInput.minutes.field
        XCTAssertTrue(panel.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("19", replacementRange: editor.selectedRange())
        let selection = NSRange(location: 1, length: 1)
        editor.setSelectedRange(selection)

        var writes: [String] = []
        let runningObserver = running.timeField.observe(\.stringValue) { field, _ in writes.append(field.stringValue) }
        let pausedObserver = paused.timeField.observe(\.stringValue) { field, _ in writes.append(field.stringValue) }
        let idleObserver = idle.timeField.observe(\.stringValue) { field, _ in writes.append(field.stringValue) }
        defer { withExtendedLifetime((runningObserver, pausedObserver, idleObserver)) {} }

        let fullRefreshes = session.fullRefreshes
        let wallSamples = session.clock.wallSamples
        let continuousSamples = session.clock.continuousSamples
        let windowFrame = panel.frame
        let clipBounds = panel.timerTray.scrollView.contentView.bounds
        let buttonFrame = panel.addTimerButton.frame.offsetBy(dx: 1, dy: 0)
        panel.addTimerButton.frame = buttonFrame
        panel.timerTray.needsLayout = false

        for offset in [0.2, 0.4, 0.6, 0.8] {
            session.clock.advance(by: offset)
            session.coordinator.tick()
        }
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(panel.timerTray.needsLayout)

        session.clock.advance(by: 1.2)
        session.coordinator.tick()
        XCTAssertEqual(writes, ["00分07秒"])
        XCTAssertEqual(session.fullRefreshes, fullRefreshes)
        XCTAssertEqual(session.clock.wallSamples - wallSamples, 5)
        XCTAssertEqual(session.clock.continuousSamples - continuousSamples, 5)
        XCTAssertEqual(panel.frame, windowFrame)
        XCTAssertEqual(panel.timerTray.scrollView.contentView.bounds, clipBounds)
        XCTAssertEqual(panel.addTimerButton.frame, buttonFrame)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.string, "19")
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testTickUsesContinuousTimeForDurationsAndWallTimeForTargets() throws {
        let session = try RefreshSession()
        let duration = try session.addRow(input: "2")
        session.coordinator.primaryAction(duration.id)
        let target = try session.addRow()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        session.coordinator.setInputKind(target.id, kind: .targetTime, at: session.clock.start)
        session.coordinator.editInput(target.id, text: formatter.string(from: session.clock.start.addingTimeInterval(30)))
        session.coordinator.primaryAction(target.id)
        session.panel.showClock()

        let fullRefreshes = session.fullRefreshes
        let wallSamples = session.clock.wallSamples
        let continuousSamples = session.clock.continuousSamples
        session.clock.wallOffset = 5
        session.clock.continuousOffset = 2
        session.coordinator.tick()

        XCTAssertEqual(duration.timeField.stringValue, "01分58秒")
        XCTAssertEqual(target.timeField.stringValue, "00分25秒")
        XCTAssertEqual(session.fullRefreshes, fullRefreshes)
        XCTAssertEqual(session.clock.wallSamples - wallSamples, 1)
        XCTAssertEqual(session.clock.continuousSamples - continuousSamples, 1)
        let savedDuration = try XCTUnwrap(session.savedTimers.first(where: { $0.id == duration.id }))
        XCTAssertEqual(savedDuration.startedAt, session.clock.start.addingTimeInterval(5))
        XCTAssertEqual(savedDuration.accumulated, 2)

        session.panel.hideClock()
        session.clock.wallOffset = 6
        session.clock.continuousOffset = 3
        session.coordinator.tick()
        XCTAssertEqual(duration.timeField.stringValue, "01分58秒")
        XCTAssertEqual(target.timeField.stringValue, "00分25秒")
        session.panel.showClock()
        XCTAssertEqual(duration.timeField.stringValue, "01分57秒")
        XCTAssertEqual(target.timeField.stringValue, "00分24秒")
        XCTAssertEqual(session.fullRefreshes, fullRefreshes)
    }

    func testShowingAfterDeadlineRefreshesAndPersistsOvertimeThenReportsErrors() throws {
        let session = try RefreshSession()
        let row = try session.addRow(input: "2秒")
        session.coordinator.primaryAction(row.id)
        XCTAssertEqual(row.signButton.title, "+")
        XCTAssertEqual(row.statusLabel.stringValue, "倒计时中 · 到时通知")
        session.panel.showClock()
        session.panel.hideClock()

        let fullRefreshes = session.fullRefreshes
        let wallSamples = session.clock.wallSamples
        let continuousSamples = session.clock.continuousSamples
        session.clock.advance(by: 7)
        session.panel.showClock()

        XCTAssertEqual(session.fullRefreshes, fullRefreshes + 1)
        XCTAssertEqual(session.clock.wallSamples - wallSamples, 1)
        XCTAssertEqual(session.clock.continuousSamples - continuousSamples, 1)
        let saved = try XCTUnwrap(session.savedTimers.first)
        XCTAssertEqual(saved.state, .running)
        XCTAssertTrue(saved.isOvertime)
        XCTAssertEqual(row.timeField.stringValue, "00分05秒")
        XCTAssertEqual(row.signButton.title, "−")
        XCTAssertEqual(row.statusLabel.stringValue, "时间到了 · 正在累计超时")
        XCTAssertTrue(session.panel.timerTray.notice.isHidden)

        let report = try XCTUnwrap(session.notifications.completion)
        report("通知未开启")
        XCTAssertEqual(session.fullRefreshes, fullRefreshes + 2)
        XCTAssertFalse(session.panel.timerTray.notice.isHidden)
        XCTAssertEqual(session.panel.timerTray.notice.toolTip, "通知未开启")
        session.coordinator.primaryAction(row.id)
        XCTAssertEqual(session.fullRefreshes, fullRefreshes + 3)
        XCTAssertEqual(row.statusLabel.stringValue, "超时已停止 · 可继续")
        XCTAssertFalse(row.resetButton.isHidden)
    }
}
