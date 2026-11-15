import AppKit
import ClockCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var settings = ClockSettings()
    private var panel: ClockPanel!
    private var menuController: MenuController!
    private var advancedSettingsController: AdvancedSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = store.load()
        panel = ClockPanel(settings: settings)
        menuController = MenuController(settings: settings)
        panel.onPositionChanged = { [weak self] origin in
            guard let self else { return }
            self.settings.origin = StoredPoint(x: origin.x, y: origin.y)
            self.store.save(self.settings)
            self.menuController.settings = self.settings
            self.advancedSettingsController?.settings = self.settings
        }
        menuController.onSettingsChanged = { [weak self] updated in
            guard let self else { return }
            self.applySettings(updated)
        }
        menuController.onShowAdvancedSettings = { [weak self] in self?.showAdvancedSettings() }
        menuController.onToggleVisibility = { [weak self] in self?.toggleClockVisibility() }
        menuController.onMoveToCurrentScreen = { [weak self] in self?.moveClockToCurrentScreen() }
        menuController.onQuit = { NSApp.terminate(nil) }
        panel.face.onContextMenu = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.menuController.quickMenu, with: event, for: self.panel.face)
        }
        panel.onQuickMenuRequested = { [weak self] button in
            self?.menuController.quickMenu.popUp(positioning: nil,
                                               at: CGPoint(x: button.bounds.midX, y: button.bounds.maxY + 4), in: button)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreFloatingWindow), name: name, object: nil)
        }
        panel.constrainAndSavePosition()
        panel.showClock()
        refreshVisibility()
    }

    private func applySettings(_ updated: ClockSettings) {
        settings = updated.normalized()
        panel.apply(settings)
        panel.constrainAndSavePosition()
    }

    private func showAdvancedSettings() {
        if advancedSettingsController == nil {
            let controller = AdvancedSettingsWindowController(settings: settings)
            controller.onSettingsChanged = { [weak self] updated in self?.applySettings(updated) }
            controller.onToggleVisibility = { [weak self] in self?.toggleClockVisibility() }
            controller.onMoveToCurrentScreen = { [weak self] in self?.moveClockToCurrentScreen() }
            controller.onQuit = { NSApp.terminate(nil) }
            advancedSettingsController = controller
        }
        advancedSettingsController?.settings = settings
        advancedSettingsController?.clockIsVisible = panel.isVisible
        advancedSettingsController?.showSettings()
    }

    private func toggleClockVisibility() {
        if panel.isVisible { panel.hideClock() } else { panel.showClock() }
        refreshVisibility()
    }

    private func moveClockToCurrentScreen() {
        panel.moveToCurrentScreen()
        refreshVisibility()
    }

    private func refreshVisibility() {
        menuController.clockIsVisible = panel.isVisible
        advancedSettingsController?.clockIsVisible = panel.isVisible
    }

    @objc private func displayConfigurationChanged() {
        panel.constrainAndSavePosition()
        restoreFloatingWindow()
    }

    @objc private func restoreFloatingWindow() {
        if panel.isVisible { panel.showClock() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.showClock()
        if panel != nil { refreshVisibility() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.constrainAndSavePosition()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--smoke-test") {
    exit(RuntimeChecks.run())
}
if let index = CommandLine.arguments.firstIndex(of: "--render-documentation-previews"), CommandLine.arguments.count > index + 1 {
    do {
        try RuntimeChecks.renderDocumentationPreviews(to: CommandLine.arguments[index + 1])
        exit(0)
    } catch {
        fputs("Documentation previews failed: \(error)\n", stderr)
        exit(1)
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--render-quick-previews"), CommandLine.arguments.count > index + 1 {
    do {
        try RuntimeChecks.renderQuickPreviews(to: CommandLine.arguments[index + 1])
        exit(0)
    } catch {
        fputs("Quick access previews failed: \(error)\n", stderr)
        exit(1)
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--render-style-previews"), CommandLine.arguments.count > index + 1 {
    do {
        try RuntimeChecks.renderStylePreviews(to: CommandLine.arguments[index + 1])
        exit(0)
    } catch {
        fputs("Style previews failed: \(error)\n", stderr)
        exit(1)
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    do {
        try RuntimeChecks.renderPreview(to: CommandLine.arguments[index + 1])
        exit(0)
    } catch {
        fputs("Preview failed: \(error)\n", stderr)
        exit(1)
    }
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
