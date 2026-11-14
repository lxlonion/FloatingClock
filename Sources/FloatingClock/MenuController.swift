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
    let quickMenu = NSMenu()
    let transparencyView = PercentageMenuView()
    private var statusItem: NSStatusItem?
    private let subtitle = NSTextField(labelWithString: "始终置顶 · 拖动表盘移动")
    private var lockItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var quickItems: [NSMenuItem] = []
    var settings: ClockSettings { didSet { refresh() } }
    var clockIsVisible = true { didSet { refresh() } }
    var onSettingsChanged: ((ClockSettings) -> Void)?
    var onToggleVisibility: (() -> Void)?
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
        menu.addItem(.separator())
        lockItem = makeItem("锁定位置（鼠标穿透）", action: #selector(toggleLock))
        menu.addItem(lockItem)
        visibilityItem = makeItem("显示时钟", action: #selector(toggleVisibility))
        menu.addItem(visibilityItem)
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
        transparencyView.update(settings.transparency)
        lockItem.state = settings.isLocked ? .on : .off
        visibilityItem.state = clockIsVisible ? .on : .off
        if quickItems.count == 3 {
            for (item, enabled) in zip(quickItems, [settings.isLocked, settings.showsMinuteNumerals, settings.showsSeconds]) {
                item.state = enabled ? .on : .off
            }
        }
        subtitle.stringValue = settings.isLocked ? "始终置顶 · 已锁定，鼠标可穿透" : "始终置顶 · 拖动表盘移动"
    }

    private func change(_ edit: (inout ClockSettings) -> Void) {
        var updated = settings
        edit(&updated)
        settings = updated.normalized()
        onSettingsChanged?(settings)
    }

    @objc private func toggleLock() { change { $0.isLocked.toggle() } }
    @objc private func toggleSeconds() { change { $0.showsSeconds.toggle() } }
    @objc private func toggleMinuteNumerals() { change { $0.showsMinuteNumerals.toggle() } }
    @objc private func showAdvancedSettings() { onShowAdvancedSettings?() }
    @objc private func toggleVisibility() { onToggleVisibility?() }
    @objc private func moveToCurrentScreen() { onMoveToCurrentScreen?() }
    @objc private func quitApp() { onQuit?() }
}
