import AppKit
import ClockCore

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsSliderRow: NSView {
    let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let suffix: String
    var onChange: ((Double) -> Void)?

    var isEnabled = true {
        didSet {
            slider.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.45
        }
    }

    init(title: String, value: Double, range: ClosedRange<Double>, suffix: String = "%",
         lowText: String, highText: String, help: String) {
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                          target: nil, action: nil)
        self.suffix = suffix
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        let low = NSTextField(labelWithString: lowText)
        let high = NSTextField(labelWithString: highText)
        titleLabel.font = .systemFont(ofSize: 13)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .right
        for label in [low, high] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        high.alignment = .right
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityHelp(help)
        toolTip = help
        for view in [titleLabel, valueLabel, slider, low, high] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 70),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            low.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 1),
            low.leadingAnchor.constraint(equalTo: leadingAnchor),
            high.firstBaselineAnchor.constraint(equalTo: low.firstBaselineAnchor),
            high.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        update(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = "\(Int(value.rounded()))\(suffix)"
    }

    @objc private func sliderChanged() {
        let value = slider.doubleValue.rounded()
        update(value)
        onChange?(value)
    }
}

final class ClockTimeZoneRow: NSView {
    let timeZonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let daylightSavingButton = NSButton(checkboxWithTitle: "自动应用夏令时", target: nil, action: nil)
    var onChange: ((ClockTimeZoneSettings) -> Void)?
    private let catalog = ClockTimeZoneCatalog.shared
    private var currentSettings = ClockTimeZoneSettings.pacific

