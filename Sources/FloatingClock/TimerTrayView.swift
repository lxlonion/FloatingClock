import AppKit
import ClockCore

final class TimerRowView: NSView, NSTextFieldDelegate {
    let id: UUID
    let signButton = NSButton(title: "+", target: nil, action: nil)
    let timeField = NSTextField(string: "")
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

    init(timer: ClockTimer) {
        id = timer.id
        super.init(frame: .zero)
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
        timeField.delegate = self
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
        kindPopup.addItems(withTitles: ["时长", "到点时间"])
        kindPopup.controlSize = .small
        kindPopup.font = .systemFont(ofSize: 11)
        kindPopup.target = self; kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel("计时输入方式")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        let line = NSStackView(views: [signButton, timeField, primaryButton, deleteButton])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 4; line.distribution = .fill
        let detail = NSStackView(views: [kindPopup, statusLabel, NSView(), resetButton])
        detail.orientation = .horizontal; detail.alignment = .centerY; detail.spacing = 4
        for view in [line, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            line.heightAnchor.constraint(equalToConstant: 30),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 3),
            detail.heightAnchor.constraint(equalToConstant: 23),
            signButton.widthAnchor.constraint(equalToConstant: 24),
            primaryButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            kindPopup.widthAnchor.constraint(equalToConstant: 90),
            resetButton.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(timer: ClockTimer, settings: ClockSettings, error: String?, now: Date = Date()) {
        let editing = timer.state == .idle
        let dark = settings.appearance == .dark || (settings.appearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let ink = dark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.17, alpha: 1)
        wantsLayer = true
        layer?.backgroundColor = ink.withAlphaComponent(0.045).cgColor
        layer?.cornerRadius = 12
        signButton.title = timer.mode == .countdown ? "+" : "−"
        signButton.contentTintColor = timer.mode == .countdown ? .systemRed : ink
        signButton.isEnabled = timer.state != .running
        signButton.toolTip = "点击切换：＋ 倒计时，− 累计计时"
        signButton.setAccessibilityLabel(timer.mode == .countdown ? "倒计时；点击切换为累计计时" : "累计计时；点击切换为倒计时")
        let text = editing ? timer.input : settings.timerDisplayFormat.string(seconds: timer.seconds(at: now), countingDown: timer.mode == .countdown)
        if timeField.stringValue != text { timeField.stringValue = text }
        timeField.isEditable = editing
        timeField.isSelectable = editing
        timeField.textColor = timer.state == .completed ? .systemRed : ink
        timeField.font = .monospacedDigitSystemFont(ofSize: settings.faceSize < 224 ? 14 : 16, weight: .medium)
        timeField.placeholderString = timer.inputKind == .duration ? "分钟 / 1小时30min" : "18:30"
        timeField.toolTip = timer.inputKind == .duration ? "数字按分钟；也可输入 90:00、1小时30min、30秒。− 从 0 开始累计。" : "输入 HH:mm、HH:mm:ss 或 yyyy-MM-dd HH:mm；只填时刻时取下一次该时刻。"
        let symbol = timer.state == .running ? "stop.fill" : "play.fill"
        primaryButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: timer.state == .running ? "停止计时" : "开始计时")
        primaryButton.contentTintColor = .systemRed
        primaryButton.toolTip = timer.state == .running ? "停止并保留当前时间" : (timer.state == .paused ? "继续计时" : "开始计时")
        primaryButton.setAccessibilityLabel(primaryButton.toolTip)
        kindPopup.isHidden = !editing || error != nil
        kindPopup.selectItem(at: timer.inputKind == .duration ? 0 : 1)
        kindPopup.isEnabled = timer.mode == .countdown
        resetButton.isHidden = editing || timer.state == .running
        resetButton.contentTintColor = ink.withAlphaComponent(0.65)
        deleteButton.contentTintColor = ink.withAlphaComponent(0.5)
        statusLabel.textColor = error == nil ? ink.withAlphaComponent(0.55) : .systemRed
        if let error { statusLabel.stringValue = error }
        else {
            switch timer.state {
            case .idle: statusLabel.stringValue = timer.mode == .elapsed ? "从已用时开始" : "输入后点 ▶"
            case .running: statusLabel.stringValue = timer.mode == .elapsed ? "正在累计" : "倒计时中 · 到时通知"
            case .paused: statusLabel.stringValue = "已停止 · 可继续"
            case .completed: statusLabel.stringValue = "时间到了"
            }
        }
        statusLabel.toolTip = error ?? statusLabel.stringValue
    }

    func controlTextDidChange(_ obj: Notification) { onInput?(timeField.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        primary()
        return true
    }
    @objc private func toggleSign() { window?.makeFirstResponder(nil); onSign?() }
    @objc private func primary() { window?.makeFirstResponder(nil); onPrimary?() }
    @objc private func deleteTimer() { onDelete?() }
    @objc private func resetTimer() { onReset?() }
    @objc private func kindChanged() { onKind?(kindPopup.indexOfSelectedItem == 0 ? .duration : .targetTime) }
}

final class TimerTrayView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private(set) var rows: [TimerRowView] = []
    var coordinator: TimerCoordinator?
    private var currentSettings = ClockSettings()

    static func height(count: Int, hasNotice: Bool) -> CGFloat {
        count == 0 ? 0 : 32 + CGFloat(count) * 74 + (hasNotice ? 32 : 0)
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
        currentSettings = settings
        if rows.map(\.id) != coordinator.timers.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = coordinator.timers.map { timer in
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

    override func viewDidChangeEffectiveAppearance() { refresh(settings: currentSettings) }

    override func layout() {
        super.layout()
        heading.frame = CGRect(x: 10, y: bounds.height - 25, width: bounds.width - 20, height: 18)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 4, y: bounds.height - 32 - CGFloat(index + 1) * 74 + 6, width: bounds.width - 8, height: 68)
        }
        notice.frame = CGRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
    }
}
