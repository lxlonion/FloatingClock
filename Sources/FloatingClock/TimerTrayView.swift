import AppKit
import ClockCore

final class TimerRowView: NSView {
    let id: UUID
    let signButton = NSButton(title: "+", target: nil, action: nil)
    let timeField = NSTextField(string: "")
    let durationInput = TimerTimeInput(kind: .duration)
    let targetInput = TimerTimeInput(kind: .targetTime)
    let primaryButton = NSButton()
    let deleteButton = NSButton()
    let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let statusLabel = NSTextField(labelWithString: "")
    let resetButton = NSButton(title: "重设", target: nil, action: nil)
    var onSign: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReset: (() -> Void)?
    var onInput: ((String) -> Void)?
    var onKind: ((ClockTimerInput) -> Void)?
    private var currentInputKind: ClockTimerInput = .duration
    private var isIdle = true
    private var isChangingKind = false
    private var selectedAppearance: ClockAppearance = .light
    private var accentSign = true
    private var accentReadout = false
    private var hasError = false

    init(timer: ClockTimer) {
        id = timer.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        signButton.font = .systemFont(ofSize: 20, weight: .medium)
        signButton.target = self; signButton.action = #selector(toggleSign)
        primaryButton.target = self; primaryButton.action = #selector(primary)
        deleteButton.target = self; deleteButton.action = #selector(deleteTimer)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除计时")
        deleteButton.toolTip = "删除这组计时"
        deleteButton.setAccessibilityLabel("删除计时")
        resetButton.target = self; resetButton.action = #selector(resetTimer)
        resetButton.font = .systemFont(ofSize: 11)
        resetButton.toolTip = "停止后重新设置时间"
        for button in [signButton, primaryButton, deleteButton, resetButton] { button.isBordered = false }
        timeField.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        timeField.isBezeled = false
        timeField.drawsBackground = false
        timeField.focusRingType = .none
        timeField.usesSingleLineMode = true
        timeField.lineBreakMode = .byTruncatingMiddle
        timeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        timeField.setAccessibilityLabel("计时时间")
        timeField.cell?.sendsActionOnEndEditing = false
        durationInput.onChange = { [weak self] text in
            guard let self, self.isIdle, self.currentInputKind == .duration, !self.isChangingKind else { return }
            self.onInput?(text)
        }
        durationInput.onSubmit = { [weak self] in self?.primary() }
        targetInput.onChange = { [weak self] text in
            guard let self, self.isIdle, self.currentInputKind == .targetTime, !self.isChangingKind else { return }
            self.onInput?(text)
        }
        targetInput.onSubmit = { [weak self] in self?.primary() }
        kindPopup.addItems(withTitles: ["时长", "到点时间"])
        kindPopup.controlSize = .small
        kindPopup.font = .systemFont(ofSize: 11)
        kindPopup.target = self; kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel("计时输入方式")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        let line = NSStackView(views: [signButton, durationInput, targetInput, timeField, primaryButton, deleteButton])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 5; line.distribution = .fill
        let detail = NSStackView(views: [kindPopup, statusLabel, NSView(), resetButton])
        detail.orientation = .horizontal; detail.alignment = .centerY; detail.spacing = 4
        for view in [line, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            line.heightAnchor.constraint(equalToConstant: 42),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 5),
            detail.heightAnchor.constraint(equalToConstant: 23),
            signButton.widthAnchor.constraint(equalToConstant: 20),
            primaryButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.widthAnchor.constraint(equalToConstant: 18),
            kindPopup.widthAnchor.constraint(equalToConstant: 90),
            resetButton.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(timer: ClockTimer, settings: ClockSettings, error: String?, now: Date = Date()) {
        let editing = timer.state == .idle
        isIdle = editing
        currentInputKind = timer.inputKind
        selectedAppearance = settings.appearance
        accentSign = timer.countsDown || timer.isOvertime
        accentReadout = timer.isOvertime || timer.state == .completed
        hasError = error != nil
        let editingDuration = editing && timer.inputKind == .duration
        durationInput.isHidden = !editingDuration
        targetInput.isHidden = !editing || timer.inputKind != .targetTime
        timeField.isHidden = editing
        if editingDuration { durationInput.update(input: timer.input) }
        if editing && timer.inputKind == .targetTime { targetInput.update(input: timer.input) }
        signButton.title = timer.countsDown ? "+" : "−"
        signButton.isEnabled = timer.state != .running
        signButton.toolTip = "点击切换：＋ 倒计时，− 累计计时"
        signButton.setAccessibilityLabel(timer.countsDown ? "倒计时；点击切换为累计计时" : "累计计时；点击切换为倒计时")
        let text = editing ? timer.input : settings.timerDisplayFormat.string(seconds: timer.seconds(at: now), countingDown: timer.countsDown)
        if timeField.currentEditor() == nil && timeField.stringValue != text { timeField.stringValue = text }
        timeField.isEditable = false
        timeField.isSelectable = false
        timeField.font = .monospacedDigitSystemFont(ofSize: settings.faceSize < 224 ? 14 : 16, weight: .medium)
        timeField.toolTip = "当前计时读数"
        let symbol = timer.state == .running ? "stop.fill" : "play.fill"
        primaryButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: timer.state == .running ? "停止计时" : "开始计时")
        primaryButton.toolTip = timer.state == .running ? "停止并保留当前时间" : (timer.state == .paused ? "继续计时" : "开始计时")
        primaryButton.setAccessibilityLabel(primaryButton.toolTip)
        kindPopup.isHidden = !editing
        kindPopup.selectItem(at: timer.inputKind == .duration ? 0 : 1)
        kindPopup.isEnabled = timer.mode == .countdown
        resetButton.isHidden = editing || timer.state == .running
        if let error { statusLabel.stringValue = error }
        else {
            switch timer.state {
            case .idle:
                if editingDuration && durationInput.remainingSeconds > 0 {
                    statusLabel.stringValue = "另含 \(durationInput.remainingSeconds)秒"
                } else if timer.inputKind == .targetTime,
                          let target = try? TimerInputParser.targetDate(timer.input, now: now) {
                    let remaining = TimerDisplayFormat.totalMinutes.string(seconds: target.timeIntervalSince(now), countingDown: true)
                    statusLabel.stringValue = "剩\(remaining)"
                } else { statusLabel.stringValue = timer.mode == .elapsed ? "从已用时开始" : "设置后点 ▶" }
            case .running: statusLabel.stringValue = timer.isOvertime ? "时间到了 · 正在累计超时" : (timer.mode == .elapsed ? "正在累计" : "倒计时中 · 到时通知")
            case .paused: statusLabel.stringValue = timer.isOvertime ? "超时已停止 · 可继续" : "已停止 · 可继续"
            case .completed: statusLabel.stringValue = "时间到了"
            }
        }
        statusLabel.toolTip = error ?? statusLabel.stringValue
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Parent appearance callbacks can run before this row inherits the new
        // appearance. Resolve its colors here, without refreshing timer state.
        applyAppearance()
    }

