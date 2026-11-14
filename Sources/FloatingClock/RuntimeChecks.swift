import AppKit
import ClockCore

enum RuntimeChecks {
    /// Exercises the real AppKit menu targets and panel without touching user preferences.
    static func run() -> Int32 {
        let suite = "FloatingClock.smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let panel = ClockPanel(settings: ClockSettings())
        let controller = MenuController(settings: ClockSettings(), includeStatusItem: false)
        var checks: [String] = []
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
            checks.append(name)
        }
        controller.onSettingsChanged = { value in
            panel.apply(value)
            store.save(value)
        }
        check(panel.level.rawValue == NSWindow.Level.popUpMenu.rawValue - 1, "above app windows, below system menus")
        check(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]), "all Spaces and fullscreen flags")
        check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate, "does not steal keyboard focus")

        let slider = controller.transparencyView.slider
        slider.doubleValue = 54
        _ = slider.sendAction(slider.action, to: slider.target)
        check(abs(panel.alphaValue - 0.46) < 0.001, "live slider changes actual window alpha")

        if let index = controller.menu.items.firstIndex(where: { $0.title == "锁定位置（鼠标穿透）" }) {
            controller.menu.performActionForItem(at: index)
            check(panel.ignoresMouseEvents && controller.settings.isLocked, "locking enables mouse pass-through")
            check(store.load().isLocked && store.load().transparency == 54, "menu changes persist to preferences")
            controller.menu.performActionForItem(at: index)
            check(!panel.ignoresMouseEvents, "menu remains able to unlock")
        } else { check(false, "lock menu exists") }

        if let submenu = controller.menu.items.first(where: { $0.title == "时钟大小" })?.submenu,
           let index = submenu.items.firstIndex(where: { $0.tag == 284 }) {
            submenu.performActionForItem(at: index)
            check(abs(panel.frame.width - 308) < 0.001, "size menu resizes panel")
            check(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }, "resized panel remains on screen")
        } else { check(false, "size menu exists") }

        if let index = controller.menu.items.firstIndex(where: { $0.title == "显示秒针" }) {
            controller.menu.performActionForItem(at: index)
            check(!panel.face.settings.showsSeconds, "seconds menu reaches rendered face")
        }
        panel.showClock()
        check(panel.isVisible, "clock can be shown")
        panel.hideClock()
        check(!panel.isVisible, "clock can be hidden")
        let result: [String: Any] = ["passed": failures.isEmpty, "count": checks.count, "checks": checks, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }

    static func renderPreview(to path: String) throws {
        var settings = ClockSettings()
        settings.transparency = 0
        settings.faceSize = 336
        let panel = ClockPanel(settings: settings)
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:08:36+08:00")
        guard let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds) else {
            throw NSError(domain: "FloatingClock.preview", code: 1)
        }
        panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FloatingClock.preview", code: 2)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