    init(slot: ClockSlot) {
        super.init(frame: .zero)
        for option in catalog.options { addTimeZone(option) }
        timeZonePopup.target = self
        timeZonePopup.action = #selector(timeZoneChanged)
        timeZonePopup.setAccessibilityLabel("\(slot.title)时区")
        timeZonePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (timeZonePopup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        daylightSavingButton.target = self
        daylightSavingButton.action = #selector(daylightSavingChanged)
        daylightSavingButton.setAccessibilityLabel("\(slot.title)自动应用夏令时")
        daylightSavingButton.toolTip = "勾选后按所选地区的规则自动切换夏令时；不勾选则全年使用标准时间。没有夏令时的地区不受影响。"
        let label = NSTextField(labelWithString: slot.title)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let choice = NSStackView(views: [label, timeZonePopup])
        choice.orientation = .horizontal
        choice.alignment = .centerY
        choice.spacing = 12
        let layout = NSStackView(views: [choice, daylightSavingButton])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 6
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            choice.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addTimeZone(_ option: ClockTimeZoneOption) {
        timeZonePopup.addItem(withTitle: option.title)
        timeZonePopup.lastItem?.representedObject = option.identifier
        timeZonePopup.lastItem?.toolTip = option.help
    }

    func update(_ settings: ClockTimeZoneSettings) {
        currentSettings = settings
        guard let option = catalog.option(for: settings.identifier) else { return }
        if !timeZonePopup.itemArray.contains(where: { $0.representedObject as? String == option.identifier }) {
            addTimeZone(option)
        }
        timeZonePopup.select(timeZonePopup.itemArray.first { $0.representedObject as? String == option.identifier })
        timeZonePopup.toolTip = option.help
        daylightSavingButton.isEnabled = option.hasDaylightSavingTime
        daylightSavingButton.state = option.hasDaylightSavingTime && settings.usesDaylightSavingTime ? .on : .off
        daylightSavingButton.toolTip = option.hasDaylightSavingTime ?
            "勾选后按此选项的规则自动切换；不勾选则全年使用前面 UTC 偏移对应的标准时间。" : "此选项全年使用固定 UTC 偏移，没有夏令时。"
    }

    @objc private func timeZoneChanged() {
        guard let identifier = timeZonePopup.selectedItem?.representedObject as? String,
              let option = catalog.option(for: identifier) else { return }
        // Selecting a seasonal option opts into its rules; saved choices and
        // explicitly disabled DST are retained when merely refreshing controls.
        currentSettings = ClockTimeZoneSettings(identifier: identifier, usesDaylightSavingTime: option.hasDaylightSavingTime)
        update(currentSettings)
        onChange?(currentSettings)
    }

    @objc private func daylightSavingChanged() {
        currentSettings.usesDaylightSavingTime = daylightSavingButton.state == .on
        onChange?(currentSettings)
    }
}

final class AdvancedSettingsWindowController: NSWindowController {
    let settingsScrollView = NSScrollView()
    let lockButton = NSButton(checkboxWithTitle: "锁定位置（鼠标穿透）", target: nil, action: nil)
    let visibilityButton = NSButton(checkboxWithTitle: "显示时钟", target: nil, action: nil)
    let moveToScreenButton = NSButton(title: "移回当前屏幕", target: nil, action: nil)
    let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let timerFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let clockSlotPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let secondTimeZoneRow = ClockTimeZoneRow(slot: .second)
    let thirdTimeZoneRow = ClockTimeZoneRow(slot: .third)
    let secondsButton = NSButton(checkboxWithTitle: "显示秒针", target: nil, action: nil)
    let dateButton = NSButton(checkboxWithTitle: "显示日期与星期", target: nil, action: nil)
    let minuteNumeralsButton = NSButton(checkboxWithTitle: "显示分钟大字", target: nil, action: nil)
    let transparencyRow = SettingsSliderRow(
        title: "背景透明度", value: 20, range: 0...90,
        lowText: "0% · 不透明", highText: "90% · 最透明", help: "背景按此数值变透明；指针、刻度、文字和计时器会稍清晰，至少保留 20% 不透明度。0% 时全部不透明。")
    let faceSizeRow = SettingsSliderRow(
        title: "时钟大小", value: Double(ClockLayout.minimumFaceSize), range: Double(ClockLayout.minimumFaceSize)...Double(ClockLayout.maximumFaceSize), suffix: "",
        lowText: "260 · 小号", highText: "420 · 大号", help: "调整整个表盘的大小，最小尺寸与计时区宽度对齐。")
    let minuteOpacityRow = SettingsSliderRow(
        title: "大字浓度", value: 40, range: 0...100,
        lowText: "0% · 透明", highText: "100% · 实色", help: "只改变分钟大字的浓度，不影响背景透明度。")
    let minuteSizeRow = SettingsSliderRow(
        title: "大字大小", value: 100, range: 40...100,
        lowText: "40% · 较小", highText: "100% · 最大", help: "相对于表盘内可用空间的大小，数字始终居中。")
    var settings: ClockSettings { didSet { refresh() } }
    var clockIsVisible = true { didSet { refresh() } }
    var onSettingsChanged: ((ClockSettings) -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onMoveToCurrentScreen: (() -> Void)?

    init(settings: ClockSettings) {
        self.settings = settings.normalized()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "漂浮时钟 · 高级设置"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        buildContent()
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showSettings() {
        refresh()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        let subtitle = note("调整会立即生效，并自动保存。")
        let header = stack([subtitle], spacing: 5)

        lockButton.target = self
        lockButton.action = #selector(lockChanged)
        visibilityButton.target = self
        visibilityButton.action = #selector(visibilityChanged)
        moveToScreenButton.target = self
        moveToScreenButton.action = #selector(moveToCurrentScreen)
        moveToScreenButton.bezelStyle = .rounded
        let visibilityRow = NSStackView(views: [visibilityButton, NSView(), moveToScreenButton])
        visibilityRow.orientation = .horizontal
        visibilityRow.alignment = .centerY
        let general = stack([heading("常规"), transparencyRow, lockButton, visibilityRow])

        clockSlotPopup.addItems(withTitles: ClockSlot.allCases.map { settings.title(for: $0) })
        clockSlotPopup.target = self
        clockSlotPopup.action = #selector(clockSlotChanged)
        clockSlotPopup.setAccessibilityLabel("当前时钟槽位")
        clockSlotPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (clockSlotPopup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        secondTimeZoneRow.onChange = { [weak self] value in self?.change { $0.secondClockTimeZone = value } }
        thirdTimeZoneRow.onChange = { [weak self] value in self?.change { $0.thirdClockTimeZone = value } }
        let timeZones = stack([
            heading("时钟槽位与时区"),
            choiceRow("当前槽位", control: clockSlotPopup),
            note("槽位 1 · 系统时区，自动跟随 macOS。"),
            secondTimeZoneRow, thirdTimeZoneRow,
            note("按 UTC 标准偏移合并；夏令时规则不同的选项单独列出。"),
            note("勾选夏令时自动切换；不勾选则全年使用标准时间。")
        ])

        stylePopup.addItems(withTitles: ClockStyle.allCases.map(\.menuTitle))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        stylePopup.setAccessibilityLabel("表盘样式")
        appearancePopup.addItems(withTitles: ["暖白", "墨黑", "跟随系统"])
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        appearancePopup.setAccessibilityLabel("表盘外观")
        let dial = stack([
            heading("表盘"),
            choiceRow("样式", control: stylePopup),
            choiceRow("外观", control: appearancePopup),
            faceSizeRow
        ])

        secondsButton.target = self
        secondsButton.action = #selector(secondsChanged)
        dateButton.target = self
        dateButton.action = #selector(dateChanged)
        let toggles = NSStackView(views: [secondsButton, dateButton])
        toggles.orientation = .horizontal
        toggles.spacing = 28
        let details = stack([heading("显示内容"), toggles])

        minuteNumeralsButton.target = self
        minuteNumeralsButton.action = #selector(minuteNumeralsChanged)
        let minutes = stack([
            heading("分钟大字"), minuteNumeralsButton,
            note("开启后可调整浓度和大小，可叠加在任一表盘上。"),
            minuteOpacityRow, minuteSizeRow
        ])
        timerFormatPopup.addItems(withTitles: TimerDisplayFormat.allCases.map(\.menuTitle))
        timerFormatPopup.target = self
        timerFormatPopup.action = #selector(timerFormatChanged)
        timerFormatPopup.setAccessibilityLabel("计时显示格式")
        let timers = stack([
            heading("计时"), choiceRow("显示格式", control: timerFormatPopup),
            note("解锁后移入时钟，点击赤陶色计时按钮添加；最多三组。"),
            note("＋ 倒计时 / 到点提醒；− 累计计时。时长可超过 60 分钟。"),
            note("到点提醒使用系统时区，切换时钟槽位不影响已有计时。")
        ])
        let done = NSButton(title: "完成", target: self, action: #selector(closeSettings))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        let form = stack([general, separator(), timeZones, separator(), dial, separator(), details, separator(), minutes, separator(), timers], spacing: 16)
        form.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView(frame: CGRect(x: 0, y: 0, width: 452, height: 0))
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: document.topAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        let formHeight = form.fittingSize.height
        document.setFrameSize(NSSize(width: 452, height: formHeight))
        let scroll = settingsScrollView
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 200
        scroll.heightAnchor.constraint(equalToConstant: min(formHeight, max(300, min(560, availableHeight)))).isActive = true
        let layout = stack([header, separator(), scroll, separator(), footer], spacing: 16)
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let height = layout.fittingSize.height + 44
        window.setContentSize(NSSize(width: 500, height: height))
        transparencyRow.onChange = { [weak self] value in self?.change { $0.transparency = value } }
        faceSizeRow.onChange = { [weak self] value in self?.change { $0.faceSize = value } }
        minuteOpacityRow.onChange = { [weak self] value in self?.change { $0.minuteNumeralOpacity = value } }
        minuteSizeRow.onChange = { [weak self] value in self?.change { $0.minuteNumeralSize = value } }
    }

    private func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        return result
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func choiceRow(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func refresh() {
        transparencyRow.update(settings.transparency)
        lockButton.state = settings.isLocked ? .on : .off
        visibilityButton.state = clockIsVisible ? .on : .off
        for (index, slot) in ClockSlot.allCases.enumerated() {
            clockSlotPopup.item(at: index)?.title = settings.title(for: slot)
        }
        clockSlotPopup.selectItem(at: ClockSlot.allCases.firstIndex(of: settings.selectedClockSlot) ?? 0)
        secondTimeZoneRow.update(settings.secondClockTimeZone)
        thirdTimeZoneRow.update(settings.thirdClockTimeZone)
        stylePopup.selectItem(at: ClockStyle.allCases.firstIndex(of: settings.style) ?? 0)
        appearancePopup.selectItem(at: ClockAppearance.allCases.firstIndex(of: settings.appearance) ?? 0)
        timerFormatPopup.selectItem(at: TimerDisplayFormat.allCases.firstIndex(of: settings.timerDisplayFormat) ?? 0)
        secondsButton.state = settings.showsSeconds ? .on : .off
        dateButton.state = settings.showsDate ? .on : .off
        minuteNumeralsButton.state = settings.showsMinuteNumerals ? .on : .off
        faceSizeRow.update(settings.faceSize)
        minuteOpacityRow.update(settings.minuteNumeralOpacity)
        minuteSizeRow.update(settings.minuteNumeralSize)
        minuteOpacityRow.isEnabled = settings.showsMinuteNumerals
        minuteSizeRow.isEnabled = settings.showsMinuteNumerals
    }

    private func change(_ edit: (inout ClockSettings) -> Void) {
        var updated = settings
        edit(&updated)
        settings = updated.normalized()
        onSettingsChanged?(settings)
    }

    @objc private func styleChanged() { change { $0.style = ClockStyle.allCases[stylePopup.indexOfSelectedItem] } }
    @objc private func clockSlotChanged() { change { $0.selectedClockSlot = ClockSlot.allCases[clockSlotPopup.indexOfSelectedItem] } }
    @objc private func appearanceChanged() { change { $0.appearance = ClockAppearance.allCases[appearancePopup.indexOfSelectedItem] } }
    @objc private func timerFormatChanged() { change { $0.timerDisplayFormat = TimerDisplayFormat.allCases[timerFormatPopup.indexOfSelectedItem] } }
    @objc private func secondsChanged() { change { $0.showsSeconds = secondsButton.state == .on } }
    @objc private func dateChanged() { change { $0.showsDate = dateButton.state == .on } }
    @objc private func minuteNumeralsChanged() { change { $0.showsMinuteNumerals = minuteNumeralsButton.state == .on } }
    @objc private func lockChanged() { change { $0.isLocked = lockButton.state == .on } }
    @objc private func visibilityChanged() { onToggleVisibility?() }
    @objc private func moveToCurrentScreen() { onMoveToCurrentScreen?() }
    @objc private func closeSettings() { close() }
}
