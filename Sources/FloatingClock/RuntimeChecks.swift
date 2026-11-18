import AppKit
import ClockCore

final class CheckTimerNotifications: TimerNotificationScheduling {
    var scheduled: [ClockTimer] = []
    var cancelled: [UUID] = []
    var message: String?
    var deferCompletion = false
    var pending: [(String?) -> Void] = []
    func schedule(_ timer: ClockTimer, completion: @escaping (String?) -> Void) {
        scheduled.append(timer)
        if deferCompletion { pending.append(completion) } else { completion(message) }
    }
    func cancel(_ id: UUID) { cancelled.append(id) }
}

enum RuntimeChecks {
    /// Exercises the real AppKit menu targets and panel without touching user preferences.
    static func run() -> Int32 {
        let suite = "FloatingClock.smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let panel = ClockPanel(settings: ClockSettings())
        var hoverPoint = CGPoint(x: -100_000, y: -100_000)
        panel.mouseLocationProvider = { hoverPoint }
        let controller = MenuController(settings: ClockSettings(), includeStatusItem: false)
        let advanced = AdvancedSettingsWindowController(settings: ClockSettings())
        defer { advanced.close() }
        var checks: [String] = []
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
            checks.append(name)
        }
        controller.onSettingsChanged = { value in
            panel.apply(value)
            store.save(value)
            advanced.settings = value
        }
        advanced.onSettingsChanged = { value in
            controller.settings = value
            panel.apply(value)
            store.save(value)
        }
        controller.onShowAdvancedSettings = { advanced.showSettings() }
        func syncVisibility() {
            controller.clockIsVisible = panel.isVisible
            advanced.clockIsVisible = panel.isVisible
        }
        let toggleVisibility = {
            if panel.isVisible { panel.hideClock() } else { panel.showClock() }
            syncVisibility()
        }
        controller.onToggleVisibility = toggleVisibility
        advanced.onToggleVisibility = toggleVisibility
        advanced.onMoveToCurrentScreen = {
            panel.moveToCurrentScreen()
            syncVisibility()
        }
        var quitRequests = 0
        controller.onQuit = { quitRequests += 1 }
        check(panel.level.rawValue == NSWindow.Level.popUpMenu.rawValue - 1, "above app windows, below system menus")
        check(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]), "all Spaces and fullscreen flags")
        check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate, "does not steal keyboard focus")

        let slider = controller.transparencyView.slider
        slider.doubleValue = 54
        _ = slider.sendAction(slider.action, to: slider.target)
        check(panel.alphaValue == panel.face.settings.contentAlpha && abs(panel.face.settings.backgroundAlpha - 0.46) < 0.001 &&
              panel.timerTray.alphaValue == 1, "live slider updates background and content opacity separately")
        check(advanced.transparencyRow.slider.doubleValue == 54 && advanced.backgroundTransparencyRow.slider.doubleValue == 54 &&
              abs(advanced.contentTransparencyRow.slider.doubleValue - 44.4) < 0.001,
              "menu overall transparency synchronizes all three sliders to the open settings window")

        if let index = controller.menu.items.firstIndex(where: { $0.title == "锁定位置（鼠标穿透）" }) {
            controller.menu.performActionForItem(at: index)
            check(panel.ignoresMouseEvents && controller.settings.isLocked, "locking enables mouse pass-through")
            check(advanced.lockButton.state == .on, "menu lock changes synchronize to advanced settings")
            check(store.load().isLocked && store.load().transparency == 54, "menu changes persist to preferences")
            controller.menu.performActionForItem(at: index)
            check(!panel.ignoresMouseEvents, "menu remains able to unlock")
        } else { check(false, "lock menu exists") }

        check(controller.menu.items.allSatisfy { $0.submenu == nil }, "compact menu has no secondary submenus")
        check(controller.menu.items.filter { $0.action != nil }.count == 8,
              "compact menu includes three clock slots and the five existing actions")
        if let index = controller.menu.items.firstIndex(where: { $0.title == "高级设置…" }) {
            controller.menu.performActionForItem(at: index)
            check(advanced.window?.isVisible == true && advanced.window?.canBecomeKey == true,
                  "advanced menu opens a separate focusable settings window")
            let window = advanced.window
            advanced.close()
            check(advanced.window?.isVisible == false, "closing settings leaves clock controls alive")
            controller.menu.performActionForItem(at: index)
            controller.menu.performActionForItem(at: index)
            check(advanced.window === window && advanced.window?.isVisible == true,
                  "reopening and repeated selection reuse the same settings window")
        } else { check(false, "advanced settings menu exists") }

        advanced.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = advanced.settingsScrollView
        check(abs((scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width) < 1,
              "settings scroll content fits the viewport without clipping controls on the right")

        check(controller.clockSlotItems.count == 3 && advanced.clockSlotPopup.numberOfItems == 3 &&
              controller.clockSlotItems.map(\.state) == [.on, .off, .off],
              "three clock slots default to the system slot in the menu and advanced settings")
        let catalog = ClockTimeZoneCatalog.shared
        let zonePopup = advanced.secondTimeZoneRow.timeZonePopup
        let newYorkOption = catalog.option(for: "America/New_York")!
        check(zonePopup.title == "UTC−08:00" && advanced.thirdTimeZoneRow.timeZonePopup.title == newYorkOption.title,
              "settings show a fixed Pacific offset and a New York choice that follows local time")
        let firstLevel = zonePopup.menu?.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.submenu == nil }
        check(firstLevel?.map(\.title) == catalog.commonOptions.map(\.title) &&
              zonePopup.menu?.item(withTitle: "固定 UTC 偏移")?.submenu?.items.map(\.title) == catalog.fixedOptions.map(\.title),
              "time zone menu opens with common choices and keeps fixed UTC offsets in their own submenu")
        let shanghaiOption = catalog.option(for: "Asia/Shanghai")!
        check(["亚洲", "大洋洲"].allSatisfy { region in
            zonePopup.menu?.item(withTitle: region)?.submenu?.item(withTitle: shanghaiOption.title) != nil
        }, "the Shanghai and Perth choice appears in both the Asian and Oceanian submenus")

        func chooseTimeZone(_ option: ClockTimeZoneOption, in popup: NSPopUpButton, submenu: String? = nil) {
            let menu = submenu.flatMap { popup.menu?.item(withTitle: $0)?.submenu } ?? popup.menu
            guard let menu, let index = menu.items.firstIndex(where: {
                ($0.representedObject as? ClockTimeZoneOption)?.identifier == option.identifier
            }) else {
                check(false, "time zone option \(option.title) is available")
                return
            }
            menu.performActionForItem(at: index)
        }
        for (index, slot) in ClockSlot.allCases.enumerated() {
            if let menuIndex = controller.menu.items.firstIndex(of: controller.clockSlotItems[index]) {
                controller.menu.performActionForItem(at: menuIndex)
                check(panel.face.settings.selectedClockSlot == slot && store.load().selectedClockSlot == slot &&
                      advanced.clockSlotPopup.indexOfSelectedItem == index && controller.clockSlotItems.filter { $0.state == .on }.count == 1,
                      "\(slot.rawValue) menu slot selection updates the face, preferences and advanced settings")
            } else { check(false, "\(slot.rawValue) slot menu item exists") }
        }
        advanced.clockSlotPopup.selectItem(at: 1)
        _ = advanced.clockSlotPopup.sendAction(advanced.clockSlotPopup.action, to: advanced.clockSlotPopup.target)
        check(panel.face.settings.selectedClockSlot == .second && controller.clockSlotItems[1].state == .on && store.load().selectedClockSlot == .second,
              "advanced slot selection synchronizes the face, menu checkmark and persistence")
        let pacificOption = catalog.option(for: ClockTimeZoneSettings.pacific.identifier)!
        chooseTimeZone(pacificOption, in: zonePopup)
        check(panel.face.settings.secondClockTimeZone.usesDaylightSavingTime && store.load().secondClockTimeZone.usesDaylightSavingTime &&
              controller.clockSlotItems[1].title.contains(pacificOption.title) && store.load().thirdClockTimeZone == .newYork,
              "selecting Los Angeles from common choices updates the clock and leaves the third slot unchanged")
        let fixedEastern = catalog.fixedOptions.first { $0.standardOffset == -5 * 3600 }!
        chooseTimeZone(fixedEastern, in: advanced.thirdTimeZoneRow.timeZonePopup, submenu: "固定 UTC 偏移")
        check(!store.load().thirdClockTimeZone.usesDaylightSavingTime && panel.face.settings.secondClockTimeZone.usesDaylightSavingTime &&
              controller.clockSlotItems[2].title == ClockSlot.third.title + " · UTC−05:00" &&
              advanced.thirdTimeZoneRow.statusLabel.stringValue == "当前 UTC−05:00",
              "selecting a fixed offset replaces New York's local rule and displays the fixed UTC offset")
        let kathmanduOption = catalog.option(for: "Asia/Kathmandu")!
        chooseTimeZone(kathmanduOption, in: zonePopup, submenu: "亚洲")
        check(store.load().secondClockTimeZone == kathmanduOption.settings && panel.face.settings.secondClockTimeZone == kathmanduOption.settings &&
              controller.clockSlotItems[1].title.contains(kathmanduOption.title) &&
              advanced.clockSlotPopup.titleOfSelectedItem?.contains(kathmanduOption.title) == true,
              "a fractional regional choice updates the face, persistence and both slot labels")
        advanced.close()
        advanced.showSettings()
        check(zonePopup.title == kathmanduOption.title && advanced.secondTimeZoneRow.statusLabel.stringValue == "当前 UTC+05:45" &&
              advanced.thirdTimeZoneRow.timeZonePopup.title == fixedEastern.title,
              "reopening advanced settings restores independent regional and fixed selections")
        advanced.window?.contentView?.layoutSubtreeIfNeeded()
        check([advanced.secondTimeZoneRow, advanced.thirdTimeZoneRow].allSatisfy { row in
            let popup = row.convert(row.timeZonePopup.bounds, from: row.timeZonePopup)
            return row.bounds.width <= scroll.contentView.bounds.width && popup.minX >= 0 && popup.maxX <= row.bounds.maxX
        }, "long time zone names fit the settings viewport without widening or clipping the controls on the right")
        var legacyAlias = controller.settings
        legacyAlias.secondClockTimeZone = ClockTimeZoneSettings(identifier: "US/Pacific", usesDaylightSavingTime: false)
        controller.settings = legacyAlias
        controller.onSettingsChanged?(legacyAlias)
        advanced.showSettings()
        check(store.load().secondClockTimeZone == legacyAlias.secondClockTimeZone && zonePopup.title == "UTC−08:00",
              "opening advanced settings displays a legacy standard-only selection as fixed without rewriting it")
        legacyAlias.secondClockTimeZone.usesDaylightSavingTime = true
        controller.settings = legacyAlias
        controller.onSettingsChanged?(legacyAlias)
        check(store.load().secondClockTimeZone == legacyAlias.secondClockTimeZone && zonePopup.title == pacificOption.title,
              "a saved regional alias with DST enabled shows the matching regional choice")
        var resetSlots = controller.settings
        resetSlots.selectedClockSlot = .system
        resetSlots.secondClockTimeZone = .pacific
        resetSlots.thirdClockTimeZone = .newYork
        controller.settings = resetSlots
        controller.onSettingsChanged?(resetSlots)

        let advancedTransparency = advanced.transparencyRow.slider
        advancedTransparency.doubleValue = 31
        _ = advancedTransparency.sendAction(advancedTransparency.action, to: advancedTransparency.target)
        check(panel.alphaValue == panel.face.settings.contentAlpha && abs(panel.face.settings.backgroundAlpha - 0.69) < 0.001 && store.load().transparency == 31 &&
              controller.transparencyView.slider.doubleValue == 31,
              "advanced transparency updates the clock, saved value, and menu slider together")
        let contentSlider = advanced.contentTransparencyRow.slider
        contentSlider.doubleValue = 70
        _ = contentSlider.sendAction(contentSlider.action, to: contentSlider.target)
        check(store.load().usesCustomTransparency && store.load().contentTransparency == 70 &&
              store.load().backgroundTransparency == 31 && controller.contentTransparencyView.slider.doubleValue == 70 &&
              controller.transparencyView.title == "整体透明度 · 手动分层" && advanced.transparencyRow.title == controller.transparencyView.title,
              "adjusting content alone enters manual mode and synchronizes the menu and saved settings")
        let backgroundSlider = controller.backgroundTransparencyView.slider
        backgroundSlider.doubleValue = 50
        _ = backgroundSlider.sendAction(backgroundSlider.action, to: backgroundSlider.target)
        check(store.load().backgroundTransparency == 50 && store.load().contentTransparency == 70 &&
              advanced.backgroundTransparencyRow.slider.doubleValue == 50 && advanced.transparencyRow.slider.doubleValue == 31 &&
              abs(panel.alphaValue * panel.timerTray.alphaValue - 0.30) < 0.001 && abs(panel.alphaValue - 0.50) < 0.001,
              "adjusting background leaves content unchanged even when the background is more opaque")
        _ = advancedTransparency.sendAction(advancedTransparency.action, to: advancedTransparency.target)
        check(!store.load().usesCustomTransparency && controller.backgroundTransparencyView.slider.doubleValue == 31 &&
              controller.contentTransparencyView.slider.doubleValue == store.load().contentTransparency &&
              controller.transparencyView.title == "整体透明度",
              "adjusting the overall slider relinks both layers even at the last overall value")
        advanced.lockButton.performClick(nil)
        check(panel.ignoresMouseEvents && store.load().isLocked &&
              controller.menu.items.first(where: { $0.title == "锁定位置（鼠标穿透）" })?.state == .on,
              "advanced lock updates mouse pass-through, persistence, and menu checkmark")
        advanced.lockButton.performClick(nil)
        panel.showClock()
        syncVisibility()
        advanced.visibilityButton.performClick(nil)
        check(!panel.isVisible && !controller.clockIsVisible && advanced.visibilityButton.state == .off &&
              advanced.window?.isVisible == true,
              "hiding the clock in advanced settings keeps the settings window open and menu synchronized")
        if let index = controller.menu.items.firstIndex(where: { $0.title == "显示时钟" }) {
            controller.menu.performActionForItem(at: index)
            check(panel.isVisible && advanced.visibilityButton.state == .on,
                  "showing the clock from the menu synchronizes the advanced visibility control")
            controller.menu.performActionForItem(at: index)
        } else { check(false, "visibility menu exists") }
        advanced.moveToScreenButton.performClick(nil)
        check(panel.isVisible && controller.clockIsVisible && advanced.visibilityButton.state == .on &&
              NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) },
              "advanced screen recovery shows the clock on screen and updates both visibility controls")
        if let index = controller.menu.items.firstIndex(where: { $0.title == "退出漂浮时钟" }) {
            controller.menu.performActionForItem(at: index)
            check(quitRequests == 1, "menu quit invokes its callback without terminating the test")
        } else { check(false, "menu quit exists") }
        func labels(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { [$0.title] } ?? []
            return own + view.subviews.flatMap { labels($0) }
        }
        let settingsLabels = advanced.window?.contentView.map { labels($0) } ?? []
        check(!settingsLabels.contains("高级设置") && !settingsLabels.contains("退出漂浮时钟"),
              "settings body has no duplicate heading or quit control")

        let sizeSlider = advanced.faceSizeRow.slider
        sizeSlider.doubleValue = 284
        _ = sizeSlider.sendAction(sizeSlider.action, to: sizeSlider.target)
        check(abs(panel.frame.width - 308) < 0.001 && store.load().faceSize == 284,
              "advanced size slider resizes the panel and persists")
        check(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }, "resized panel remains on screen")
        advanced.secondsButton.performClick(nil)
        check(!panel.face.settings.showsSeconds && !store.load().showsSeconds,
              "advanced seconds toggle reaches rendered face and preferences")
        check(controller.quickMenu.items[2].state == .off,
              "advanced seconds toggle updates the quick menu")
        check(advanced.stylePopup.numberOfItems == 2, "advanced style picker contains both dials")
        for (index, style) in ClockStyle.allCases.enumerated() {
            advanced.stylePopup.selectItem(at: index)
            _ = advanced.stylePopup.sendAction(advanced.stylePopup.action, to: advanced.stylePopup.target)
            check(panel.face.settings.style == style && store.load().style == style,
                  "\(style.rawValue) advanced picker updates face and preferences")
        }
        for (index, appearance) in ClockAppearance.allCases.enumerated() {
            advanced.appearancePopup.selectItem(at: index)
            _ = advanced.appearancePopup.sendAction(advanced.appearancePopup.action, to: advanced.appearancePopup.target)
            check(panel.face.settings.appearance == appearance && store.load().appearance == appearance,
                  "\(appearance.rawValue) advanced appearance persists")
        }
        check(MinuteNumerals.font.familyName == "Comic Sans MS", "minute numerals use Comic Sans MS")
        check(!advanced.minuteOpacityRow.slider.isEnabled && !advanced.minuteSizeRow.slider.isEnabled,
              "minute details are disabled while the layer is off")
        advanced.minuteNumeralsButton.performClick(nil)
        check(advanced.minuteOpacityRow.slider.isEnabled && advanced.minuteSizeRow.slider.isEnabled && panel.face.settings.showsMinuteNumerals,
              "enabling minute numerals enables their detailed controls")
        check(controller.quickMenu.items[1].state == .on,
              "advanced minute toggle updates the quick menu")
        let windowAlpha = panel.alphaValue
        let minuteSlider = advanced.minuteOpacityRow.slider
        minuteSlider.doubleValue = 67
        _ = minuteSlider.sendAction(minuteSlider.action, to: minuteSlider.target)
        check(abs(panel.face.settings.minuteNumeralAlpha - 0.67) < 0.001,
              "advanced concentration slider updates the rendered layer")
        check(panel.alphaValue == windowAlpha, "minute concentration leaves window transparency unchanged")
        let minuteSizeSlider = advanced.minuteSizeRow.slider
        minuteSizeSlider.doubleValue = 65
        _ = minuteSizeSlider.sendAction(minuteSizeSlider.action, to: minuteSizeSlider.target)
        check(panel.face.settings.minuteNumeralSize == 65 && panel.face.settings.faceSize == 284,
              "minute size changes independently of clock size")
        check(store.load().showsMinuteNumerals && store.load().minuteNumeralOpacity == 67 && store.load().minuteNumeralSize == 65,
              "minute visibility, concentration, and size persist together")
        advanced.minuteNumeralsButton.performClick(nil)
        check(!advanced.minuteOpacityRow.slider.isEnabled && !advanced.minuteSizeRow.slider.isEnabled &&
              controller.settings.minuteNumeralOpacity == 67 && controller.settings.minuteNumeralSize == 65,
              "disabling the layer retains concentration and size")
        advanced.minuteNumeralsButton.performClick(nil)
        check(advanced.minuteOpacityRow.slider.doubleValue == 67 && advanced.minuteSizeRow.slider.doubleValue == 65,
              "reenabling the layer restores its chosen details")
        advanced.dateButton.performClick(nil)
        check(!panel.face.settings.showsDate && panel.face.settings.showsMinuteNumerals,
              "minute layer remains visible when corner dates are hidden")
        advanced.close()
        advanced.showSettings()
        check(advanced.minuteSizeRow.slider.doubleValue == 65 && advanced.stylePopup.indexOfSelectedItem == 1,
              "closing and reopening settings preserves selections")
        let card = CGRect(x: 12, y: 12, width: 224, height: 224)
        for minute in ["00", "11", "58"] {
            if let full = MinuteNumerals.path(for: minute, in: card)?.boundingBoxOfPath,
               let small = MinuteNumerals.path(for: minute, in: card, size: 40)?.boundingBoxOfPath {
                check(abs(small.width / full.width - 0.4) < 0.001 &&
                      abs(small.midX - card.midX) < 0.001 && abs(small.midY - card.midY) < 0.001,
                      "minute \(minute) scales its visible outlines and remains centered")
            } else { check(false, "minute \(minute) has renderable outlines") }
        }
        panel.showClock()
        check(panel.isVisible, "clock can be shown")
        check(controller.quickMenu.items.map(\.title) == ["锁定位置", "显示分钟大字", "显示秒针"],
              "quick menu contains exactly the three requested toggles")
        let minutesBefore = panel.face.settings.showsMinuteNumerals
        controller.quickMenu.performActionForItem(at: 1)
        check(panel.face.settings.showsMinuteNumerals != minutesBefore &&
              store.load().showsMinuteNumerals == panel.face.settings.showsMinuteNumerals,
              "quick minute toggle updates the clock and saved preferences")
        check(advanced.minuteNumeralsButton.state == .off &&
              !advanced.minuteOpacityRow.slider.isEnabled && !advanced.minuteSizeRow.slider.isEnabled &&
              advanced.minuteSizeRow.slider.doubleValue == 65,
              "quick minute toggle updates advanced controls without losing their values")
        let secondsBefore = panel.face.settings.showsSeconds
        controller.quickMenu.performActionForItem(at: 2)
        check(panel.face.settings.showsSeconds != secondsBefore,
              "quick seconds toggle reaches the clock")
        check(advanced.secondsButton.state == .on,
              "quick seconds toggle updates advanced settings")
        hoverPoint = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        controller.quickMenu.performActionForItem(at: 0)
        check(panel.ignoresMouseEvents && panel.quickAccessPanel.isEntryVisible && controller.quickMenu.items[0].state == .on,
              "locking under the pointer passes clock clicks through and keeps the entry visible")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        let plusPoint = CGPoint(x: panel.quickAccessPanel.frame.midX, y: panel.quickAccessPanel.frame.midY)
        let centerPoint = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let plusHit = NSWindow.windowNumber(at: plusPoint, belowWindowWithWindowNumber: 0)
        let centerHit = NSWindow.windowNumber(at: centerPoint, belowWindowWithWindowNumber: 0)
        check(plusHit == panel.quickAccessPanel.windowNumber, "WindowServer routes plus clicks to the small entry window")
        check(centerHit != panel.windowNumber && centerHit != panel.quickAccessPanel.windowNumber,
              "WindowServer routes locked clock center clicks to underlying windows")
        var requests = 0
        panel.onQuickMenuRequested = { _ in requests += 1 }
        panel.quickAccessPanel.button.performClick(nil)
        check(requests == 1, "plus button requests the quick menu without unlocking the clock")
        if let screen = panel.screen?.visibleFrame {
            for (x, y, corner) in [(screen.minX + 20, screen.maxY - panel.frame.height - 20, ClockCorner.topRight),
                                    (screen.maxX - panel.frame.width - 20, screen.maxY - panel.frame.height - 20, .topLeft),
                                    (screen.minX + 20, screen.minY + 20, .bottomRight),
                                    (screen.maxX - panel.frame.width - 20, screen.minY + 20, .bottomLeft)] {
                hoverPoint = CGPoint(x: x + panel.frame.width / 2, y: y + panel.frame.height / 2)
                panel.setFrameOrigin(CGPoint(x: x, y: y))
                let card = panel.face.bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
                let expected = panel.convertToScreen(QuickAccessLayout.buttonFrame(in: card, corner: corner))
                check(panel.face.quickAccessCorner == corner &&
                      abs(panel.quickAccessPanel.frame.minX - expected.minX) < 1 &&
                      abs(panel.quickAccessPanel.frame.minY - expected.minY) < 1,
                      "\(corner.rawValue) entry follows the clock and avoids the nearer horizontal edge")
            }
        }
        hoverPoint = CGPoint(x: -100_000, y: -100_000)
        controller.quickMenu.performActionForItem(at: 0)
        check(!panel.ignoresMouseEvents && !panel.quickAccessPanel.isEntryVisible && panel.face.quickAccessCorner == nil,
              "quick unlock restores dragging and removes the plus entry")
        check(controller.menu.items.first(where: { $0.title == "锁定位置（鼠标穿透）" })?.state == .off,
              "quick settings stay synchronized with the full menu")
        controller.quickMenu.performActionForItem(at: 0)
        panel.hideClock()
        check(!panel.isVisible, "clock can be hidden")
        check(!panel.quickAccessPanel.isEntryVisible, "hiding the clock also hides its small entry")

        let scheduler = CheckTimerNotifications()
        let timerStore = ClockTimerStore(defaults: defaults)
        let timers = TimerCoordinator(store: timerStore, notifications: scheduler)
        let timerPanel = ClockPanel(settings: ClockSettings())
        timerPanel.timerCoordinator = timers
        timers.onChange = { [weak timerPanel] in timerPanel?.refreshTimers() }
        timerPanel.showClock()
        defer { timerPanel.hideClock() }
        timerPanel.face.onHoverChanged?(false)
        check(timerPanel.addTimerButton.isHidden && !timerPanel.quickAccessPanel.isEntryVisible,
              "unlocked idle clock hides both entries outside its hover area")
        timerPanel.face.onHoverChanged?(true)
        check(!timerPanel.addTimerButton.isHidden && !timerPanel.quickAccessPanel.isEntryVisible,
              "hovering unlocked clock shows only the timer entry")
        timerPanel.addTimerButton.performClick(nil)
        check(timers.timers.count == 1 && timerPanel.timerTray.rows.count == 1 && timerPanel.canBecomeKey,
              "timer entry adds an editable timer and allows keyboard input")
        check(!timerPanel.timerHint.isHidden && timerPanel.timerHint.frame.maxY < timerPanel.timerTray.frame.minY &&
              timerPanel.timerHint.frame.maxY < (timerPanel.face.dialFrame?.minY ?? 0) + ClockLayout.padding,
              "a single timer shows its sign hint at the bottom of the entire window")
        timerPanel.addTimerButton.performClick(nil)
        check(timers.timers.count == 2 && timerPanel.timerHint.isHidden,
              "adding a second timer removes the bottom sign hint")
        timerPanel.addTimerButton.performClick(nil)
        timerPanel.addTimerButton.performClick(nil)
        check(timers.timers.count == 3 && timerPanel.timerTray.rows.count == 3,
              "timer entry enforces a maximum of three timer groups")
        check(timers.timers.allSatisfy { $0.state == .idle } && scheduler.scheduled.isEmpty,
              "moving focus between new timer inputs does not start timers")
        check(timerPanel.frame.height > timerPanel.frame.width && NSScreen.screens.contains { $0.visibleFrame.contains(timerPanel.frame) },
              "three timers form a rectangular window kept inside the display")
        timerPanel.face.layoutSubtreeIfNeeded()
        check(timerPanel.timerTray.rows.allSatisfy { $0.bounds.contains($0.convert($0.deleteButton.bounds, from: $0.deleteButton)) },
              "timer row controls fit within the expanded card")
        let row = timerPanel.timerTray.rows[0]
        func stackedButtons(in row: TimerRowView) -> Bool {
            let left = [row.signButton, row.kindButton, row.resetButton].filter { !$0.isHidden }
                .map { row.convert($0.bounds, from: $0) }
            let right = [row.primaryButton, row.deleteButton].map { row.convert($0.bounds, from: $0) }
            func validColumn(_ frames: [CGRect]) -> Bool {
                frames.allSatisfy { row.bounds.contains($0) && abs($0.midX - frames[0].midX) < 1 } &&
                zip(frames, frames.dropFirst()).allSatisfy { !$0.intersects($1) }
            }
            let leftBounds = left.reduce(CGRect.null) { $0.union($1) }
            let rightBounds = right.reduce(CGRect.null) { $0.union($1) }
            return validColumn(left) && validColumn(right) && abs(leftBounds.midY - rightBounds.midY) < 1 &&
                abs(leftBounds.midY - row.bounds.midY) < 1
        }
        timerPanel.makeFirstResponder(row.durationInput.minutes.field)
        row.durationInput.minutes.field.selectText(nil)
        if let editor = row.durationInput.minutes.field.currentEditor() as? NSTextView {
            editor.insertText("9999", replacementRange: editor.selectedRange())
            editor.insertText("9", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        }
        let fifthDigitWasRejected = row.durationInput.minutes.field.currentEditor()?.string == "9999"
        row.durationInput.minutes.field.selectText(nil)
        if let editor = row.durationInput.minutes.field.currentEditor() as? NSTextView {
            editor.insertText("1234567", replacementRange: editor.selectedRange())
        }
        check(fifthDigitWasRejected && row.durationInput.minutes.field.currentEditor()?.string == "9999",
              "number fields immediately reject a fifth digit and a paste longer than four digits")
        timerPanel.makeFirstResponder(nil)
        row.durationInput.hours.update(value: 9999)
        row.durationInput.minutes.update(value: 9999)
        row.durationInput.commit()
        timerPanel.face.layoutSubtreeIfNeeded()
        let fourDigitWidth = ceil("9999".size(withAttributes: [.font: row.durationInput.hours.field.font!]).width) + 4
        check(stackedButtons(in: row) && timerPanel.frame.width == 284 && [row.durationInput.hours, row.durationInput.minutes].allSatisfy { input in
            input.field.bounds.width >= fourDigitWidth && row.bounds.contains(row.convert(input.stepper.bounds, from: input.stepper))
        } && row.durationInput.hours.value == 9999 && row.durationInput.minutes.value == 9999,
              "both four-digit inputs fit at the original window width with buttons stacked on each side")
        timers.editInput(row.id, text: "5")
        row.durationInput.minutes.field.integerValue = 90
        row.durationInput.minutes.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        check(!row.durationInput.isHidden && row.timeField.isHidden && row.durationInput.hours.value == 1 && row.durationInput.minutes.value == 30,
              "separate hour and minute fields normalize ninety minutes without starting the timer")
        row.durationInput.hours.stepper.integerValue = 2
        _ = row.durationInput.hours.stepper.sendAction(row.durationInput.hours.stepper.action, to: row.durationInput.hours.stepper.target)
        check((try? TimerInputParser.duration(timers.timers[0].input)) == 9000 && scheduler.scheduled.isEmpty,
              "native hour stepper updates the saved duration without starting a timer")
        row.durationInput.hours.stepper.integerValue = 1
        _ = row.durationInput.hours.stepper.sendAction(row.durationInput.hours.stepper.action, to: row.durationInput.hours.stepper.target)
        row.primaryButton.performClick(nil)
        check(timers.timers[0].state == .running && scheduler.scheduled.last?.duration == 5400,
              "row play action starts a 90-minute countdown and schedules a system notification")
        let scheduledCount = scheduler.scheduled.count
        var locked = ClockSettings()
        locked.isLocked = true
        let lockedPointer = CGPoint(x: timerPanel.frame.midX, y: timerPanel.frame.midY)
        timerPanel.mouseLocationProvider = { lockedPointer }
        timerPanel.apply(locked)
        timerPanel.face.onHoverChanged?(true)
        check(timerPanel.ignoresMouseEvents && !timerPanel.canBecomeKey && timerPanel.addTimerButton.isHidden && timerPanel.quickAccessPanel.isEntryVisible,
              "locking expanded clock keeps only the plus entry and restores pass-through")
        check(timers.timers[0].state == .running && scheduler.scheduled.count == scheduledCount,
              "locking does not stop or duplicate timer notifications")
        locked.isLocked = false
        locked.timerDisplayFormat = .hoursMinutes
        timerPanel.apply(locked)
        timerPanel.face.onHoverChanged?(true)
        check(!timerPanel.addTimerButton.isHidden && !timerPanel.quickAccessPanel.isEntryVisible && row.timeField.stringValue.hasPrefix("1时"),
              "unlocking restores the hover timer entry and the hour-minute readout")
        row.primaryButton.performClick(nil)
        check(timers.timers[0].state == .paused && scheduler.cancelled.contains(row.id),
              "stop preserves remaining time and cancels its pending notification")
        timerPanel.face.layoutSubtreeIfNeeded()
        check(!row.resetButton.isHidden && stackedButtons(in: row), "the paused timer reset icon joins the left button column")
        row.resetButton.performClick(nil)
        check(timers.timers[0].state == .idle && !row.durationInput.isHidden && row.durationInput.minutes.field.isEditable,
              "reset restores the editable input")
        row.signButton.performClick(nil)
        let beforeElapsed = scheduler.scheduled.count
        timers.primaryAction(row.id, at: Date().addingTimeInterval(-120))
        check(timers.timers[0].mode == .elapsed && timers.timers[0].seconds(at: Date()) >= 120 && scheduler.scheduled.count == beforeElapsed,
              "minus starts elapsed counting from zero without scheduling a countdown notification")
        row.primaryButton.performClick(nil)
        check(timers.timers[0].state == .paused && row.timeField.stringValue.hasPrefix("02分"),
              "elapsed stop retains its accumulated readout")
        row.deleteButton.performClick(nil)
        check(timers.timers.count == 2 && !timers.timers.contains { $0.id == row.id },
              "delete removes exactly one timer group")
        let countdown = timerPanel.timerTray.rows[0]
        timers.editInput(countdown.id, text: "1秒")
        scheduler.message = "通知未开启"
        let started = Date()
        timers.primaryAction(countdown.id, at: started)
        check(timers.notificationMessage == "通知未开启", "notification permission failure is surfaced in the timer card")
        timerPanel.hideClock()
        timers.tick(at: started.addingTimeInterval(2))
        check(timers.timers[0].state == .running && timers.timers[0].isOvertime && !timerPanel.isVisible && timerPanel.addTimerButton.isHidden,
              "hidden clock crosses zero into overtime without reopening itself")
        let afterCompletion = scheduler.scheduled.count
        timers.tick(at: started.addingTimeInterval(20))
        check(scheduler.scheduled.count == afterCompletion, "countdown completion does not send duplicate notifications")
        check(countdown.signButton.title == "−" && timers.timers[0].seconds(at: started.addingTimeInterval(20)) == 19,
              "overtime switches the visible sign to minus and counts from the original deadline")
        let cancelledBeforeOvertimeStop = scheduler.cancelled.count
        timers.primaryAction(countdown.id, at: started.addingTimeInterval(21))
        check(timers.timers[0].state == .paused && timers.timers[0].seconds(at: started.addingTimeInterval(40)) == 20 && scheduler.cancelled.count == cancelledBeforeOvertimeStop,
              "stopping overtime preserves the overrun and its already due notification")
        timers.primaryAction(countdown.id, at: started.addingTimeInterval(40))
        check(timers.timers[0].state == .running && timers.timers[0].seconds(at: started.addingTimeInterval(45)) == 25 && scheduler.scheduled.count == afterCompletion,
              "resuming overtime continues the negative count without another notification")
        countdown.deleteButton.performClick(nil)
        check(timers.timers.count == 1 && !timerPanel.timerHint.isHidden,
              "deleting back to one timer restores the bottom hint without leaving old views")
        timerPanel.timerTray.rows[0].deleteButton.performClick(nil)
        let side = ClockSettings().faceSize + ClockLayout.padding * 2
        check(timers.timers.isEmpty && timerPanel.frame.size == CGSize(width: side, height: side) && !timerPanel.canBecomeKey,
              "deleting the last group restores the square clock and passive focus behavior")
        scheduler.deferCompletion = true
        let delayed = timers.add()!
        timers.editInput(delayed, text: "1秒")
        let delayedStart = Date()
        timers.primaryAction(delayed, at: delayedStart)
        timers.tick(at: delayedStart.addingTimeInterval(2))
        scheduler.pending.last?("通知未开启")
        check(timers.notificationMessage == "通知未开启", "late permission denial remains visible after a short countdown completes")
        timers.remove(delayed)
        scheduler.pending.last?("通知未开启")
        check(timers.notificationMessage == nil && timers.timers.isEmpty, "late notification callbacks cannot restore a deleted timer or warning")
        advanced.timerFormatPopup.selectItem(at: 1)
        _ = advanced.timerFormatPopup.sendAction(advanced.timerFormatPopup.action, to: advanced.timerFormatPopup.target)
        check(store.load().timerDisplayFormat == .hoursMinutes && panel.face.settings.timerDisplayFormat == .hoursMinutes,
              "advanced timer format selection updates the clock and persists")
        timerPanel.showClock()
        for deletedIndex in 0..<3 {
            for _ in 0..<3 { timerPanel.addTimerButton.performClick(nil) }
            timerPanel.face.layoutSubtreeIfNeeded()
            let removed = timerPanel.timerTray.rows[deletedIndex].id
            timerPanel.timerTray.rows[deletedIndex].deleteButton.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            timerPanel.face.layoutSubtreeIfNeeded()
            let tray = timerPanel.timerTray
            let attachedRows = tray.subviews.compactMap { $0 as? TimerRowView }
            check(timers.timers.count == 2 && tray.rows.count == 2 && attachedRows.count == 2 &&
                  Set(attachedRows.map(\.id)) == Set(timers.timers.map(\.id)) && !attachedRows.contains { $0.id == removed },
                  "deleting row \(deletedIndex + 1) while the last input is focused leaves exactly two attached rows")
            check(tray.rows.allSatisfy { tray.bounds.contains($0.frame) && $0.frame.height == $0.preferredHeight } &&
                  !tray.rows[0].frame.intersects(tray.rows[1].frame),
                  "deleting row \(deletedIndex + 1) keeps the two remaining row frames separate inside the tray")
            for id in timers.timers.map(\.id) { timers.remove(id) }
        }
        timerPanel.addTimerButton.performClick(nil)
        let targetRow = timerPanel.timerTray.rows[0]
        targetRow.kindButton.performClick(nil)
        check(timers.timers[0].inputKind == .targetTime && targetRow.kindButton.image != nil && !targetRow.targetInput.isHidden && targetRow.timeField.isHidden,
              "switching a focused duration input to target time keeps the selected mode")
        var allSwitchesSucceeded = true
        for _ in 0..<3 {
            targetRow.kindButton.performClick(nil)
            timerPanel.makeFirstResponder(targetRow.durationInput.minutes.field)
            targetRow.kindButton.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            allSwitchesSucceeded = allSwitchesSucceeded && timers.timers[0].inputKind == .targetTime && targetRow.kindButton.image != nil && targetRow.targetInput.hours.field.currentEditor() != nil
        }
        check(allSwitchesSucceeded, "repeated duration-to-target switches remain stable with an active numeric field")
        // Exercise the real field editor and play action against a fixed local time.
        let localNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 18, minute: 34))!
        timerPanel.makeFirstResponder(nil)
        timers.setInputKind(targetRow.id, kind: .duration)
        timers.setInputKind(targetRow.id, kind: .targetTime, at: localNow)
        check(timers.timers[0].input == "18:35", "target preset uses the next minute instead of adding an hour")
        timerPanel.makeFirstResponder(targetRow.targetInput.hours.field)
        targetRow.targetInput.hours.field.selectText(nil)
        if let editor = targetRow.targetInput.hours.field.currentEditor() as? NSTextView {
            editor.insertText("18", replacementRange: editor.selectedRange())
        }
        if let editor = targetRow.targetInput.minutes.field.currentEditor() as? NSTextView {
            editor.insertText("40", replacementRange: editor.selectedRange())
        }
        let targetID = targetRow.id
        targetRow.onPrimary = { timers.primaryAction(targetID, at: localNow) }
        targetRow.primaryButton.performClick(nil)
        check(timers.timers[0].input == "18:40" && timers.timers[0].duration == 360 && scheduler.scheduled.last?.deadline == localNow.addingTimeInterval(360),
              "editing 18:40 then clicking play at 18:34 schedules exactly six minutes")
        timers.primaryAction(targetID, at: localNow.addingTimeInterval(1))
        timers.reset(targetID)
        timerPanel.makeFirstResponder(targetRow.targetInput.hours.field)
        targetRow.targetInput.hours.field.selectText(nil)
        for character in "1930" {
            if let editor = timerPanel.firstResponder as? NSTextView {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
            }
        }
        check(targetRow.targetInput.hours.value == 19 && targetRow.targetInput.minutes.value == 30 &&
              targetRow.targetInput.minutes.field.currentEditor() != nil && timers.timers[0].input == "19:30" && timers.timers[0].state == .idle,
              "typing 1930 moves the caret from hours to selected minutes automatically without mouse input")
        timerPanel.makeFirstResponder(targetRow.targetInput.hours.field)
        targetRow.targetInput.hours.field.selectText(nil)
        if let editor = targetRow.targetInput.hours.field.currentEditor() as? NSTextView {
            editor.insertText("1930", replacementRange: editor.selectedRange())
        }
        check(targetRow.targetInput.hours.value == 19 && targetRow.targetInput.minutes.value == 30 && timers.timers[0].input == "19:30",
              "pasting four clock digits also splits them into hour and minute fields")
        let hourStepper = targetRow.targetInput.hours.stepper
        let minuteStepper = targetRow.targetInput.minutes.stepper
        for value in [20, 19] {
            hourStepper.integerValue = value
            _ = hourStepper.sendAction(hourStepper.action, to: hourStepper.target)
        }
        for value in [31, 30] {
            minuteStepper.integerValue = value
            _ = minuteStepper.sendAction(minuteStepper.action, to: minuteStepper.target)
        }
        check(timers.timers[0].input == "19:30" && hourStepper.maxValue == 23 && minuteStepper.maxValue == 59,
              "target hour and minute steppers edit a 24-hour time within valid limits")
        targetRow.targetInput.hours.update(value: 20)
        targetRow.targetInput.commit()
        timers.editInput(targetID, text: "18:40")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(targetRow.targetInput.hours.value == 18 && targetRow.targetInput.minutes.value == 40 && timers.timers[0].input == "18:40",
              "a delayed input refresh cannot overwrite a newer target time")
        timers.editInput(targetID, text: "2030-11-15 19:30:15")
        minuteStepper.integerValue = 31
        _ = minuteStepper.sendAction(minuteStepper.action, to: minuteStepper.target)
        check(timers.timers[0].input == "2030-11-15 19:31:15", "editing target digits preserves a legacy explicit date and seconds")
        let lateNight = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 23, minute: 59))!
        timers.setInputKind(targetID, kind: .duration)
        timers.setInputKind(targetID, kind: .targetTime, at: lateNight)
        targetRow.targetInput.hours.update(value: 0)
        targetRow.targetInput.minutes.update(value: 5)
        targetRow.onPrimary = { timers.primaryAction(targetID, at: lateNight) }
        targetRow.primaryButton.performClick(nil)
        check(timers.timers[0].input == "00:05" && timers.timers[0].duration == 360,
              "numeric midnight target rolls to the next day and counts exactly six minutes")
        timers.primaryAction(targetID, at: lateNight.addingTimeInterval(1))
        timers.reset(targetID)
        timers.editInput(targetID, text: "18:")
        timers.primaryAction(targetID, at: localNow)
        let modePickerIsAvailable = !targetRow.kindButton.isHidden && timers.errors[targetID] != nil
        targetRow.kindButton.performClick(nil)
        check(modePickerIsAvailable && timers.timers[0].inputKind == .duration && timers.errors[targetID] == nil,
              "invalid target text leaves the mode icon available and can switch back to duration")
        timers.remove(targetRow.id)
        let previousAppAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)
        var themeSettings = ClockSettings()
        themeSettings.appearance = .system
        timerPanel.apply(themeSettings)
        let idleDuration = timers.add()!
        let idleTarget = timers.add()!
        timers.setInputKind(idleTarget, kind: .targetTime)
        let stoppedElapsed = timers.add()!
        timers.toggleMode(stoppedElapsed)
        timers.primaryAction(stoppedElapsed, at: Date().addingTimeInterval(-90))
        timers.primaryAction(stoppedElapsed)
        timerPanel.face.layoutSubtreeIfNeeded()
        let themeRows = timerPanel.timerTray.rows
        let activeNumber = themeRows[0].durationInput.minutes.field
        timerPanel.makeKey()
        timerPanel.makeFirstResponder(activeNumber)
        activeNumber.selectText(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let editor = activeNumber.currentEditor() as? NSTextView
        let editorText = editor?.string
        let editorSelection = editor?.selectedRange()
        let unchangedTimers = timers.timers
        let unchangedFrame = timerPanel.frame
        var themeStateChanges = 0
        let previousChange = timers.onChange
        timers.onChange = { themeStateChanges += 1; previousChange?() }
        func matchesPalette(_ color: NSColor?, dark: Bool) -> Bool {
            guard let color = color?.usingColorSpace(.sRGB) else { return false }
            let value = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            return dark ? value > 0.8 : value < 0.3
        }
        func rowsMatchPalette(dark: Bool) -> Bool {
            let duration = themeRows[0].durationInput
            let target = themeRows[1].targetInput
            let inputs = [duration.hours, duration.minutes, target.hours, target.minutes]
            return inputs.allSatisfy { input in
                let labels = input.subviews.compactMap { $0 as? NSTextField }
                return labels.allSatisfy { matchesPalette($0.textColor, dark: dark) }
            } && themeRows.allSatisfy { row in
                matchesPalette(row.statusLabel.textColor, dark: dark) &&
                matchesPalette(row.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), dark: dark)
            } && matchesPalette(themeRows[2].timeField.textColor, dark: dark)
        }
        for dark in [true, false] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            check(rowsMatchPalette(dark: dark), "system \(dark ? "dark" : "light") appearance immediately updates idle inputs, units, status and stopped readout")
            check(activeNumber.currentEditor() === editor && editor?.string == editorText && editor?.selectedRange() == editorSelection &&
                  matchesPalette(editor?.textColor, dark: dark) && matchesPalette(editor?.insertionPointColor, dark: dark),
                  "system \(dark ? "dark" : "light") appearance updates the active editor and caret without disturbing input")
        }
        check(themeStateChanges == 0 && timers.timers == unchangedTimers && timerPanel.frame == unchangedFrame &&
              zip(themeRows, timerPanel.timerTray.rows).allSatisfy { $0 === $1 },
              "following system appearance needs no timer state changes, replacement rows or layout changes")
        for appearance in [ClockAppearance.dark, .light] {
            themeSettings.appearance = appearance
            timerPanel.apply(themeSettings)
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .aqua : .darkAqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            check(rowsMatchPalette(dark: appearance == .dark), "explicit \(appearance.rawValue) appearance remains fixed when inherited appearance changes")
            check(activeNumber.currentEditor() === editor && editor?.string == editorText && editor?.selectedRange() == editorSelection &&
                  matchesPalette(editor?.textColor, dark: appearance == .dark) && matchesPalette(editor?.insertionPointColor, dark: appearance == .dark),
                  "explicit \(appearance.rawValue) updates the active editor and caret without changing text or selection")
        }
        timers.onChange = previousChange
        timerPanel.makeFirstResponder(nil)
        for id in [idleDuration, idleTarget, stoppedElapsed] { timers.remove(id) }
        checkTimerInputRegressions(check)
        checkTimerDragging(check)
        checkSizeHoverAndOpacity(check)
        checkVisualPolish(check)
        checkSnapshotGroupOpacity(check)
        DialCacheChecks.run(check)
        checkTimeZoneRendering(check)
        let result: [String: Any] = ["passed": failures.isEmpty, "count": checks.count, "checks": checks, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }

    private static func checkTimeZoneRendering(_ check: (Bool, String) -> Void) {
        var settings = ClockSettings()
        settings.transparency = 0
        settings.showsSeconds = false
        settings.selectedClockSlot = .second
        let panel = ClockPanel(settings: settings)
        defer { panel.hideClock() }
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-07-15T04:20:00Z")!
        func image() -> Data? {
            panel.apply(settings)
            panel.face.layoutSubtreeIfNeeded()
            let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds)!
            panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let pacific = image()
        settings.selectedClockSlot = .third
        let newYork = image()
        check(pacific != nil && newYork != nil && pacific != newYork,
              "switching from Pacific to New York redraws the real clock hands and midnight date")
        settings.thirdClockTimeZone.usesDaylightSavingTime = false
        let standard = image()
        check(standard != nil && standard != newYork, "disabling New York DST redraws the real hour hand and midnight date")
        settings.showsMinuteNumerals = true
        settings.thirdClockTimeZone = ClockTimeZoneSettings(identifier: "Asia/Kathmandu", usesDaylightSavingTime: true)
        let kathmandu = image()
        settings.thirdClockTimeZone.identifier = "Asia/Shanghai"
        let shanghai = image()
        check(kathmandu != nil && shanghai != nil && kathmandu != shanghai,
              "fractional-offset time zones redraw the minute hand and invalidate cached minute numerals")
    }

    private static func checkSnapshotGroupOpacity(_ check: (Bool, String) -> Void) {
        var settings = ClockSettings()
        settings.transparency = 45
        let panel = ClockPanel(settings: settings)
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
        defer { panel.hideClock() }
        for appearance in [ClockAppearance.light, .dark] {
            settings.appearance = appearance
            panel.apply(settings)
            panel.face.layoutSubtreeIfNeeded()
            let card = panel.face.dialCard
            let sample = CGPoint(x: card.midX - 60, y: card.midY)
            for scale in [1, 2] {
                for space in [NSColorSpaceName.deviceRGB, .calibratedRGB] {
                    var fullBitmap: NSBitmapImageRep?
                    for cropped in [false, true] {
                        let rect = cropped ? panel.face.bounds.insetBy(dx: 6, dy: 6) : panel.face.bounds
                        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width) * scale,
                            pixelsHigh: Int(rect.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: space, bytesPerRow: 0, bitsPerPixel: 0)!
                        bitmap.size = rect.size
                        panel.face.cacheDisplay(in: rect, to: bitmap)
                        let x = Int((sample.x - rect.minX) * CGFloat(scale))
                        let y = Int((rect.maxY - sample.y) * CGFloat(scale))
                        let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1
                        let expected = settings.backgroundAlpha / panel.alphaValue
                        check(panel.face.cardLayer?.shadowOpacity ?? 0 > 0 && abs(alpha - expected) <= 1.5 / 255,
                              "\(appearance.rawValue) \(scale)x \(space.rawValue) \(cropped ? "offset" : "full") snapshot composites the shadow and card once at quantized relative alpha (actual \(alpha), expected \(expected))")
                        if !cropped { fullBitmap = bitmap }
                        if let full = fullBitmap, cropped {
                            var maximum: CGFloat = 0
                            for pointY in stride(from: Int(rect.minY) + 1, to: Int(rect.maxY) - 1, by: 5) {
                                for pointX in stride(from: Int(rect.minX) + 1, to: Int(rect.maxX) - 1, by: 5) {
                                    let fullAlpha = full.colorAt(x: pointX * scale, y: (Int(panel.face.bounds.maxY) - pointY) * scale)?.alphaComponent ?? -1
                                    let croppedAlpha = bitmap.colorAt(x: (pointX - Int(rect.minX)) * scale,
                                        y: (Int(rect.maxY) - pointY) * scale)?.alphaComponent ?? -1
                                    maximum = max(maximum, abs(fullAlpha - croppedAlpha))
                                }
                            }
                            check(maximum <= 2.0 / 255,
                                  "\(appearance.rawValue) \(scale)x \(space.rawValue) offset snapshot matches full-image alpha including shadow (maximum difference \(maximum))")
                        }
                    }
                }
            }
        }
    }

    private static func checkVisualPolish(_ check: (Bool, String) -> Void) {
        let suite = "FloatingClock.visual-regressions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = CheckTimerNotifications()
        let timers = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: scheduler)
        let panel = ClockPanel(settings: ClockSettings())
        panel.timerCoordinator = timers
        timers.onChange = { [weak panel] in panel?.refreshTimers() }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        defer { panel.hideClock() }

        func bitmap() -> NSBitmapImageRep {
            panel.face.layoutSubtreeIfNeeded()
            let image = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds)!
            panel.face.cacheDisplay(in: panel.face.bounds, to: image)
            return image
        }
        func edgeAlpha(_ image: NSBitmapImageRep) -> CGFloat {
            let w = image.pixelsWide, h = image.pixelsHigh
            let edge = (0..<w).flatMap { [($0, 0), ($0, h - 1)] } + (0..<h).flatMap { [(0, $0), (w - 1, $0)] }
            return edge.map { image.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1 }.max() ?? 1
        }
        func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 &&
                abs(a.blueComponent - b.blueComponent) < 0.01
        }

        // Compare the rendered live card layer itself, not a replacement path.
        panel.face.layoutSubtreeIfNeeded()
        func cardBitmap() -> NSBitmapImageRep {
            let layer = panel.face.cardLayer!
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(layer.bounds.width), pixelsHigh: Int(layer.bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            layer.render(in: NSGraphicsContext(bitmapImageRep: image)!.cgContext)
            return image
        }
        let continuous = cardBitmap()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.face.cardLayer?.cornerCurve = .circular
        CATransaction.commit()
        let circular = cardBitmap()
        let stayedCircular = panel.face.cardLayer?.cornerCurve == .circular
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.face.cardLayer?.cornerCurve = .continuous
        CATransaction.commit()
        var cornerDifferences = 0
        for y in 0..<min(100, continuous.pixelsHigh) {
            for x in 0..<min(100, continuous.pixelsWide) {
                let a = continuous.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let b = circular.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if abs(a - b) > 0.05 { cornerDifferences += 1 }
            }
        }
        check(stayedCircular, "test capture preserves the selected live corner curve")
        check(cornerDifferences > 0, "live continuous card layer produces pixels distinct from a circular corner")

        for appearance in [ClockAppearance.light, .dark] {
            for size in [260.0, 300, 420] {
                for above in [false, true] {
                    var settings = ClockSettings()
                    settings.appearance = appearance
                    settings.faceSize = size
                    settings.transparency = 0
                    settings.origin = StoredPoint(x: screen.midX - size / 2,
                                                  y: above ? screen.minY + 16 : screen.maxY - size - 40)
                    // A new panel is not needed: move the existing dial to the requested screen quadrant.
                    panel.setFrameOrigin(CGPoint(x: settings.origin!.x, y: settings.origin!.y))
                    panel.apply(settings)
                    let radius = panel.face.cardCornerRadius
                    let width = panel.frame.width
                    let plain = bitmap()
                    let plainEdge = edgeAlpha(plain)
                    var geometryOK = true
                    for count in 1...3 {
                        _ = timers.add()
                        panel.face.layoutSubtreeIfNeeded()
                        let tray = panel.timerTray
                        let rows = tray.rows
                        let gap = CardGeometry.inset
                        geometryOK = geometryOK && rows.count == count && rows.allSatisfy { row in
                            let controls = [row.signButton, row.kindButton, row.primaryButton, row.deleteButton].filter { !$0.isHidden }
                            let input = row.durationInput.convert(row.durationInput.bounds, to: row)
                            return row.layer?.cornerCurve == .continuous &&
                                abs((row.layer?.cornerRadius ?? 0) - CardGeometry.innerRadius(height: row.bounds.height)) < 0.01 &&
                                abs(row.frame.minX - gap) < 0.01 && abs(tray.bounds.maxX - row.frame.maxX - gap) < 0.01 &&
                                input.width >= 180 && controls.allSatisfy { button in
                                    let frame = button.convert(button.bounds, to: row)
                                    return row.bounds.contains(frame) && !frame.intersects(input)
                                }
                        }
                        geometryOK = geometryOK && zip(rows, rows.dropFirst()).allSatisfy {
                            abs($0.0.frame.minY - $0.1.frame.maxY - gap) < 0.01
                        }
                        let outerGap = above ? tray.bounds.maxY - rows[0].frame.maxY : rows.last!.frame.minY
                        geometryOK = geometryOK && abs(outerGap - gap) < 0.01
                    }
                    panel.face.layoutSubtreeIfNeeded()
                    check(geometryOK && panel.face.cardLayer?.cornerCurve == .continuous &&
                          panel.face.cardLayer?.cornerRadius == CardGeometry.outerRadius &&
                          CardGeometry.innerRadius(height: 48) == 24,
                          "\(appearance.rawValue) \(Int(size)) \(above ? "above" : "below") uses continuous linked radii and eight-point row insets at 1–3 rows without control overlap")
                    let image = bitmap()
                    let outer = NSBezierPath(roundedRect: panel.face.bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding),
                                             xRadius: radius, yRadius: radius)
                    let rowsFit = panel.timerTray.rows.allSatisfy { row in
                        let shape = NSBezierPath(roundedRect: row.bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
                        return stride(from: 0.0, through: row.bounds.width, by: 2).allSatisfy { x in
                            stride(from: 0.0, through: row.bounds.height, by: 2).allSatisfy { y in
                                let point = CGPoint(x: x, y: y)
                                return !shape.contains(point) || outer.contains(row.convert(point, to: panel.face))
                            }
                        }
                    }
                    let direction = (panel.timerTray.frame.midY > panel.face.dialCard.midY) == above
                    let expandedRadius = panel.face.cardCornerRadius
                    for id in timers.timers.map(\.id) { timers.remove(id) }
                    check(radius == 32 && expandedRadius == radius && panel.face.cardCornerRadius == radius &&
                          panel.frame.width == width && panel.frame.height == width && direction && rowsFit,
                          "\(appearance.rawValue) \(Int(size)) \(above ? "above" : "below") keeps one stable rounded card and rows inside it across add/delete")
                    check(plainEdge <= 1.0 / 255 && edgeAlpha(image) <= 1.0 / 255,
                          "\(appearance.rawValue) \(Int(size)) \(above ? "above" : "below") actual plain and expanded shadow pixels fade at every window edge")
                }
            }
        }
        var settings = ClockSettings()
        for text in ["12", "3", "6", "9"] {
            for size in [260.0, 300, 420] {
                let center = CGPoint(x: 123.4, y: 98.7)
                let path = ClockFaceView.cardinalPath(text, at: center, font: .systemFont(ofSize: 18 * size / 224, weight: .regular))
                let bounds = path?.boundingBoxOfPath ?? .null
                check(!bounds.isNull && abs(bounds.midX - center.x) < 0.001 && abs(bounds.midY - center.y) < 0.001,
                      "cardinal \(text) at \(Int(size)) is centered by its actual glyph ink")
            }
        }
        settings.minuteNumeralOpacity = 60
        settings.showsMinuteNumerals = true
        let atThreshold = ClockFaceView.haloStrength(settings: settings)
        settings.minuteNumeralOpacity = 80
        let intermediate = ClockFaceView.haloStrength(settings: settings)
        settings.minuteNumeralOpacity = 100
        let maximum = ClockFaceView.haloStrength(settings: settings)
        settings.showsMinuteNumerals = false
        check(atThreshold == 0 && intermediate > 0 && intermediate < maximum && maximum == 1 &&
              ClockFaceView.haloStrength(settings: settings) == 0 && settings.minuteNumeralOpacity == 100,
              "hand halo starts above 60 percent, ramps smoothly, and never changes the user's concentration")
        for size in [260.0, 300, 420] {
            for appearance in [ClockAppearance.light, .dark] {
                settings.faceSize = size
                settings.appearance = appearance
                var idle = ClockTimer()
                idle.input = "9999小时9999分钟"
                var target = ClockTimer()
                target.inputKind = .targetTime
                target.input = "19:30"
                var running = ClockTimer()
                try? running.start(at: Date())
                var paused = running
                paused.pause(at: Date())
                let row = TimerRowView(timer: idle)
                var allFit = true
                for (timer, error) in [(idle, nil), (target, nil), (running, nil), (paused, nil), (idle, "输入错误")] as [(ClockTimer, String?)] {
                    row.refresh(timer: timer, settings: settings, error: error)
                    row.frame = CGRect(x: 0, y: 0, width: size - 2 * CardGeometry.inset, height: row.preferredHeight)
                    row.layoutSubtreeIfNeeded()
                    let buttons = [row.signButton, row.kindButton, row.resetButton, row.primaryButton, row.deleteButton].filter { !$0.isHidden }
                    let visibleInput: NSView = timer.state == .idle ? (timer.inputKind == .targetTime ? row.targetInput : row.durationInput) : row.timeField
                    let input = visibleInput.convert(visibleInput.bounds, to: row)
                    allFit = allFit && row.bounds.contains(input) && buttons.allSatisfy { button in
                        let frame = button.convert(button.bounds, to: row)
                        return row.bounds.contains(frame) && !frame.intersects(input)
                    } && (row.statusLabel.isHidden || row.bounds.contains(row.statusLabel.frame)) &&
                        row.layer?.cornerRadius == CardGeometry.innerRadius(height: row.bounds.height)
                    if timer.state == .idle { allFit = allFit && input.width >= 180 }
                }
                check(allFit, "\(appearance.rawValue) \(Int(size)) idle four digits, target, running, paused and error controls fit without overlapping")
            }
        }
        settings = ClockSettings()
        settings.transparency = 0
        panel.apply(settings)
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
        panel.face.quickAccessCorner = nil
        let full = bitmap()
        let card = panel.face.dialCard
        func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, left: Bool) -> Int {
            let sx = CGFloat(a.pixelsWide) / panel.face.bounds.width
            let sy = CGFloat(a.pixelsHigh) / panel.face.bounds.height
            let range = left ? card.minX..<(card.minX + card.width * 0.35) : (card.maxX - card.width * 0.35)..<card.maxX
            var count = 0
            for x in Int(range.lowerBound * sx)..<Int(range.upperBound * sx) {
                for y in Int((panel.face.bounds.height - card.minY - 40) * sy)..<Int((panel.face.bounds.height - card.minY) * sy) {
                    if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
                }
            }
            return count
        }
        for (corner, left) in [(ClockCorner.bottomLeft, true), (.bottomRight, false)] {
            panel.face.quickAccessCorner = corner
            let hidden = bitmap()
            check(differences(full, hidden, left: left) > 10 && differences(full, hidden, left: !left) == 0,
                  "\(corner.rawValue) hover hides only its own date text in actual rendered pixels")
        }
        panel.face.quickAccessCorner = nil
        let restored = bitmap()
        check(differences(full, restored, left: true) == 0 && differences(full, restored, left: false) == 0,
              "leaving a bottom entry restores both date readouts")
        var id = timers.add()!
        var row = panel.timerTray.rows[0]
        check([row.durationInput, row.targetInput].allSatisfy { input in
            input.minutes.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "min" }
        }, "duration and target-time minute fields both display min")
        for appearance in [ClockAppearance.light, .dark] {
            settings.appearance = appearance
            panel.apply(settings)
            let palette = ClockPalette(appearance, effectiveAppearance: panel.face.effectiveAppearance)
            panel.addTimerButton.isHidden = false
            let entry = bitmap()
            let entryFrame = panel.addTimerButton.frame
            let sx = CGFloat(entry.pixelsWide) / panel.face.bounds.width
            let sy = CGFloat(entry.pixelsHigh) / panel.face.bounds.height
            var symbolPixels = 0
            let center = entryFrame.insetBy(dx: entryFrame.width * 0.2, dy: entryFrame.height * 0.2)
            for x in Int(center.minX * sx)..<Int(center.maxX * sx) {
                for y in Int((panel.face.bounds.height - center.maxY) * sy)..<Int((panel.face.bounds.height - center.minY) * sy) {
                    if let color = entry.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       abs(color.redComponent - color.blueComponent) < 0.04,
                       (appearance == .dark ? color.redComponent < 0.3 : color.redComponent > 0.85) { symbolPixels += 1 }
                }
            }
            check(QuickAccessButton.timerSymbolName == "timer" && NSImage(systemSymbolName: QuickAccessButton.timerSymbolName, accessibilityDescription: nil) != nil && symbolPixels > 3,
                  "\(appearance.rawValue) add entry actually renders the contrasting timer symbol")
            check(sameColor(row.signButton.contentTintColor, palette.accent) && sameColor(row.primaryButton.contentTintColor, palette.accent) &&
                  palette.accent.colorSpace == .sRGB && palette.face.colorSpace == .sRGB,
                  "\(appearance.rawValue) countdown controls share the explicit sRGB terracotta palette")
            timers.editInput(id, text: "invalid")
            timers.primaryAction(id)
            check(sameColor(row.statusLabel.textColor, palette.error) && !sameColor(row.statusLabel.textColor, palette.warning),
                  "\(appearance.rawValue) invalid input remains semantic red, distinct from amber")
            timers.editInput(id, text: "1秒")
            scheduler.message = "通知未开启"
            let start = Date()
            timers.primaryAction(id, at: start)
            let notice = panel.timerTray.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("通知未就绪") }
            check(notice != nil && sameColor(notice?.textColor, palette.warning),
                  "\(appearance.rawValue) notification warning uses warm amber")
            timers.tick(at: start.addingTimeInterval(2))
            check(sameColor(row.timeField.textColor, palette.warning) && sameColor(row.signButton.contentTintColor, palette.warning) &&
                  sameColor(row.statusLabel.textColor, palette.warning) && !sameColor(row.timeField.textColor, palette.accent),
                  "\(appearance.rawValue) overtime uses warm amber rather than the ordinary accent")
            timers.remove(id)
            if appearance == .light {
                id = timers.add()!
                row = panel.timerTray.rows[0]
            }
        }
    }

    private static func checkSizeHoverAndOpacity(_ check: (Bool, String) -> Void) {
        let suite = "FloatingClock.appearance-regressions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let timers = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: CheckTimerNotifications())
        let panel = ClockPanel(settings: ClockSettings())
        panel.timerCoordinator = timers
        timers.onChange = { [weak panel] in panel?.refreshTimers() }
        var pointer = CGPoint(x: -100_000, y: -100_000)
        panel.mouseLocationProvider = { pointer }
        panel.showClock()
        defer { panel.hideClock() }
        let advanced = AdvancedSettingsWindowController(settings: ClockSettings())
        check(advanced.faceSizeRow.slider.minValue == 260 && advanced.faceSizeRow.slider.maxValue == 420,
              "size slider ranges from the timer-aligned minimum of 260 to the maximum of 420")
        var settings = ClockSettings()
        for size in [140.0, 224, 260, 300, 420] {
            settings.faceSize = size
            panel.apply(settings)
            let width = panel.frame.width
            let id = timers.add()!
            check(panel.frame.width == width && panel.clockScreenFrame.width == width && panel.face.dialCard.width >= 260,
                  "requested size \(Int(size)) retains an aligned width when a timer is added")
            timers.remove(id)
            check(panel.frame.width == width && panel.frame.height == width,
                  "requested size \(Int(size)) retains the same width when the last timer is removed")
        }
        settings.faceSize = 260
        let id = timers.add()!
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
        for transparency in [0.0, 20, 45, 80, 90] {
            settings.transparency = transparency
            panel.apply(settings)
            panel.face.layoutSubtreeIfNeeded()
            let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds)!
            panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
            let card = panel.face.dialCard
            func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
                let px = Int(x * CGFloat(bitmap.pixelsWide) / panel.face.bounds.width)
                let py = Int((panel.face.bounds.height - y) * CGFloat(bitmap.pixelsHigh) / panel.face.bounds.height)
                return bitmap.colorAt(x: px, y: py)?.alphaComponent ?? -1
            }
            // cacheDisplay captures backing pixels before the WindowServer
            // applies window opacity. Include that final composition exactly once.
            let background = alpha(x: card.midX - 60, y: card.midY) * panel.alphaValue
            let hub = alpha(x: card.midX, y: card.midY) * panel.alphaValue
            check(abs(background - settings.backgroundAlpha) < 0.02 && abs(hub - settings.contentAlpha) < 0.02,
                  "\(Int(transparency)) percent transparency renders separate background and foreground opacity in actual pixels")
            check(panel.alphaValue == settings.contentAlpha && panel.timerTray.alphaValue == 1 &&
                  panel.timerHint.alphaValue == 1 && panel.addTimerButton.alphaValue == 1,
                  "\(Int(transparency)) percent transparency applies the compensated opacity once to timer controls, hint and entry")
        }
        let input = panel.timerTray.rows[0].durationInput.minutes.field
        panel.makeKey()
        panel.makeFirstResponder(input)
        check(input.currentEditor()?.isDescendant(of: panel.timerTray) == true,
              "active timer text and caret inherit the same compensated window opacity as the tray")
        panel.makeFirstResponder(nil)
        settings.isLocked = true
        settings.showsSeconds = false
        panel.apply(settings)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(panel.ignoresMouseEvents && !panel.quickAccessPanel.isEntryVisible && panel.face.quickAccessCorner == nil,
              "locked clock keeps its entry hidden and date restored outside its hover bounds")
        pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(panel.quickAccessPanel.isEntryVisible && panel.addTimerButton.isHidden && panel.quickAccessPanel.alphaValue == settings.contentAlpha,
              "locked entry appears on hover with compensated opacity even when the second hand is off")
        let plus = panel.quickAccessPanel.frame
        check(NSWindow.windowNumber(at: CGPoint(x: plus.midX, y: plus.midY), belowWindowWithWindowNumber: 0) == panel.quickAccessPanel.windowNumber,
              "fresh locked hover entry receives WindowServer clicks after the pointer enters")
        pointer = panel.convertPoint(toScreen: CGPoint(x: panel.timerTray.frame.midX, y: panel.timerTray.frame.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(panel.quickAccessPanel.isEntryVisible && panel.ignoresMouseEvents,
              "hovering the attached timer also keeps the locked entry visible without blocking underlying clicks")
        pointer = CGPoint(x: -100_000, y: -100_000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(!panel.quickAccessPanel.isEntryVisible && panel.face.quickAccessCorner == nil,
              "locked entry disappears promptly after leaving the entire clock")
        panel.hideClock()
        pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(!panel.quickAccessPanel.isEntryVisible, "hidden clock never reveals a locked entry from stale hover polling")
        panel.showClock()
        check(panel.quickAccessPanel.isEntryVisible, "showing the locked clock refreshes its hover location immediately")
        settings.isLocked = false
        panel.apply(settings)
        check(!panel.addTimerButton.isHidden && !panel.quickAccessPanel.isEntryVisible,
              "unlocking under the pointer swaps the white entry for the timer entry immediately")
        timers.remove(id)
    }

    private static func checkTimerDragging(_ check: (Bool, String) -> Void) {
        let suite = "FloatingClock.drag-regressions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let timers = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: CheckTimerNotifications())
        let panel = ClockPanel(settings: ClockSettings())
        panel.timerCoordinator = timers
        timers.onChange = { [weak panel] in panel?.refreshTimers() }
        panel.showClock()
        defer { panel.hideClock() }
        guard let screen = panel.screen?.visibleFrame else { check(false, "drag checks have a display"); return }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func screenPoint(in view: NSView, _ point: CGPoint) -> CGPoint {
            panel.convertPoint(toScreen: view.convert(point, to: nil))
        }
        var savedOrigins: [CGPoint] = []
        panel.onPositionChanged = { savedOrigins.append($0) }
        for count in [1, 3] {
            while timers.timers.count < count { _ = timers.add() }
            let start = panel.clockScreenFrame
            let gripOffset = CGPoint(x: start.width * 0.35, y: start.height * 0.7)
            let grip = CGPoint(x: start.minX + gripOffset.x, y: start.minY + gripOffset.y)
            panel.sendEvent(event(.leftMouseDown, at: grip))
            let savesBefore = savedOrigins.count
            var followsPointer = true
            var directionMatches = true
            var entryMatches = true
            var footerStaysAtBottom = true
            // Visit every quadrant, then cross the midline repeatedly without
            // releasing the mouse. Every assertion precedes mouseUp.
            for (dx, dy) in [(-1.0, 80.0), (1, 80), (-1, -80), (1, -80), (1, 1), (1, -1), (1, 1)] {
                let desired = CGRect(x: screen.midX + dx * 150 - start.width / 2,
                                     y: screen.midY + dy - start.height / 2, width: start.width, height: start.height)
                let pointer = CGPoint(x: desired.minX + gripOffset.x, y: desired.minY + gripOffset.y)
                panel.sendEvent(event(.leftMouseDragged, at: pointer))
                let actual = panel.clockScreenFrame
                followsPointer = followsPointer && abs(actual.minX - desired.minX) < 0.01 && abs(actual.minY - desired.minY) < 0.01
                let corner = QuickAccessLayout.corner(for: desired, on: screen)
                directionMatches = directionMatches && (panel.timerTray.frame.midY > panel.face.dialCard.midY) == corner.isBottom
                panel.face.onHoverChanged?(true)
                entryMatches = entryMatches && panel.face.quickAccessCorner == corner &&
                    panel.addTimerButton.frame == QuickAccessLayout.buttonFrame(in: panel.face.dialCard, corner: corner)
                footerStaysAtBottom = footerStaysAtBottom && (count != 1 ||
                    (panel.timerHint.frame.maxY < panel.timerTray.frame.minY && panel.timerHint.frame.maxY < panel.face.dialCard.minY))
            }
            check(followsPointer, "\(count) timers keep the dial under the same mouse grip throughout direction changes")
            check(directionMatches && entryMatches, "\(count) timers and the add entry change sides immediately during one continuous drag")
            check(footerStaysAtBottom, "\(count) timers keep the single-timer hint at the bottom while dragging")
            check(savedOrigins.count == savesBefore, "\(count) timers defer saving position until mouse release")
            let finalDial = panel.clockScreenFrame
            panel.sendEvent(event(.leftMouseUp, at: CGPoint(x: finalDial.minX + gripOffset.x, y: finalDial.minY + gripOffset.y)))
            check(savedOrigins.count == savesBefore + 1 && savedOrigins.last == panel.clockScreenFrame.origin &&
                  panel.clockScreenFrame == finalDial && screen.contains(panel.frame),
                  "\(count) timers constrain and save the final position on mouse release")

            panel.face.layoutSubtreeIfNeeded()
            let row = panel.timerTray.rows[0]
            let points = [screenPoint(in: row, CGPoint(x: row.bounds.midX, y: 2)),
                          screenPoint(in: panel.timerTray, CGPoint(x: 1, y: panel.timerTray.bounds.midY))] +
                (count == 1 ? [screenPoint(in: panel.timerHint, CGPoint(x: panel.timerHint.bounds.midX, y: panel.timerHint.bounds.midY))] : [])
            let before = panel.frame
            let saves = savedOrigins.count
            for point in points {
                let local = panel.face.convert(panel.convertPoint(fromScreen: point), from: nil)
                let hit = panel.face.hitTest(local) ?? panel.face
                hit.mouseDown(with: event(.leftMouseDown, at: point))
                hit.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: point.x + 80, y: point.y + 80)))
                hit.mouseUp(with: event(.leftMouseUp, at: point))
            }
            check(panel.frame == before && savedOrigins.count == saves && !panel.face.mouseDownCanMoveWindow,
                  "\(count) timers ignore drags on row backgrounds, tray gaps and the footer")
        }
        var locked = ClockSettings()
        locked.isLocked = true
        let lockedPointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.mouseLocationProvider = { lockedPointer }
        panel.apply(locked)
        panel.face.onHoverChanged?(true)
        let before = panel.frame
        let dial = panel.clockScreenFrame
        let point = CGPoint(x: dial.midX, y: dial.midY)
        panel.face.mouseDown(with: event(.leftMouseDown, at: point))
        panel.face.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: point.x + 80, y: point.y - 80)))
        panel.face.mouseUp(with: event(.leftMouseUp, at: point))
        check(panel.frame == before && panel.quickAccessPanel.isEntryVisible && panel.ignoresMouseEvents,
              "locked clock ignores dial drags and retains its clickable quick entry")
    }

    private static func checkTimerInputRegressions(_ check: (Bool, String) -> Void) {
        let suite = "FloatingClock.input-regressions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClockTimerStore(defaults: defaults)
        let scheduler = CheckTimerNotifications()
        let panel = ClockPanel(settings: ClockSettings())
        panel.showClock()
        defer { panel.hideClock() }

        func attach(_ timers: TimerCoordinator) {
            panel.timerCoordinator = timers
            timers.onChange = { [weak panel] in panel?.refreshTimers() }
            panel.makeKey()
        }
        func type(_ text: String, into field: NSTextField) {
            panel.makeFirstResponder(field)
            field.selectText(nil)
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertText(text, replacementRange: editor.selectedRange())
            }
        }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            panel.face.layoutSubtreeIfNeeded()
        }
        func step(_ input: TimerNumberInput, by direction: Int) -> Bool {
            // NSStepper changes its own value before dispatching the target action.
            // Derive the next value from the control, so stale editing state fails.
            input.stepper.integerValue += direction
            return input.stepper.sendAction(input.stepper.action, to: input.stepper.target)
        }

        let timers = TimerCoordinator(store: store, notifications: scheduler)
        attach(timers)
        let id = timers.add()!
        let row = panel.timerTray.rows[0]
        for kind in [ClockTimerInput.duration, .targetTime] {
            for editsHours in [false, true] {
                for direction in [-1, 1] {
                    panel.makeFirstResponder(nil)
                    timers.setInputKind(id, kind: kind)
                    timers.editInput(id, text: kind == .duration ? "5" : "18:35")
                    settle()
                    let input = kind == .duration ? row.durationInput : row.targetInput
                    let number = editsHours ? input.hours : input.minutes
                    let typed = editsHours ? 9 : 40
                    type(String(typed), into: number.field)
                    let adjusted = step(number, by: direction)
                    settle()
                    let expected = typed + direction
                    let expectedInput = editsHours ? String(format: "%02d:35", expected) : String(format: "18:%02d", expected)
                    let correctModel = kind == .targetTime ? timers.timers[0].input == expectedInput :
                        (try? TimerInputParser.duration(timers.timers[0].input)) == Double(editsHours ? expected * 3600 + 300 : expected * 60)
                    check(adjusted && correctModel && number.value == expected && number.stepper.integerValue == expected && timers.timers[0].state == .idle,
                          "\(kind) \(editsHours ? "hour" : "minute") arrow \(direction) uses the active typed value and leaves the timer idle")
                }
            }
        }
        timers.setInputKind(id, kind: .duration)
        timers.editInput(id, text: "5")
        type("10", into: row.durationInput.minutes.field)
        let firstStep = step(row.durationInput.minutes, by: 1)
        let secondStep = step(row.durationInput.minutes, by: 1)
        settle()
        check(firstStep && secondStep && (try? TimerInputParser.duration(timers.timers[0].input)) == 720,
              "typing ten minutes then pressing up twice advances to twelve minutes")
        timers.editInput(id, text: "1分钟30秒")
        type("90", into: row.durationInput.minutes.field)
        let normalizedStep = step(row.durationInput.minutes, by: 1)
        settle()
        check(normalizedStep && (try? TimerInputParser.duration(timers.timers[0].input)) == 5490 &&
              row.durationInput.hours.value == 1 && row.durationInput.minutes.value == 31,
              "stepping ninety typed minutes normalizes once and preserves legacy seconds")
        timers.remove(id)

        for text in ["999999", "999998分钟30.5秒"] {
            var saved = ClockTimer()
            saved.input = text
            store.save([saved])
            let restored = TimerCoordinator(store: store, notifications: scheduler)
            attach(restored)
            let legacy = panel.timerTray.rows[0]
            let seconds = try! TimerInputParser.duration(text)
            check(!legacy.statusLabel.isHidden && legacy.statusLabel.stringValue.contains("99999"),
                  "legacy duration \(text) visibly identifies the preserved original value")
            panel.makeFirstResponder(legacy.durationInput.minutes.field)
            panel.makeFirstResponder(nil)
            settle()
            check((try? TimerInputParser.duration(restored.timers[0].input)) == seconds,
                  "focusing and leaving an oversized legacy duration preserves its full value")
            legacy.primaryButton.performClick(nil)
            check(restored.timers[0].state == .running && restored.timers[0].duration == seconds &&
                  store.load().first?.duration == seconds && scheduler.scheduled.last?.duration == seconds,
                  "starting legacy duration \(text) preserves its full value in storage and notification scheduling")
            legacy.primaryButton.performClick(nil)
            legacy.resetButton.performClick(nil)
            legacy.primaryButton.performClick(nil)
            check(restored.timers[0].duration == seconds,
                  "resetting and restarting legacy duration \(text) does not truncate it")
            legacy.primaryButton.performClick(nil)
            legacy.resetButton.performClick(nil)
            type("1", into: legacy.durationInput.hours.field)
            legacy.primaryButton.performClick(nil)
            let replacement = 3600 + 9999 * 60 + seconds.truncatingRemainder(dividingBy: 60)
            check(restored.timers[0].duration == replacement,
                  "explicitly editing legacy duration \(text) replaces it with the new fields and retains its seconds")
            legacy.primaryButton.performClick(nil)
            legacy.resetButton.performClick(nil)
            restored.editInput(saved.id, text: text)
            restored.setInputKind(saved.id, kind: .targetTime)
            restored.setInputKind(saved.id, kind: .duration)
            legacy.primaryButton.performClick(nil)
            check(restored.timers[0].duration == 300,
                  "switching input modes clears the preserved legacy duration \(text)")
            restored.remove(saved.id)
        }
    }

    static func renderPreview(to path: String) throws {
        var settings = ClockSettings()
        settings.transparency = 0
        settings.faceSize = 336
        try renderFace(to: path, settings: settings)
    }

    static func renderTimerPreviews(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        for appearance in [ClockAppearance.light, .dark] {
            for size in [260.0, 300, 420] {
                for above in [false, true] {
                    let suite = "FloatingClock.preview.\(UUID())"
                    let defaults = UserDefaults(suiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let timers = TimerCoordinator(store: ClockTimerStore(defaults: defaults), notifications: CheckTimerNotifications())
                    var settings = ClockSettings()
                    settings.faceSize = size
                    settings.transparency = 0
                    settings.appearance = appearance
                    settings.timerDisplayFormat = .hoursMinutes
                    settings.origin = StoredPoint(x: screen.midX, y: above ? screen.minY + 16 : screen.maxY - size - 40)
                    let panel = ClockPanel(settings: settings)
                    panel.timerCoordinator = timers
                    timers.onChange = { [weak panel] in panel?.refreshTimers() }
                    let countdown = timers.add()!
                    timers.editInput(countdown, text: "90")
                    timers.primaryAction(countdown)
                    let elapsed = timers.add()!
                    timers.toggleMode(elapsed)
                    timers.primaryAction(elapsed, at: Date().addingTimeInterval(-1340))
                    let editable = timers.add()!
                    timers.editInput(editable, text: "90")
                    panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
                    panel.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                    panel.addTimerButton.isHidden = false
                    panel.face.quickAccessCorner = QuickAccessLayout.corner(for: panel.clockScreenFrame, on: screen)
                    panel.face.layoutSubtreeIfNeeded()
                    let view = panel.face
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                    let data = bitmap.representation(using: .png, properties: [:])!
                    let side = above ? "above" : "below"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("timers-\(appearance.rawValue)-\(Int(size))-\(side).png"))
                    timers.setInputKind(editable, kind: .targetTime)
                    timers.editInput(editable, text: "19:30")
                    panel.addTimerButton.isHidden = false
                    panel.face.layoutSubtreeIfNeeded()
                    let targetBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: targetBitmap) }
                    try targetBitmap.representation(using: .png, properties: [:])!.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("timers-target-\(appearance.rawValue)-\(Int(size))-\(side).png"))
                    if size == 260 {
                        panel.showClock()
                        panel.makeKey()
                        panel.makeFirstResponder(panel.timerTray.rows[2].targetInput.minutes.field)
                        panel.timerTray.rows[0].deleteButton.performClick(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        panel.addTimerButton.isHidden = false
                        panel.face.layoutSubtreeIfNeeded()
                        let reduced = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: reduced) }
                        try reduced.representation(using: .png, properties: [:])!.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent("timers-after-removal-\(appearance.rawValue)-\(side).png"))
                        for id in timers.timers.map(\.id) { timers.remove(id) }
                        for count in 1...3 {
                            let added = timers.add()!
                            if count == 2 {
                                timers.setInputKind(added, kind: .targetTime)
                                timers.editInput(added, text: "19:30")
                            }
                            panel.addTimerButton.isHidden = false
                            panel.face.layoutSubtreeIfNeeded()
                            let editors = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                            panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: editors) }
                            try editors.representation(using: .png, properties: [:])!.write(
                                to: URL(fileURLWithPath: directory).appendingPathComponent("timer-editors-\(appearance.rawValue)-\(count)-\(side).png"))
                            if count == 1 {
                                timers.editInput(added, text: "9999小时9999分钟")
                                panel.face.layoutSubtreeIfNeeded()
                                let full = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                                panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: full) }
                                try full.representation(using: .png, properties: [:])!.write(
                                    to: URL(fileURLWithPath: directory).appendingPathComponent("timer-four-digits-\(appearance.rawValue)-\(side).png"))
                                timers.editInput(added, text: "5")
                            }
                        }
                    }
                    panel.hideClock()
                }
            }
        }
    }

    /// Render the real settings controls without opening a window or changing preferences.
    static func renderDocumentationPreviews(to directory: String) throws {
        try renderStylePreviews(to: directory)
        try renderQuickPreviews(to: directory)
        try renderTimerPreviews(to: directory)
        for enabled in [true, false] {
            var settings = ClockSettings()
            settings.showsMinuteNumerals = enabled
            let controller = AdvancedSettingsWindowController(settings: settings)
            guard let window = controller.window, let content = window.contentView else {
                throw NSError(domain: "FloatingClock.documentation", code: 1)
            }
            window.appearance = NSAppearance(named: .aqua)
            let view = content.superview ?? content
            view.layoutSubtreeIfNeeded()
            if !enabled, let document = controller.settingsScrollView.documentView {
                let scroll = controller.settingsScrollView
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded()
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "FloatingClock.documentation", code: 2)
            }
            window.appearance?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "FloatingClock.documentation", code: 3)
            }
            let name = enabled ? "advanced-settings.png" : "advanced-settings-disabled.png"
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            controller.close()
        }
    }

    static func renderQuickPreviews(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for appearance in [ClockAppearance.light, .dark] {
            for corner in ClockCorner.allCases {
                var settings = ClockSettings()
                settings.transparency = 0
                settings.isLocked = true
                settings.showsMinuteNumerals = true
                settings.appearance = appearance
                let panel = ClockPanel(settings: settings)
                panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
                panel.face.quickAccessCorner = corner
                let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds)!
                panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
                let canvas = NSImage(size: panel.face.bounds.size)
                canvas.lockFocus()
                NSImage(cgImage: bitmap.cgImage!, size: panel.face.bounds.size).draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                let card = panel.face.bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
                let buttonFrame = QuickAccessLayout.buttonFrame(in: card, corner: corner)
                let button = panel.quickAccessPanel.button
                button.settings = settings
                button.faceScale = card.width / 224
                button.setFrameSize(buttonFrame.size)
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: buttonFrame.minX, yBy: buttonFrame.minY)
                shift.concat()
                button.draw(button.bounds)
                NSGraphicsContext.restoreGraphicsState()
                canvas.unlockFocus()
                let png = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                try png.write(to: URL(fileURLWithPath: "\(directory)/quick-\(appearance.rawValue)-\(corner.rawValue).png"))
            }
        }
    }

    static func renderStylePreviews(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for appearance in [ClockAppearance.light, .dark] {
            for size in [260, 300, 420] {
                for style in ClockStyle.allCases {
                    for enabled in [false, true] {
                        var settings = ClockSettings()
                        settings.transparency = 0
                        settings.faceSize = Double(size)
                        settings.appearance = appearance
                        settings.style = style
                        settings.showsMinuteNumerals = enabled
                        let layer = enabled ? "minutes" : "plain"
                        try renderFace(to: "\(directory)/\(style.rawValue)-\(layer)-\(appearance.rawValue)-\(size).png", settings: settings)
                    }
                }
            }
            try renderOverview(to: "\(directory)/styles-\(appearance.rawValue).png", appearance: appearance)
            for minute in [0, 11, 58] {
                var settings = ClockSettings()
                settings.transparency = 0
                settings.style = .cardinalNumbers
                settings.showsMinuteNumerals = true
                settings.appearance = appearance
                try renderFace(to: "\(directory)/minute-layer-\(appearance.rawValue)-minute\(minute).png", settings: settings, minute: minute)
            }
            for opacity in [15, 80] {
                var settings = ClockSettings()
                settings.transparency = 0
                settings.showsMinuteNumerals = true
                settings.minuteNumeralOpacity = Double(opacity)
                settings.appearance = appearance
                try renderFace(to: "\(directory)/minute-layer-\(appearance.rawValue)-opacity\(opacity).png", settings: settings)
            }
            for minute in [0, 11, 58] {
                var settings = ClockSettings()
                settings.transparency = 0
                settings.showsMinuteNumerals = true
                settings.minuteNumeralOpacity = 100
                settings.appearance = appearance
                try renderFace(to: "\(directory)/halo-\(appearance.rawValue)-minute\(minute).png", settings: settings, minute: minute)
            }
        }
    }

    private static func renderFace(to path: String, settings: ClockSettings, minute: Int = 15) throws {
        let bitmap = try faceBitmap(settings: settings, minute: minute)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FloatingClock.preview", code: 2)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func faceBitmap(settings: ClockSettings, minute: Int = 15) throws -> NSBitmapImageRep {
        let panel = ClockPanel(settings: settings)
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:\(String(format: "%02d", minute)):36+08:00")
        guard let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds) else {
            throw NSError(domain: "FloatingClock.preview", code: 1)
        }
        panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
        return bitmap
    }

    private static func renderOverview(to path: String, appearance: ClockAppearance) throws {
        let faces = try ClockStyle.allCases.map { style -> (String, NSImage) in
            var settings = ClockSettings()
            settings.transparency = 0
            settings.style = style
            settings.showsMinuteNumerals = true
            settings.appearance = appearance
            let bitmap = try faceBitmap(settings: settings)
            guard let cgImage = bitmap.cgImage else { throw NSError(domain: "FloatingClock.preview", code: 4) }
            let title = style == .minimal ? "样式一 + 分钟大字" : "样式二 + 分钟大字"
            return (title, NSImage(cgImage: cgImage, size: NSSize(width: 248, height: 248)))
        }
        let canvas = NSImage(size: NSSize(width: 568, height: 304))
        canvas.lockFocus()
        let dark = appearance == .dark
        (dark ? NSColor(calibratedWhite: 0.075, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
        CGRect(x: 0, y: 0, width: 568, height: 304).fill()
        for (index, entry) in faces.enumerated() {
            let (title, faceImage) = entry
            let x = CGFloat(index) * 272 + 24
            faceImage.draw(in: CGRect(x: x, y: 36, width: 248, height: 248))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray
            ]
            let titleSize = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: x + 124 - titleSize.width / 2, y: 12), withAttributes: attributes)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FloatingClock.preview", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
