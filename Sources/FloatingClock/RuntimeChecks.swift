import AppKit
import ClockCore

private final class CheckTimerNotifications: TimerNotificationScheduling {
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
        advanced.onQuit = { quitRequests += 1 }
        check(panel.level.rawValue == NSWindow.Level.popUpMenu.rawValue - 1, "above app windows, below system menus")
        check(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]), "all Spaces and fullscreen flags")
        check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate, "does not steal keyboard focus")

        let slider = controller.transparencyView.slider
        slider.doubleValue = 54
        _ = slider.sendAction(slider.action, to: slider.target)
        check(abs(panel.alphaValue - 0.46) < 0.001, "live slider changes actual window alpha")
        check(advanced.transparencyRow.slider.doubleValue == 54,
              "menu transparency changes synchronize to the open settings window")

        if let index = controller.menu.items.firstIndex(where: { $0.title == "锁定位置（鼠标穿透）" }) {
            controller.menu.performActionForItem(at: index)
            check(panel.ignoresMouseEvents && controller.settings.isLocked, "locking enables mouse pass-through")
            check(advanced.lockButton.state == .on, "menu lock changes synchronize to advanced settings")
            check(store.load().isLocked && store.load().transparency == 54, "menu changes persist to preferences")
            controller.menu.performActionForItem(at: index)
            check(!panel.ignoresMouseEvents, "menu remains able to unlock")
        } else { check(false, "lock menu exists") }

        check(controller.menu.items.allSatisfy { $0.submenu == nil }, "compact menu has no secondary submenus")
        check(controller.menu.items.filter { $0.action != nil }.count == 5,
              "compact menu retains only lock, visibility, advanced settings, screen recovery, and quit")
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

        let advancedTransparency = advanced.transparencyRow.slider
        advancedTransparency.doubleValue = 31
        _ = advancedTransparency.sendAction(advancedTransparency.action, to: advancedTransparency.target)
        check(abs(panel.alphaValue - 0.69) < 0.001 && store.load().transparency == 31 &&
              controller.transparencyView.slider.doubleValue == 31,
              "advanced transparency updates the clock, saved value, and menu slider together")
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
        advanced.quitButton.performClick(nil)
        check(quitRequests == 1, "advanced settings exposes the app quit action")

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
        controller.quickMenu.performActionForItem(at: 0)
        panel.face.onHoverChanged?(false)
        check(panel.ignoresMouseEvents && panel.quickAccessPanel.isVisible &&
              !panel.quickAccessPanel.ignoresMouseEvents && controller.quickMenu.items[0].state == .on,
              "locked clock passes clicks through while its small plus remains interactive")
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
                panel.setFrameOrigin(CGPoint(x: x, y: y))
                let card = panel.face.bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
                let expected = panel.convertToScreen(QuickAccessLayout.buttonFrame(in: card, corner: corner))
                check(panel.face.quickAccessCorner == corner &&
                      abs(panel.quickAccessPanel.frame.minX - expected.minX) < 1 &&
                      abs(panel.quickAccessPanel.frame.minY - expected.minY) < 1,
                      "\(corner.rawValue) entry follows the clock and avoids the nearer horizontal edge")
            }
        }
        controller.quickMenu.performActionForItem(at: 0)
        check(!panel.ignoresMouseEvents && !panel.quickAccessPanel.isVisible && panel.face.quickAccessCorner == nil,
              "quick unlock restores dragging and removes the plus entry")
        check(controller.menu.items.first(where: { $0.title == "锁定位置（鼠标穿透）" })?.state == .off,
              "quick settings stay synchronized with the full menu")
        controller.quickMenu.performActionForItem(at: 0)
        panel.hideClock()
        check(!panel.isVisible, "clock can be hidden")
        check(!panel.quickAccessPanel.isVisible, "hiding the clock also hides its small entry")

        let scheduler = CheckTimerNotifications()
        let timerStore = ClockTimerStore(defaults: defaults)
        let timers = TimerCoordinator(store: timerStore, notifications: scheduler)
        let timerPanel = ClockPanel(settings: ClockSettings())
        timerPanel.timerCoordinator = timers
        timers.onChange = { [weak timerPanel] in timerPanel?.refreshTimers() }
        timerPanel.showClock()
        defer { timerPanel.hideClock() }
        timerPanel.face.onHoverChanged?(false)
        check(timerPanel.recordingButton.isHidden && !timerPanel.quickAccessPanel.isVisible,
              "unlocked idle clock hides both entries outside its hover area")
        timerPanel.face.onHoverChanged?(true)
        check(!timerPanel.recordingButton.isHidden && !timerPanel.quickAccessPanel.isVisible,
              "hovering unlocked clock shows only the red recording entry")
        timerPanel.recordingButton.performClick(nil)
        check(timers.timers.count == 1 && timerPanel.timerTray.rows.count == 1 && timerPanel.canBecomeKey,
              "red entry adds an editable timer and allows keyboard input")
        timerPanel.recordingButton.performClick(nil)
        timerPanel.recordingButton.performClick(nil)
        timerPanel.recordingButton.performClick(nil)
        check(timers.timers.count == 3 && timerPanel.timerTray.rows.count == 3,
              "red entry enforces a maximum of three timer groups")
        check(timers.timers.allSatisfy { $0.state == .idle } && scheduler.scheduled.isEmpty,
              "moving focus between new timer inputs does not start timers")
        check(timerPanel.frame.height > timerPanel.frame.width && NSScreen.screens.contains { $0.visibleFrame.contains(timerPanel.frame) },
              "three timers form a rectangular window kept inside the display")
        timerPanel.face.layoutSubtreeIfNeeded()
        check(timerPanel.timerTray.rows.allSatisfy { $0.bounds.contains($0.convert($0.deleteButton.bounds, from: $0.deleteButton)) },
              "timer row controls fit within the expanded card")
        let row = timerPanel.timerTray.rows[0]
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
        timerPanel.apply(locked)
        timerPanel.face.onHoverChanged?(true)
        check(timerPanel.ignoresMouseEvents && !timerPanel.canBecomeKey && timerPanel.recordingButton.isHidden && timerPanel.quickAccessPanel.isVisible,
              "locking expanded clock keeps only the plus entry and restores pass-through")
        check(timers.timers[0].state == .running && scheduler.scheduled.count == scheduledCount,
              "locking does not stop or duplicate timer notifications")
        locked.isLocked = false
        locked.timerDisplayFormat = .hoursMinutes
        timerPanel.apply(locked)
        timerPanel.face.onHoverChanged?(true)
        check(!timerPanel.recordingButton.isHidden && !timerPanel.quickAccessPanel.isVisible && row.timeField.stringValue.hasPrefix("1时"),
              "unlocking restores the hover recording entry and the hour-minute readout")
        row.primaryButton.performClick(nil)
        check(timers.timers[0].state == .paused && scheduler.cancelled.contains(row.id),
              "stop preserves remaining time and cancels its pending notification")
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
        countdown.timeField.stringValue = "1秒"
        countdown.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        scheduler.message = "通知未开启"
        let started = Date()
        timers.primaryAction(countdown.id, at: started)
        check(timers.notificationMessage == "通知未开启", "notification permission failure is surfaced in the timer card")
        timerPanel.hideClock()
        timers.tick(at: started.addingTimeInterval(2))
        check(timers.timers[0].state == .running && timers.timers[0].isOvertime && !timerPanel.isVisible && timerPanel.recordingButton.isHidden,
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
            for _ in 0..<3 { timerPanel.recordingButton.performClick(nil) }
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
            check(tray.rows.allSatisfy { tray.bounds.contains($0.frame) && $0.frame.height == 84 } &&
                  !tray.rows[0].frame.intersects(tray.rows[1].frame),
                  "deleting row \(deletedIndex + 1) keeps the two remaining row frames separate inside the tray")
            for id in timers.timers.map(\.id) { timers.remove(id) }
        }
        let result: [String: Any] = ["passed": failures.isEmpty, "count": checks.count, "checks": checks, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
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
            for size in [140.0, 224, 360] {
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
                    panel.recordingButton.isHidden = false
                    panel.face.quickAccessCorner = QuickAccessLayout.corner(for: panel.clockScreenFrame, on: screen)
                    panel.face.layoutSubtreeIfNeeded()
                    let view = panel.face
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                    let data = bitmap.representation(using: .png, properties: [:])!
                    let side = above ? "above" : "below"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("timers-\(appearance.rawValue)-\(Int(size))-\(side).png"))
                    if size == 224 {
                        panel.showClock()
                        panel.makeKey()
                        panel.makeFirstResponder(panel.timerTray.rows[2].durationInput.minutes.field)
                        panel.timerTray.rows[0].deleteButton.performClick(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        panel.recordingButton.isHidden = false
                        panel.face.layoutSubtreeIfNeeded()
                        let reduced = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: reduced) }
                        try reduced.representation(using: .png, properties: [:])!.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent("timers-after-removal-\(appearance.rawValue)-\(side).png"))
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
            for size in [164, 224, 284] {
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
