import AppKit
import ClockCore

final class PercentageMenuView: NSView {
    let slider: NSSlider
    private let valueLabel: NSTextField
    var onChange: ((Double) -> Void)?

    init(titleText: String = "透明度", initialValue: Double = 20, maximum: Double = 90,
         lowText: String = "0% 不透明", highText: String = "90% 最透明",
         accessibilityLabel: String = "时钟透明度，0% 到 90%",
         help: String = "0% 完全不透明，90% 最透明。") {
        slider = NSSlider(value: initialValue, minValue: 0, maxValue: maximum, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "\(Int(initialValue))%")
        super.init(frame: CGRect(x: 0, y: 0, width: 286, height: 92))
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.frame = CGRect(x: 20, y: 64, width: 160, height: 18)
        addSubview(title)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.frame = CGRect(x: 212, y: 64, width: 54, height: 18)
        addSubview(valueLabel)
        slider.frame = CGRect(x: 18, y: 31, width: 250, height: 25)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityHelp(help)
        addSubview(slider)
        let low = NSTextField(labelWithString: lowText)
        let high = NSTextField(labelWithString: highText)
        for label in [low, high] {
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }
        low.frame = CGRect(x: 20, y: 10, width: 120, height: 15)
        high.frame = CGRect(x: 146, y: 10, width: 120, height: 15)
        high.alignment = .right
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ transparency: Double) {
        slider.doubleValue = transparency
        valueLabel.stringValue = "\(Int(transparency))%"
    }

    @objc private func sliderChanged() {
        let value = slider.doubleValue.rounded()
        update(value)
        onChange?(value)
    }
}

