import AppKit
import ClockCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SettingsStore
    private var settings: ClockSettings
    let panel: ClockPanel
    let menuController: MenuController
    private var advancedSettingsController: AdvancedSettingsWindowController?
    private var timerCoordinator: TimerCoordinator?

    init(store: SettingsStore = SettingsStore(), includeStatusItem: Bool = true) {
        self.store = store
        let settings = store.load()
        self.settings = settings
        panel = ClockPanel(settings: settings)
        menuController = MenuController(settings: settings, includeStatusItem: includeStatusItem)
        super.init()

        menuController.onSettingsChanged = { [weak self] in self?.applySettings($0) }
        menuController.onShowAdvancedSettings = { [weak self] in self?.advancedSettings().showSettings() }
        menuController.onMoveToCurrentScreen = { [weak self] in self?.panel.moveToCurrentScreen() }
        menuController.onQuit = { NSApp.terminate(nil) }
        panel.face.onContextMenu = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.menuController.quickMenu, with: event, for: self.panel.face)
        }
        panel.onQuickMenuRequested = { [weak self] button in
            self?.menuController.quickMenu.popUp(positioning: nil,
                                               at: CGPoint(x: button.bounds.midX, y: button.bounds.maxY + 4), in: button)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareClock(timerCoordinator: TimerCoordinator(notifications: TimerNotifications()))
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreFloatingWindow), name: name, object: nil)
        }
        panel.showClock()
    }

    func prepareClock(timerCoordinator: TimerCoordinator) {
        self.timerCoordinator = timerCoordinator
        panel.timerCoordinator = timerCoordinator
        timerCoordinator.onChange = { [weak self] in self?.panel.refreshTimers() }
        timerCoordinator.restore()
        panel.restorePosition(settings.origin)
        panel.onPositionChanged = { [weak self] in self?.savePosition($0) }
        savePosition(panel.clockScreenFrame.origin)
    }

    private func applySettings(_ value: ClockSettings) {
        var updated = value.normalized()
        updated.origin = settings.origin
        let changed = settings != updated
        if changed {
            settings = updated
            store.save(settings)
        }
        menuController.settings = settings
        advancedSettingsController?.settings = settings
        if changed { panel.apply(settings) }
    }

    private func savePosition(_ origin: CGPoint) {
        let position = StoredPoint(x: origin.x, y: origin.y)
        guard settings.origin != position else { return }
        settings.origin = position
        store.save(settings)
    }

    func advancedSettings() -> AdvancedSettingsWindowController {
        if let advancedSettingsController { return advancedSettingsController }
        let controller = AdvancedSettingsWindowController(settings: settings)
        controller.onSettingsChanged = { [weak self] in self?.applySettings($0) }
        controller.onMoveToCurrentScreen = menuController.onMoveToCurrentScreen
        advancedSettingsController = controller
        return controller
    }

    @objc private func displayConfigurationChanged() {
        panel.constrainPosition()
        restoreFloatingWindow()
    }

    @objc private func restoreFloatingWindow() {
        timerCoordinator?.tick()
        if panel.isVisible { panel.showClock() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.showClock()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard timerCoordinator?.prepareForTermination({ sender.reply(toApplicationShouldTerminate: true) }) == true else {
            return .terminateNow
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.constrainPosition()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--smoke-test") {
    exit(RuntimeChecks.run())
}
if let index = CommandLine.arguments.firstIndex(of: "--live-display-test"), CommandLine.arguments.count > index + 1 {
    LiveDisplayChecks.run(to: CommandLine.arguments[index + 1])
}
if let index = CommandLine.arguments.firstIndex(of: "--render-timer-previews"), CommandLine.arguments.count > index + 1 {
    do {
        try RuntimeChecks.renderTimerPreviews(to: CommandLine.arguments[index + 1])
        exit(0)
    } catch {
        fputs("Timer previews failed: \(error)\n", stderr)
        exit(1)
    }
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
