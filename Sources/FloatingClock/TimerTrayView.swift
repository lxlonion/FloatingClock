import AppKit
import ClockCore

final class TimerActionButton: NSButton {
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
    let nextTargetButton = NSButton(title: "下一个该时刻", target: nil, action: nil)
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
    private var statusBeforeNextButton: NSLayoutConstraint!
    private var statusFullWidth: NSLayoutConstraint!

    init(timer: ClockTimer) {
        id = timer.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
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
        nextTargetButton.font = .systemFont(ofSize: 9)
        nextTargetButton.isBordered = false
        nextTargetButton.target = self
        nextTargetButton.action = #selector(useNextTargetTime)
        nextTargetButton.toolTip = "清除原日期，使用下一个该时刻（保留秒数）"
        nextTargetButton.setAccessibilityLabel("使用下一个该时刻，清除原日期并保留秒数")
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
        for view in [line, statusLabel, nextTargetButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        statusBeforeNextButton = statusLabel.trailingAnchor.constraint(equalTo: nextTargetButton.leadingAnchor, constant: -2)
        statusFullWidth = statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        statusFullWidth.isActive = true
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 38),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nextTargetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nextTargetButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor, constant: -1),
            nextTargetButton.widthAnchor.constraint(equalToConstant: 76),
            nextTargetButton.heightAnchor.constraint(equalToConstant: 16),
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = CardGeometry.innerRadius(height: bounds.height)
        CATransaction.commit()
    }

    func refresh(timer: ClockTimer, settings: ClockSettings, error: String?, now: Date = Date(),
                 instant: TimerInstant? = TimerInstant.current()) {
        let editing = timer.state == .idle
        let draft = editing ? timer.draft : nil
        let mode = draft?.mode ?? timer.mode
        let inputKind = draft?.kind ?? timer.inputKind
        let countsDown = editing ? mode == .countdown : timer.countsDown
        isIdle = editing
        currentInputKind = inputKind
        selectedAppearance = settings.appearance
        accentSign = countsDown || timer.isOvertime
        accentReadout = timer.isOvertime || timer.state == .completed
        hasError = error != nil
        let editingDuration = editing && inputKind == .duration
        let editingTarget = editing && inputKind == .targetTime
        durationInput.isHidden = !editingDuration
        targetInput.isHidden = !editingTarget
        timeField.isHidden = editing
        if let draft { (inputKind == .duration ? durationInput : targetInput).update(draft: draft) }
        signButton.title = countsDown ? "+" : "−"
        signButton.isEnabled = timer.state != .running
        signButton.toolTip = "点击切换：＋ 倒计时，− 累计计时"
        signButton.setAccessibilityLabel(countsDown ? "倒计时；点击切换为累计计时" : "累计计时；点击切换为倒计时")
        if editing {
            setReadout(timer.input)
        } else {
            refreshReadout(timer: timer, format: settings.timerDisplayFormat, at: now, instant: instant)
        }
        timeField.isEditable = false
        timeField.isSelectable = false
        timeField.font = .monospacedDigitSystemFont(ofSize: settings.faceSize < 224 ? 14 : 16, weight: .medium)
        timeField.toolTip = "当前计时读数"
        let symbol = timer.state == .running ? "stop.fill" : "play.fill"
        primaryButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: timer.state == .running ? "停止计时" : "开始计时")
        primaryButton.toolTip = timer.state == .running ? "停止并保留当前时间" : (timer.state == .paused ? "继续计时" : "开始计时")
        primaryButton.setAccessibilityLabel(primaryButton.toolTip)
        kindButton.isHidden = !editing
        kindButton.isEnabled = mode == .countdown
        let durationMode = inputKind == .duration
        kindButton.image = NSImage(systemSymbolName: durationMode ? "stopwatch" : "arrow.right",
                                  accessibilityDescription: durationMode ? "时长" : "到点时间")
        kindButton.toolTip = durationMode ? "时长 · 点击切换为到点时间" : "到点时间 · 点击切换为时长"
        kindButton.setAccessibilityLabel(kindButton.toolTip)
        resetButton.isHidden = editing || timer.state == .running
        var statusHelp: String?
        let targetDetail = editingTarget ? targetInput.targetDetail : nil
        nextTargetButton.isHidden = !editingTarget || !targetInput.hasExplicitTargetDate
        if nextTargetButton.isHidden {
            statusBeforeNextButton.isActive = false
            statusFullWidth.isActive = true
        } else {
            statusFullWidth.isActive = false
            statusBeforeNextButton.isActive = true
        }
        if let error { statusLabel.stringValue = targetDetail.map { "\($0) · \(error)" } ?? error }
        else {
            switch timer.state {
            case .idle:
                if editingDuration, let preserved = durationInput.preservedDuration {
                    statusLabel.stringValue = "原时长：\(settings.timerDisplayFormat.string(seconds: preserved, countingDown: countsDown))"
                    statusHelp = "原时长：\(preserved)秒。旧时长超出输入范围；未修改时完整保留，修改小时或分钟将使用新时长。"
                } else if editingDuration && durationInput.remainingSeconds > 0 {
                    statusLabel.stringValue = "另含 \(durationInput.remainingSeconds)秒"
                } else if let targetDetail {
                    statusLabel.stringValue = targetDetail
                    statusHelp = "原定到点时间：\(targetDetail)"
                } else { statusLabel.stringValue = "" }
            case .running: statusLabel.stringValue = timer.isOvertime ? "时间到了 · 正在累计超时" : (timer.mode == .elapsed ? "正在累计" : "倒计时中 · 到时通知")
            case .paused: statusLabel.stringValue = timer.isOvertime ? "超时已停止 · 可继续" : "已停止 · 可继续"
            case .completed: statusLabel.stringValue = "时间到了"
            }
        }
        statusLabel.toolTip = error ?? statusHelp ?? statusLabel.stringValue
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        applyAppearance()
    }

    func refreshReadout(timer: ClockTimer, format: TimerDisplayFormat, at now: Date, instant: TimerInstant?) {
        setReadout(format.string(seconds: timer.seconds(at: now, instant: instant), countingDown: timer.countsDown))
    }

    private func setReadout(_ text: String) {
        if timeField.stringValue != text && timeField.currentEditor() == nil { timeField.stringValue = text }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let palette = ClockPalette(selectedAppearance, effectiveAppearance: effectiveAppearance)
        let ink = palette.ink
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = palette.timerRowBackground.cgColor
        layer?.borderColor = ink.withAlphaComponent(0.06).cgColor
        CATransaction.commit()
        durationInput.apply(palette: palette)
        targetInput.apply(palette: palette)
        signButton.contentTintColor = accentReadout ? palette.warning : (accentSign ? palette.accent : ink)
        timeField.textColor = accentReadout ? palette.warning : ink
        primaryButton.contentTintColor = palette.accent
        kindButton.contentTintColor = ink.withAlphaComponent(0.65)
        resetButton.contentTintColor = ink.withAlphaComponent(0.65)
        deleteButton.contentTintColor = ink.withAlphaComponent(0.5)
        nextTargetButton.contentTintColor = palette.accent
        statusLabel.textColor = hasError ? palette.error : (accentReadout ? palette.warning : ink.withAlphaComponent(0.55))
        needsDisplay = true
    }

    @objc private func useNextTargetTime() {
        guard window?.makeFirstResponder(nil) != false else { return }
        targetInput.useNextTargetTime()
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
    private static let rowSpacing: CGFloat = CardGeometry.inset
    let notice = NSTextField(labelWithString: "")
    let scrollView = NSScrollView()
    private let document = NSView()
    private var wasOverflowing = false
    private var selectedAppearance: ClockAppearance = .light
    private(set) var rows: [TimerRowView] = []
    var coordinator: TimerCoordinator?

    var contentHeight: CGFloat {
        rows.isEmpty ? 0 : CardGeometry.inset + rows.reduce(0) { $0 + $1.preferredHeight + Self.rowSpacing } + (notice.isHidden ? 0 : 32)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        notice.font = .systemFont(ofSize: 10)
        notice.lineBreakMode = .byTruncatingTail
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityLabel("计时列表，可滚动")
        scrollView.documentView = document
        addSubview(scrollView)
        document.addSubview(notice)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(settings: ClockSettings) {
        guard let coordinator else { return }
        selectedAppearance = settings.appearance
        applyAppearance()
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
                document.addSubview(row)
                return row
            }
            let remaining = Set(rows.map(\.id))
            for row in previousRows where !remaining.contains(row.id) {
                row.onInput = nil
                row.removeFromSuperview()
            }
        }
        notice.stringValue = coordinator.notificationMessage == nil ? "" : "通知未就绪 · 请检查系统通知设置"
        notice.toolTip = coordinator.notificationMessage
        notice.isHidden = coordinator.notificationMessage == nil
        let (now, instant) = coordinator.readoutTime()
        for (row, timer) in zip(rows, coordinator.timers) {
            row.refresh(timer: timer, settings: settings, error: coordinator.errors[timer.id], now: now, instant: instant)
        }
        needsLayout = true
    }

    func refreshReadouts(format: TimerDisplayFormat, at now: Date, instant: TimerInstant?) {
        guard let coordinator else { return }
        for (row, timer) in zip(rows, coordinator.timers) where timer.state == .running {
            row.refreshReadout(timer: timer, format: format, at: now, instant: instant)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        notice.textColor = ClockPalette(selectedAppearance, effectiveAppearance: effectiveAppearance).warning
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let viewport = scrollView.contentView.bounds
        let height = max(viewport.height, contentHeight)
        document.frame = CGRect(x: 0, y: 0, width: viewport.width, height: height)
        let overflowing = contentHeight > viewport.height + 0.5
        if overflowing && !wasOverflowing {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: height - viewport.height))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        wasOverflowing = overflowing
        var top = height - CardGeometry.inset
        for row in rows {
            row.frame = CGRect(x: CardGeometry.inset, y: top - row.preferredHeight,
                               width: document.bounds.width - 2 * CardGeometry.inset, height: row.preferredHeight)
            top = row.frame.minY - Self.rowSpacing
        }
        notice.frame = CGRect(x: 10, y: 8, width: document.bounds.width - 20, height: 18)
    }
}
