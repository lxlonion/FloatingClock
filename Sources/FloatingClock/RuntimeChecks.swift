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
        if let submenu = controller.menu.items.first(where: { $0.title == "表盘样式" })?.submenu {
            for (index, style) in ClockStyle.allCases.enumerated() {
                submenu.performActionForItem(at: index)
                check(panel.face.settings.style == style && store.load().style == style &&
                      submenu.items[index].state == .on && submenu.items.filter { $0.state == .on }.count == 1,
                      "\(style.rawValue) menu updates face, saved selection, and checkmark")
            }
        } else { check(false, "style menu exists") }
        if let index = controller.menu.items.firstIndex(where: { $0.title == "显示日期" }) {
            controller.menu.performActionForItem(at: index)
            check(!panel.face.settings.showsDate && panel.face.settings.style == .minuteReadout,
                  "minute style stays selected when corner dates are hidden")
        } else { check(false, "date menu exists") }
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
        try renderFace(to: path, settings: settings)
    }

    static func renderStylePreviews(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for appearance in [ClockAppearance.light, .dark] {
            for size in [164, 224, 284] {
                for style in ClockStyle.allCases {
                    var settings = ClockSettings()
                    settings.transparency = 0
                    settings.faceSize = Double(size)
                    settings.appearance = appearance
                    settings.style = style
                    try renderFace(to: "\(directory)/\(style.rawValue)-\(appearance.rawValue)-\(size).png", settings: settings)
                }
            }
            try renderOverview(to: "\(directory)/styles-\(appearance.rawValue).png", appearance: appearance)
        }
    }

    private static func renderFace(to path: String, settings: ClockSettings) throws {
        let bitmap = try faceBitmap(settings: settings)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FloatingClock.preview", code: 2)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func faceBitmap(settings: ClockSettings) throws -> NSBitmapImageRep {
        let panel = ClockPanel(settings: settings)
        panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T10:15:36+08:00")
        guard let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: panel.face.bounds) else {
            throw NSError(domain: "FloatingClock.preview", code: 1)
        }
        panel.face.cacheDisplay(in: panel.face.bounds, to: bitmap)
        return bitmap
    }

    private static func renderOverview(to path: String, appearance: ClockAppearance) throws {
        let faces = try ClockStyle.allCases.map { style -> (ClockStyle, NSImage) in
            var settings = ClockSettings()
            settings.transparency = 0
            settings.style = style
            settings.appearance = appearance
            let bitmap = try faceBitmap(settings: settings)
            guard let cgImage = bitmap.cgImage else { throw NSError(domain: "FloatingClock.preview", code: 4) }
            return (style, NSImage(cgImage: cgImage, size: NSSize(width: 248, height: 248)))
        }
        let canvas = NSImage(size: NSSize(width: 840, height: 304))
        canvas.lockFocus()
        let dark = appearance == .dark
        (dark ? NSColor(calibratedWhite: 0.075, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
        CGRect(x: 0, y: 0, width: 840, height: 304).fill()
        for (index, entry) in faces.enumerated() {
            let (style, faceImage) = entry
            let x = CGFloat(index) * 272 + 24
            faceImage.draw(in: CGRect(x: x, y: 36, width: 248, height: 248))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray
            ]
            let titleSize = style.menuTitle.size(withAttributes: attributes)
            style.menuTitle.draw(at: CGPoint(x: x + 124 - titleSize.width / 2, y: 12), withAttributes: attributes)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FloatingClock.preview", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
