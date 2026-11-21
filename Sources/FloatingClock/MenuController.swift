import AppKit
import ClockCore

final class PercentageMenuView: NSView {
    let slider: NSSlider
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    var onChange: ((Double) -> Void)?

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            slider.setAccessibilityLabel(newValue)
        }
    }

    init(title: String, controlSize: NSControl.ControlSize = .regular, help: String) {
        slider = NSSlider(value: 0, minValue: 0, maxValue: 90, target: nil, action: nil)
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: "")
        let isSmall = controlSize == .small
        let rowHeight: CGFloat = isSmall ? 42 : 58
        let fontSize: CGFloat = isSmall ? 11 : 12
        let labelY: CGFloat = isSmall ? 23 : 34
        super.init(frame: CGRect(x: 0, y: 0, width: 286, height: rowHeight))
        titleLabel.font = .systemFont(ofSize: fontSize, weight: .medium)
        titleLabel.frame = CGRect(x: 20, y: labelY, width: 184, height: 18)
        addSubview(titleLabel)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.frame = CGRect(x: 212, y: labelY, width: 54, height: 18)
        addSubview(valueLabel)
        slider.controlSize = controlSize
        slider.frame = CGRect(x: 18, y: isSmall ? 3 : 5, width: 250, height: isSmall ? 20 : 25)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityHelp(help)
        slider.toolTip = help
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ transparency: Double) {
        slider.doubleValue = transparency
        valueLabel.stringValue = "\(Int(transparency.rounded()))%"
    }

    @objc private func sliderChanged() {
        let value = slider.doubleValue.rounded()
        update(value)
        onChange?(value)
    }
}

final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let quickMenu = NSMenu()
    let transparencyView = PercentageMenuView(title: "整体透明度", help: "联动背景和信息元素，中间档位的信息元素稍清晰。")
    let transparencyDisclosureButton = TransparencyDisclosureButton(horizontalInset: 20)
    let contentTransparencyView = PercentageMenuView(
        title: "信息元素透明度", controlSize: .small, help: "单独调整刻度、指针、文字、分钟大字和计时器。")
    let backgroundTransparencyView = PercentageMenuView(
        title: "背景透明度", controlSize: .small, help: "单独调整时钟底板和阴影。")
    private let layerTransparencyItems = [NSMenuItem(), NSMenuItem()]
    private var statusItem: NSStatusItem?
    private var lockItem: NSMenuItem!
    private(set) var clockSlotItems: [NSMenuItem] = []
    private var quickItems: [NSMenuItem] = []
    var settings: ClockSettings { didSet { refresh() } }
    var onSettingsChanged: ((ClockSettings) -> Void)?
    var onMoveToCurrentScreen: (() -> Void)?
    var onShowAdvancedSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(settings: ClockSettings, includeStatusItem: Bool = true) {
        self.settings = settings
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        quickMenu.autoenablesItems = false
        quickMenu.delegate = self
        for (title, action) in [("锁定位置", #selector(toggleLock)),
                                ("显示分钟大字", #selector(toggleMinuteNumerals)),
                                ("显示秒针", #selector(toggleSeconds))] {
            let item = makeItem(title, action: action)
            quickItems.append(item)
            quickMenu.addItem(item)
        }
        if includeStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "漂浮时钟设置")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "漂浮时钟 · 设置"
            item.button?.setAccessibilityLabel("漂浮时钟设置")
            item.menu = menu
            statusItem = item
        }
        transparencyView.onChange = { [weak self] value in self?.change { $0.transparency = value } }
        contentTransparencyView.onChange = { [weak self] value in self?.change { $0.contentTransparency = value } }
        backgroundTransparencyView.onChange = { [weak self] value in self?.change { $0.backgroundTransparency = value } }
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func buildMenu() {
        transparencyDisclosureButton.target = self
        transparencyDisclosureButton.action = #selector(toggleTransparencyDetails)
        transparencyDisclosureButton.setFrameSize(NSSize(width: transparencyView.bounds.width,
                                                         height: transparencyDisclosureButton.intrinsicContentSize.height))
        let overallItem = NSMenuItem()
        let disclosureItem = NSMenuItem()
        for (item, view) in zip([overallItem, disclosureItem] + layerTransparencyItems,
                                [transparencyView, transparencyDisclosureButton, contentTransparencyView, backgroundTransparencyView]) {
            item.view = view
            item.isHidden = layerTransparencyItems.contains(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, slot) in ClockSlot.allCases.enumerated() {
            let item = makeItem(slot.title, action: #selector(selectClockSlot(_:)))
            item.tag = index
            if slot == .system { item.toolTip = "跟随系统时区" }
            clockSlotItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        lockItem = makeItem("锁定位置（鼠标穿透）", action: #selector(toggleLock))
        menu.addItem(lockItem)
        menu.addItem(.separator())
        let advanced = makeItem("高级设置…", action: #selector(showAdvancedSettings))
        advanced.keyEquivalent = ","
        menu.addItem(advanced)
        menu.addItem(.separator())
        menu.addItem(makeItem("移回当前屏幕", action: #selector(moveToCurrentScreen)))
        menu.addItem(.separator())
        let quit = makeItem("退出漂浮时钟", action: #selector(quitApp))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refresh() {
        guard lockItem != nil else { return }
        transparencyView.title = settings.usesCustomTransparency ? "整体透明度 · 手动分层" : "整体透明度"
        transparencyView.update(settings.transparency)
        contentTransparencyView.update(settings.contentTransparency)
        backgroundTransparencyView.update(settings.backgroundTransparency)
        lockItem.state = settings.isLocked ? .on : .off
        let date = Date()
        for (item, slot) in zip(clockSlotItems, ClockSlot.allCases) {
            item.title = settings.menuTitle(for: slot, at: date)
            item.state = settings.selectedClockSlot == slot ? .on : .off
        }
        if quickItems.count == 3 {
            for (item, enabled) in zip(quickItems, [settings.isLocked, settings.showsMinuteNumerals, settings.showsSeconds]) {
                item.state = enabled ? .on : .off
            }
        }
    }

    private func change(_ edit: (inout ClockSettings) -> Void) {
        var updated = settings
        edit(&updated)
        if let onSettingsChanged {
            onSettingsChanged(updated)
        } else {
            settings = updated.normalized()
        }
    }

    @objc private func toggleTransparencyDetails() {
        transparencyDisclosureButton.isExpanded.toggle()
        for item in layerTransparencyItems { item.isHidden = !transparencyDisclosureButton.isExpanded }
    }
    @objc private func toggleLock() { change { $0.isLocked.toggle() } }
    @objc private func selectClockSlot(_ sender: NSMenuItem) {
        guard ClockSlot.allCases.indices.contains(sender.tag) else { return }
        change { $0.selectedClockSlot = ClockSlot.allCases[sender.tag] }
    }
    @objc private func toggleSeconds() { change { $0.showsSeconds.toggle() } }
    @objc private func toggleMinuteNumerals() { change { $0.showsMinuteNumerals.toggle() } }
    @objc private func showAdvancedSettings() { onShowAdvancedSettings?() }
    @objc private func moveToCurrentScreen() { onMoveToCurrentScreen?() }
    @objc private func quitApp() { onQuit?() }
}
