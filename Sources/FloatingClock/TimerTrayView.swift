import AppKit
import ClockCore

final class TimerActionButton: NSButton {
    // Borderless image buttons have different optical insets from text buttons.
    // Use their physical bounds so each compact column has equal, separate hits.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

final class TimerRowView: NSView {
    var preferredHeight: CGFloat { statusLabel.isHidden ? 48 : 64 }
    let id: UUID
    let signButton = TimerActionButton(title: "+", target: nil, action: nil)
    let timeField = NSTextField(string: "")
    let durationInput = TimerTimeInput(kind: .duration)
    let targetInput = TimerTimeInput(kind: .targetTime)
    let primaryButton = TimerActionButton()
    let deleteButton = TimerActionButton()
    let kindButton = TimerActionButton()
    let statusLabel = NSTextField(labelWithString: "")
    let resetButton = TimerActionButton()
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
        signButton.font = .systemFont(ofSize: 17, weight: .medium)
        signButton.target = self; signButton.action = #selector(toggleSign)
        primaryButton.target = self; primaryButton.action = #selector(primary)
        deleteButton.target = self; deleteButton.action = #selector(deleteTimer)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除计时")
        deleteButton.toolTip = "删除这组计时"
        deleteButton.setAccessibilityLabel("删除计时")
        resetButton.target = self; resetButton.action = #selector(resetTimer)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "重设计时")
        resetButton.setAccessibilityLabel("重设计时")
        resetButton.toolTip = "停止后重新设置时间"
        resetButton.isHidden = true
        for button in [signButton, kindButton, primaryButton, deleteButton, resetButton] { button.isBordered = false }
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
        kindButton.target = self; kindButton.action = #selector(kindChanged)
        kindButton.imageScaling = .scaleProportionallyDown
        kindButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.lineBreakMode = .byTruncatingTail
        let leftControls = NSStackView(views: [signButton, kindButton, resetButton])
        let rightControls = NSStackView(views: [primaryButton, deleteButton])
        for column in [leftControls, rightControls] {
            column.orientation = .vertical
            column.alignment = .centerX
            column.distribution = .fill
            column.spacing = 1
        }
        let line = NSStackView(views: [leftControls, durationInput, targetInput, timeField, rightControls])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 4; line.distribution = .fill
        for view in [line, statusLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 38),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 10),
            leftControls.widthAnchor.constraint(equalToConstant: 20),
            rightControls.widthAnchor.constraint(equalToConstant: 22)
        ])
        for button in [signButton, kindButton, resetButton, primaryButton, deleteButton] {
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
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
        kindButton.isHidden = !editing
        kindButton.isEnabled = timer.mode == .countdown
        let durationMode = timer.inputKind == .duration
        kindButton.image = NSImage(systemSymbolName: durationMode ? "stopwatch" : "arrow.right",
                                  accessibilityDescription: durationMode ? "时长" : "到点时间")
        kindButton.toolTip = durationMode ? "时长 · 点击切换为到点时间" : "到点时间 · 点击切换为时长"
        kindButton.setAccessibilityLabel(kindButton.toolTip)
        resetButton.isHidden = editing || timer.state == .running
        if let error { statusLabel.stringValue = error }
        else {
            switch timer.state {
            case .idle:
                if editingDuration && durationInput.remainingSeconds > 0 {
                    statusLabel.stringValue = "另含 \(durationInput.remainingSeconds)秒"
                } else { statusLabel.stringValue = "" }
            case .running: statusLabel.stringValue = timer.isOvertime ? "时间到了 · 正在累计超时" : (timer.mode == .elapsed ? "正在累计" : "倒计时中 · 到时通知")
            case .paused: statusLabel.stringValue = timer.isOvertime ? "超时已停止 · 可继续" : "已停止 · 可继续"
            case .completed: statusLabel.stringValue = "时间到了"
            }
        }
        statusLabel.toolTip = error ?? statusLabel.stringValue
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
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
        kindButton.contentTintColor = ink.withAlphaComponent(0.65)
        resetButton.contentTintColor = ink.withAlphaComponent(0.65)
        deleteButton.contentTintColor = ink.withAlphaComponent(0.5)
        statusLabel.textColor = hasError ? .systemRed : ink.withAlphaComponent(0.55)
        needsDisplay = true
    }

    @objc private func toggleSign() { window?.makeFirstResponder(nil); onSign?() }
    @objc private func primary() {
        guard window?.makeFirstResponder(nil) != false else { return }
        if isIdle { (currentInputKind == .targetTime ? targetInput : durationInput).commit() }
        onPrimary?()
    }
    @objc private func deleteTimer() { window?.makeFirstResponder(nil); onDelete?() }
    @objc private func resetTimer() { onReset?() }
    @objc private func kindChanged() {
        // Capture the new mode before ending editing can refresh the row.
        let selected: ClockTimerInput = currentInputKind == .duration ? .targetTime : .duration
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
    private static let rowSpacing: CGFloat = 6
    private let notice = NSTextField(labelWithString: "")
    private(set) var rows: [TimerRowView] = []
    var coordinator: TimerCoordinator?

    var contentHeight: CGFloat {
        rows.isEmpty ? 0 : 8 + rows.reduce(0) { $0 + $1.preferredHeight + Self.rowSpacing } + (notice.isHidden ? 0 : 32)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        notice.font = .systemFont(ofSize: 10)
        notice.textColor = .systemOrange
        notice.lineBreakMode = .byTruncatingTail
        addSubview(notice)
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
        var top = bounds.height - 8
        for row in rows {
            row.frame = CGRect(x: 4, y: top - row.preferredHeight,
                               width: bounds.width - 8, height: row.preferredHeight)
            top = row.frame.minY - Self.rowSpacing
        }
        notice.frame = CGRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
    }
}