    private func applyAppearance() {
        let dark = selectedAppearance == .dark ||
            (selectedAppearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let ink = dark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.17, alpha: 1)
        layer?.backgroundColor = ink.withAlphaComponent(dark ? 0.055 : 0.035).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.06).cgColor
        durationInput.apply(ink: ink, dark: dark)
        targetInput.apply(ink: ink, dark: dark)
        signButton.contentTintColor = accentSign ? .systemRed : ink
        timeField.textColor = accentReadout ? .systemRed : ink
        primaryButton.contentTintColor = .systemRed
        resetButton.contentTintColor = ink.withAlphaComponent(0.65)
        deleteButton.contentTintColor = ink.withAlphaComponent(0.5)
        statusLabel.textColor = hasError ? .systemRed : ink.withAlphaComponent(0.55)
        needsDisplay = true
    }

    @objc private func toggleSign() { window?.makeFirstResponder(nil); onSign?() }
    @objc private func primary() {
        guard window?.makeFirstResponder(nil) != false else { return }
        if isIdle && currentInputKind == .targetTime { targetInput.commit() }
        onPrimary?()
    }
    @objc private func deleteTimer() { window?.makeFirstResponder(nil); onDelete?() }
    @objc private func resetTimer() { onReset?() }
    @objc private func kindChanged() {
        // Ending editing can synchronously refresh the popup with the old mode.
        let selected: ClockTimerInput = kindPopup.indexOfSelectedItem == 0 ? .duration : .targetTime
        isChangingKind = true
        if window?.makeFirstResponder(nil) == false { window?.endEditing(for: nil) }
        onKind?(selected)
        isChangingKind = false
        if isIdle && currentInputKind == selected {
            let field = selected == .targetTime ? targetInput.hours.field : durationInput.minutes.field
            if window?.makeFirstResponder(field) == true { field.selectText(nil) }
        }
    }
}

final class TimerTrayView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private(set) var rows: [TimerRowView] = []
    var coordinator: TimerCoordinator?

    static func height(count: Int, hasNotice: Bool) -> CGFloat {
        count == 0 ? 0 : 32 + CGFloat(count) * 90 + (hasNotice ? 32 : 0)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        notice.font = .systemFont(ofSize: 10)
        notice.textColor = .systemOrange
        notice.lineBreakMode = .byTruncatingTail
        addSubview(heading); addSubview(notice)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(settings: ClockSettings) {
        guard let coordinator else { return }
        if rows.map(\.id) != coordinator.timers.map(\.id) {
            let previousRows = rows
            let existing = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, $0) })
            rows = coordinator.timers.map { timer in
                if let row = existing[timer.id] { return row }
                let row = TimerRowView(timer: timer)
                let id = timer.id
                row.onSign = { [weak coordinator] in coordinator?.toggleMode(id) }
                row.onPrimary = { [weak coordinator] in coordinator?.primaryAction(id) }
                row.onDelete = { [weak coordinator] in coordinator?.remove(id) }
                row.onReset = { [weak coordinator] in coordinator?.reset(id) }
                row.onInput = { [weak coordinator] in coordinator?.editInput(id, text: $0) }
                row.onKind = { [weak coordinator] in coordinator?.setInputKind(id, kind: $0) }
                addSubview(row)
                return row
            }
            // Publish the new row list before detaching views. Ending an input's
            // editing session can synchronously refresh the tray again.
            let remaining = Set(rows.map(\.id))
            for row in previousRows where !remaining.contains(row.id) {
                row.onInput = nil
                row.removeFromSuperview()
            }
        }
        heading.stringValue = "计时  \(rows.count) / 3     ＋ 倒计时  ·  − 累计"
        heading.textColor = .secondaryLabelColor
        notice.stringValue = coordinator.notificationMessage == nil ? "" : "通知未就绪 · 请检查系统通知设置"
        notice.toolTip = coordinator.notificationMessage
        notice.isHidden = coordinator.notificationMessage == nil
        let now = Date()
        for (row, timer) in zip(rows, coordinator.timers) {
            row.refresh(timer: timer, settings: settings, error: coordinator.errors[timer.id], now: now)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        heading.frame = CGRect(x: 10, y: bounds.height - 25, width: bounds.width - 20, height: 18)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 4, y: bounds.height - 32 - CGFloat(index + 1) * 90 + 6, width: bounds.width - 8, height: 84)
        }
        notice.frame = CGRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
    }
}
