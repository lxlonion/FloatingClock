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
            check(submenu.items.count == 2, "dial menu contains only styles one and two")
            for (index, style) in ClockStyle.allCases.enumerated() {
                submenu.performActionForItem(at: index)
                check(panel.face.settings.style == style && store.load().style == style &&
                      submenu.items[index].state == .on && submenu.items.filter { $0.state == .on }.count == 1,
                      "\(style.rawValue) menu updates face, saved selection, and checkmark")
            }
        } else { check(false, "style menu exists") }
        check(MinuteNumerals.font.familyName == "Comic Sans MS", "minute numerals use Comic Sans MS")
        let opacityItem = controller.menu.items.first {
            $0.submenu?.items.contains(where: { $0.view === controller.minuteOpacityView }) == true
        }
        check(opacityItem?.isHidden == true && !panel.face.settings.showsMinuteNumerals,
              "minute opacity control is hidden while layer is off")
        if let toggle = controller.menu.items.firstIndex(where: { $0.title == "显示分钟大字" }) {
            controller.menu.performActionForItem(at: toggle)
            check(opacityItem?.isHidden == false && panel.face.settings.showsMinuteNumerals,
                  "enabling minute layer reveals its opacity control")
            let windowAlpha = panel.alphaValue
            let minuteSlider = controller.minuteOpacityView.slider
            minuteSlider.doubleValue = 67
            _ = minuteSlider.sendAction(minuteSlider.action, to: minuteSlider.target)
            check(abs(panel.face.settings.minuteNumeralAlpha - 0.67) < 0.001,
                  "minute concentration slider updates the rendered layer")
            check(panel.alphaValue == windowAlpha, "minute concentration leaves window transparency unchanged")
            check(store.load().showsMinuteNumerals && store.load().minuteNumeralOpacity == 67,
                  "minute layer and concentration persist together")
            controller.menu.performActionForItem(at: toggle)
            check(opacityItem?.isHidden == true && !panel.face.settings.showsMinuteNumerals &&
                  controller.settings.minuteNumeralOpacity == 67,
                  "disabling layer hides its control and retains chosen concentration")
            controller.menu.performActionForItem(at: toggle)
            if let submenu = controller.menu.items.first(where: { $0.title == "表盘样式" })?.submenu {
                for (index, style) in ClockStyle.allCases.enumerated() {
                    submenu.performActionForItem(at: index)
                    check(panel.face.settings.style == style && panel.face.settings.showsMinuteNumerals &&
                          panel.face.settings.minuteNumeralOpacity == 67,
                          "\(style.rawValue) retains independent minute layer and concentration")
                }
            }
        } else { check(false, "minute layer toggle exists") }
        if let index = controller.menu.items.firstIndex(where: { $0.title == "显示日期" }) {
            controller.menu.performActionForItem(at: index)
            check(!panel.face.settings.showsDate && panel.face.settings.showsMinuteNumerals,
                  "minute layer remains visible when corner dates are hidden")
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