final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let transparencyView = PercentageMenuView()
    let minuteOpacityView = PercentageMenuView(
        titleText: "分钟大字浓度", initialValue: 40, maximum: 100,
        lowText: "0% 透明", highText: "100% 实色",
        accessibilityLabel: "分钟大字浓度，0% 到 100%",
        help: "只影响分钟大字。数值越高，颜色越深；不改变整个时钟的透明度。")
    private var statusItem: NSStatusItem?
    private let subtitle = NSTextField(labelWithString: "始终置顶 · 拖动表盘移动")
    private var lockItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var secondsItem: NSMenuItem!
    private var dateItem: NSMenuItem!
    private var minuteNumeralItem: NSMenuItem!
    private var minuteOpacityItem: NSMenuItem!
    private var sizeItems: [NSMenuItem] = []
    private var styleItems: [NSMenuItem] = []
    private var appearanceItems: [NSMenuItem] = []
    private var presetItems: [NSMenuItem] = []
    var settings: ClockSettings { didSet { refresh() } }
    var clockIsVisible = true { didSet { refresh() } }
    var onSettingsChanged: ((ClockSettings) -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onMoveToCurrentScreen: (() -> Void)?
    var onQuit: (() -> Void)?

    init(settings: ClockSettings, includeStatusItem: Bool = true) {
        self.settings = settings
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        if includeStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "漂浮时钟设置")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "漂浮时钟 · 透明度与位置设置"
            item.button?.setAccessibilityLabel("漂浮时钟设置")
            item.menu = menu
            statusItem = item
        }
        transparencyView.onChange = { [weak self] value in self?.change { $0.transparency = value } }
        minuteOpacityView.onChange = { [weak self] value in self?.change { $0.minuteNumeralOpacity = value } }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func buildMenu() {
        let header = NSView(frame: CGRect(x: 0, y: 0, width: 286, height: 53))
        let title = NSTextField(labelWithString: "漂浮时钟")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = CGRect(x: 20, y: 28, width: 250, height: 19)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = CGRect(x: 20, y: 10, width: 250, height: 16)
        header.addSubview(title)
        header.addSubview(subtitle)
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())
        let sliderItem = NSMenuItem()
        sliderItem.view = transparencyView
        menu.addItem(sliderItem)
        let presets = NSMenuItem(title: "透明度预设", action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu()
        presetsMenu.autoenablesItems = false
        for value in [0, 25, 50, 75, 90] {
            let item = makeItem(value == 0 ? "0% · 不透明" : "\(value)%", action: #selector(setPreset(_:)))
            item.tag = value
            presetItems.append(item)
            presetsMenu.addItem(item)
        }
        presets.submenu = presetsMenu
        menu.addItem(presets)
        menu.addItem(.separator())
        lockItem = makeItem("锁定位置（鼠标穿透）", action: #selector(toggleLock))
        menu.addItem(lockItem)
        visibilityItem = makeItem("显示时钟", action: #selector(toggleVisibility))
        menu.addItem(visibilityItem)
        menu.addItem(.separator())
        let styleItem = NSMenuItem(title: "表盘样式", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        styleMenu.autoenablesItems = false
        for (index, style) in ClockStyle.allCases.enumerated() {
            let item = makeItem(style.menuTitle, action: #selector(setStyle(_:)))
            item.tag = index
            styleItems.append(item)
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        minuteNumeralItem = makeItem("显示分钟大字", action: #selector(toggleMinuteNumerals))
        menu.addItem(minuteNumeralItem)
        minuteOpacityItem = NSMenuItem(title: "分钟大字浓度", action: nil, keyEquivalent: "")
        let minuteOpacityMenu = NSMenu()
        minuteOpacityMenu.autoenablesItems = false
        let minuteSliderItem = NSMenuItem()
        minuteSliderItem.view = minuteOpacityView
        minuteOpacityMenu.addItem(minuteSliderItem)
        minuteOpacityItem.submenu = minuteOpacityMenu
        menu.addItem(minuteOpacityItem)
        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "时钟大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (title, size) in [("小巧 · 164", 164), ("标准 · 224", 224), ("大号 · 284", 284)] {
            let item = makeItem(title, action: #selector(setSize(_:)))
            item.tag = size
            sizeItems.append(item)
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let appearanceItem = NSMenuItem(title: "表盘外观", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        appearanceMenu.autoenablesItems = false
        for (index, title) in ["暖白", "墨黑", "跟随系统"].enumerated() {
            let item = makeItem(title, action: #selector(setAppearance(_:)))
            item.tag = index
            appearanceItems.append(item)
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        secondsItem = makeItem("显示秒针", action: #selector(toggleSeconds))
        menu.addItem(secondsItem)
        dateItem = makeItem("显示日期", action: #selector(toggleDate))
        menu.addItem(dateItem)
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
        transparencyView.update(settings.transparency)
        lockItem.state = settings.isLocked ? .on : .off
        visibilityItem.state = clockIsVisible ? .on : .off
        secondsItem.state = settings.showsSeconds ? .on : .off
        dateItem.state = settings.showsDate ? .on : .off
        minuteNumeralItem.state = settings.showsMinuteNumerals ? .on : .off
        minuteOpacityItem.isHidden = !settings.showsMinuteNumerals
        minuteOpacityItem.title = "分钟大字浓度 · \(Int(settings.minuteNumeralOpacity))%"
        minuteOpacityView.update(settings.minuteNumeralOpacity)
        subtitle.stringValue = settings.isLocked ? "始终置顶 · 已锁定，鼠标可穿透" : "始终置顶 · 拖动表盘移动"
        for item in presetItems { item.state = Double(item.tag) == settings.transparency ? .on : .off }
        for item in sizeItems { item.state = Double(item.tag) == settings.faceSize ? .on : .off }
        for item in styleItems { item.state = ClockStyle.allCases[item.tag] == settings.style ? .on : .off }
        for item in appearanceItems { item.state = ClockAppearance.allCases[item.tag] == settings.appearance ? .on : .off }
    }

    private func change(_ edit: (inout ClockSettings) -> Void) {
        var updated = settings
        edit(&updated)
        settings = updated.normalized()
        onSettingsChanged?(settings)
    }

    @objc private func setPreset(_ item: NSMenuItem) { change { $0.transparency = Double(item.tag) } }
    @objc private func setSize(_ item: NSMenuItem) { change { $0.faceSize = Double(item.tag) } }
    @objc private func setStyle(_ item: NSMenuItem) { change { $0.style = ClockStyle.allCases[item.tag] } }
    @objc private func setAppearance(_ item: NSMenuItem) { change { $0.appearance = ClockAppearance.allCases[item.tag] } }
    @objc private func toggleLock() { change { $0.isLocked.toggle() } }
    @objc private func toggleSeconds() { change { $0.showsSeconds.toggle() } }
    @objc private func toggleDate() { change { $0.showsDate.toggle() } }
    @objc private func toggleMinuteNumerals() { change { $0.showsMinuteNumerals.toggle() } }
    @objc private func toggleVisibility() { onToggleVisibility?() }
    @objc private func moveToCurrentScreen() { onMoveToCurrentScreen?() }
    @objc private func quitApp() { onQuit?() }
}
