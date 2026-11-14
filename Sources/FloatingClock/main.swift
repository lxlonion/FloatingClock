import AppKit
import ClockCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var settings = ClockSettings()
    private var panel: ClockPanel!
    private var menuController: MenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = store.load()
        panel = ClockPanel(settings: settings)
        menuController = MenuController(settings: settings)
        panel.onPositionChanged = { [weak self] origin in
            guard let self else { return }
            self.settings.origin = StoredPoint(x: origin.x, y: origin.y)
            self.store.save(self.settings)
            self.menuController.settings = self.settings
        }
        menuController.onSettingsChanged = { [weak self] updated in
            guard let self else { return }
            self.settings = updated
            self.panel.apply(updated)
            self.panel.constrainAndSavePosition()
        }
        menuController.onToggleVisibility = { [weak self] in
            guard let self else { return }
            if self.panel.isVisible { self.panel.hideClock() } else { self.panel.showClock() }
            self.menuController.clockIsVisible = self.panel.isVisible
        }
        menuController.onMoveToCurrentScreen = { [weak self] in
            self?.panel.moveToCurrentScreen()
            self?.menuController.clockIsVisible = true
        }
        menuController.onQuit = { NSApp.terminate(nil) }
        panel.face.onContextMenu = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.menuController.menu, with: event, for: self.panel.face)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restoreFloatingWindow), name: name, object: nil)
        }
        panel.constrainAndSavePosition()
        panel.showClock()
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
        menuController?.clockIsVisible = true
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
let delegate = AppDelegate()
application.delegate = delegate
application.run()
