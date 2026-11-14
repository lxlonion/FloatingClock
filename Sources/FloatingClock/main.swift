import AppKit
import ClockCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var panel: ClockPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = ClockPanel(settings: store.load())
        panel.onPositionChanged = { [weak self] origin in
            guard let self else { return }
            var settings = self.store.load()
            settings.origin = StoredPoint(x: origin.x, y: origin.y)
            self.store.save(settings)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "漂浮时钟")
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出漂浮时钟", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        panel.showClock()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
