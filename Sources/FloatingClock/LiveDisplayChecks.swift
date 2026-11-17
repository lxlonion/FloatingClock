import AppKit
import ClockCore

/// End-to-end checks of the WindowServer's live window, before any view cache.
/// Run in a separate process with --live-display-test <evidence-directory>.
enum LiveDisplayChecks {
    static func run(to directory: String) -> Never {
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        catch { fputs("Cannot create live-display evidence directory: \(error)\n", stderr); exit(1) }
        guard let screen = NSScreen.main else { fputs("No screen for live-display test\n", stderr); exit(1) }
        let app = NSApplication.shared
        var settings = ClockSettings()
        settings.transparency = 0
        settings.showsSeconds = true
        let panel = ClockPanel(settings: settings)
        panel.mouseLocationProvider = { CGPoint(x: -100_000, y: -100_000) }
        // Stages below control hover explicitly; physical cursor events must
        // not overwrite the simulated date occlusion between captures.
        panel.face.onHoverChanged = { _ in }
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10, minute: 15, second: 36))!
        let six = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 6))!
        panel.face.fixedDate = date
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.midY - panel.frame.height / 2))
        panel.showClock()
        var images: [String: NSBitmapImageRep] = [:]
        var checks: [[String: Any]] = []
        var buildsAfterOffscreen = 0
        var buildsAfterLive = 0
        func check(_ condition: Bool, _ name: String, _ detail: String = "") {
            checks.append(["name": name, "passed": condition, "detail": detail])
        }
        func capture(_ name: String) {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                       [.boundsIgnoreFraming, .bestResolution]) else {
                check(false, "capture \(name)", "WindowServer did not provide an image")
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            images[name] = bitmap
            do {
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            } catch { check(false, "write \(name)", String(describing: error)) }
        }
        func color(_ image: NSBitmapImageRep?, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
            guard let image else { return nil }
            let px = Int(x * CGFloat(image.pixelsWide) / panel.face.bounds.width)
            let py = Int((panel.face.bounds.height - y) * CGFloat(image.pixelsHigh) / panel.face.bounds.height)
            guard px >= 0, py >= 0, px < image.pixelsWide, py < image.pixelsHigh else { return nil }
            return image.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        }
        func brightness(_ image: NSBitmapImageRep?, _ point: CGPoint) -> CGFloat {
            guard let c = color(image, point.x, point.y) else { return -1 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        func differences(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?, in rect: CGRect) -> Int {
            guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 0 }
            let scale = CGFloat(a.pixelsWide) / panel.face.bounds.width
            let minX = max(0, Int(rect.minX * scale)), maxX = min(a.pixelsWide, Int(rect.maxX * scale))
            let minY = max(0, Int((panel.face.bounds.height - rect.maxY) * scale))
            let maxY = min(a.pixelsHigh, Int((panel.face.bounds.height - rect.minY) * scale))
            guard minX < maxX, minY < maxY else { return 0 }
            var count = 0
            for y in minY..<maxY {
                for x in minX..<maxX {
                    guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if max(abs(ca.redComponent - cb.redComponent), abs(ca.greenComponent - cb.greenComponent),
                           abs(ca.blueComponent - cb.blueComponent)) > 0.08 { count += 1 }
                }
            }
            return count
        }
        func warmOnePixelPerPointCache() {
            // A real Retina window can have an identity CTM and a 2x default
            // device transform. This bitmap also has an identity CTM, but 1x
            // device density. Match the color space to isolate the density key.
            let bounds = panel.face.bounds
            let space = panel.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            panel.face.drawDial(bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        func maximumComponentDifference(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
            guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
                  a.samplesPerPixel == b.samplesPerPixel, a.bitsPerSample == 8, b.bitsPerSample == 8,
                  let ap = a.bitmapData, let bp = b.bitmapData else { return 255 }
            var maximum = 0
            for y in 0..<a.pixelsHigh {
                for x in 0..<(a.pixelsWide * a.samplesPerPixel) {
                    maximum = max(maximum, abs(Int(ap[y * a.bytesPerRow + x]) - Int(bp[y * b.bytesPerRow + x])))
                }
            }
            return maximum
        }
        let card = panel.face.dialCard
        let scale = card.width / 224
        let handPoint = CGPoint(x: card.midX + 50 * scale, y: card.midY - 3.1 * scale)
        let dayRect = CGRect(x: card.minX + 15 * scale, y: card.minY + 12 * scale,
                             width: 45 * scale, height: 25 * scale)
        let dialRect = card.insetBy(dx: 30 * scale, dy: 30 * scale)
        let stages: [(TimeInterval, () -> Void)] = [
            (0.5, { capture("00-light"); settings.appearance = .dark; panel.apply(settings) }),
            (0.5, {
                capture("01-dark")
                let light = brightness(images["00-light"], handPoint), dark = brightness(images["01-dark"], handPoint)
                check(light >= 0 && light < 0.4 && dark > 0.7, "explicit appearance redraws the live hand", "light=\(light), dark=\(dark)")
                panel.face.fixedDate = six
                panel.face.needsDisplay = true
            }),
            (1.5, {
                capture("02-time")
                let old = brightness(images["01-dark"], handPoint), new = brightness(images["02-time"], handPoint)
                check(old > 0.7 && new >= 0 && new < 0.4, "time change redraws live hands before any cache", "old=\(old), new=\(new)")
                panel.face.quickAccessCorner = .bottomLeft
            }),
            (0.5, {
                capture("03-hover")
                let changed = differences(images["02-time"], images["03-hover"], in: dayRect)
                check(changed > 10, "bottom hover removes the live date", "changed pixels=\(changed)")
                panel.face.quickAccessCorner = nil
            }),
            (0.5, {
                capture("04-restored")
                let changed = differences(images["02-time"], images["04-restored"], in: dayRect)
                check(images["02-time"] != nil && images["04-restored"] != nil && changed == 0,
                      "leaving bottom hover restores the live date", "changed pixels=\(changed)")
                panel.face.fixedDate = date
                settings.showsMinuteNumerals = true
                settings.minuteNumeralOpacity = 60
                panel.apply(settings)
            }),
            (0.5, {
                capture("05-numerals-low")
                let changed = differences(images["01-dark"], images["05-numerals-low"], in: dialRect)
                check(changed > 300, "enabling minute numerals changes the live window", "changed pixels=\(changed)")
                settings.minuteNumeralOpacity = 100
                panel.apply(settings)
            }),
            (0.5, {
                capture("06-numerals-halo")
                let changed = differences(images["05-numerals-low"], images["06-numerals-halo"], in: dialRect)
                // At 10:15 the hour hand crosses the 1. A narrow strip just
                // outside its stroke changes from numeral ink to face color.
                let angle = ClockAngles(date: date).hour
                var haloPixels = 0
                for distance in stride(from: 20.0, through: 52.0, by: 0.5) {
                    for offset in stride(from: 3.3, through: 4.3, by: 0.25) {
                        for side in [-1.0, 1.0] {
                            let x = card.midX + (sin(angle) * distance + cos(angle) * offset * side) * scale
                            let y = card.midY + (cos(angle) * distance - sin(angle) * offset * side) * scale
                            let low = brightness(images["05-numerals-low"], CGPoint(x: x, y: y))
                            let high = brightness(images["06-numerals-halo"], CGPoint(x: x, y: y))
                            if low > 0.3 && high >= 0 && high < 0.25 { haloPixels += 1 }
                        }
                    }
                }
                check(changed > 300 && haloPixels > 0, "high-concentration halo is visible around a live hand",
                      "changed pixels=\(changed), halo samples=\(haloPixels)")
                settings.showsMinuteNumerals = false
                settings.appearance = .system
                panel.appearance = NSAppearance(named: .aqua)
                panel.apply(settings)
            }),
            (0.5, {
                capture("07-system-light")
                panel.appearance = NSAppearance(named: .darkAqua)
            }),
            (0.5, {
                capture("08-system-dark")
                let light = brightness(images["07-system-light"], handPoint), dark = brightness(images["08-system-dark"], handPoint)
                check(light >= 0 && light < 0.4 && dark > 0.7, "system appearance redraws the live hand", "light=\(light), dark=\(dark)")
                panel.face.fixedDate = nil
            }),
            (0.5, { capture("09-ticker-before") }),
            (1.5, {
                capture("10-ticker-after")
                let changed = differences(images["09-ticker-before"], images["10-ticker-after"], in: dialRect)
                check(changed > 10, "ticker updates the live second hand", "changed pixels=\(changed)")
                settings.showsSeconds = false
                settings.selectedClockSlot = .second
                panel.face.fixedDate = ISO8601DateFormatter().date(from: "2026-07-15T04:20:00Z")!
                panel.apply(settings)
            }),
            (0.5, {
                capture("10a-pacific-standard")
                settings.selectedClockSlot = .third
                panel.apply(settings)
            }),
            (0.5, {
                capture("10b-new-york-dst")
                let hands = differences(images["10a-pacific-standard"], images["10b-new-york-dst"], in: dialRect)
                let day = differences(images["10a-pacific-standard"], images["10b-new-york-dst"], in: dayRect)
                check(hands > 50 && day > 10, "slot switching redraws live hands and cross-midnight date before any cache",
                      "hand pixels=\(hands), date pixels=\(day)")
                settings.thirdClockTimeZone.usesDaylightSavingTime = false
                panel.apply(settings)
            }),
            (0.5, {
                capture("10c-new-york-standard")
                let hands = differences(images["10b-new-york-dst"], images["10c-new-york-standard"], in: dialRect)
                let day = differences(images["10b-new-york-dst"], images["10c-new-york-standard"], in: dayRect)
                check(hands > 50 && day > 10, "DST checkbox redraws live hands and date before any cache",
                      "hand pixels=\(hands), date pixels=\(day)")
                settings.showsMinuteNumerals = true
                settings.thirdClockTimeZone.identifier = "Asia/Kathmandu"
                panel.apply(settings)
            }),
            (0.5, {
                capture("10d-kathmandu")
                settings.thirdClockTimeZone.identifier = "Asia/Shanghai"
                panel.apply(settings)
            }),
            (0.5, {
                capture("10e-shanghai")
                let changed = differences(images["10d-kathmandu"], images["10e-shanghai"], in: dialRect)
                check(changed > 300, "fractional time zone switching refreshes live minute numerals before any cache", "changed pixels=\(changed)")
                settings.selectedClockSlot = .system
                settings.showsMinuteNumerals = false
                settings.transparency = 90
                panel.face.fixedDate = six
                panel.apply(settings)
            }),
            (0.5, {
                capture("11-before-cache")
                let rect = panel.face.bounds
                let bitmap = panel.face.bitmapImageRepForCachingDisplay(in: rect)!
                panel.face.cacheDisplay(in: rect, to: bitmap)
                let point = CGPoint(x: card.midX - 60, y: card.midY)
                let alpha = color(bitmap, point.x, point.y)?.alphaComponent ?? -1
                check(abs(alpha - 0.5) <= 1.5 / 255, "transparent snapshot groups the live shadow and fill once", "relative alpha=\(alpha)")
            }),
            (0.5, {
                capture("12-after-cache")
                let changed = differences(images["11-before-cache"], images["12-after-cache"], in: panel.face.bounds)
                check(images["11-before-cache"] != nil && images["12-after-cache"] != nil && changed == 0,
                      "snapshot leaves the actual window unchanged", "changed pixels=\(changed)")
                settings.style = .cardinalNumbers
                settings.showsMinuteNumerals = true
                settings.minuteNumeralOpacity = 100
                settings.transparency = 0
                panel.face.fixedDate = date
                panel.apply(settings)
                warmOnePixelPerPointCache()
                buildsAfterOffscreen = panel.face.staticDialRenderCount
            }),
            (0.5, {
                capture("13-live-after-1x")
                let builds = panel.face.staticDialRenderCount
                let expected = buildsAfterOffscreen + (panel.backingScaleFactor == 1 ? 0 : 1)
                check(builds == expected, "real backing density selects a new cache after a 1x identity-CTM bitmap",
                      "scale=\(panel.backingScaleFactor), builds=\(buildsAfterOffscreen)->\(builds), expected=\(expected)")
                panel.face.viewDidChangeBackingProperties()
            }),
            (0.5, {
                capture("14-fresh-live-reference")
                let difference = maximumComponentDifference(images["13-live-after-1x"], images["14-fresh-live-reference"])
                check(difference <= 1, "returning from a 1x bitmap stays as sharp as a fresh live cache",
                      "maximum component difference=\(difference)/255")
                let builds = panel.face.staticDialRenderCount
                warmOnePixelPerPointCache()
                let expected = builds + (panel.backingScaleFactor == 1 ? 0 : 1)
                check(panel.face.staticDialRenderCount == expected, "a 1x bitmap does not reuse the real window's different device density",
                      "builds=\(builds)->\(panel.face.staticDialRenderCount), expected=\(expected)")
                buildsAfterOffscreen = panel.face.staticDialRenderCount
                warmOnePixelPerPointCache()
                check(panel.face.staticDialRenderCount == buildsAfterOffscreen, "repeated identical 1x bitmap targets reuse their static cache")
                panel.face.invalidateDial()
            }),
            (0.5, {
                capture("15-live-after-second-1x")
                let difference = maximumComponentDifference(images["14-fresh-live-reference"], images["15-live-after-second-1x"])
                check(difference <= 1, "a second offscreen/live round trip preserves sharp static pixels",
                      "maximum component difference=\(difference)/255")
                let expected = buildsAfterOffscreen + (panel.backingScaleFactor == 1 ? 0 : 1)
                check(panel.face.staticDialRenderCount == expected, "the second return to the live window rebuilds only for its actual density",
                      "builds=\(buildsAfterOffscreen)->\(panel.face.staticDialRenderCount), expected=\(expected)")
                buildsAfterLive = panel.face.staticDialRenderCount
            }),
            (0.5, {
                panel.face.invalidateDial()
                panel.displayIfNeeded()
                check(panel.face.staticDialRenderCount == buildsAfterLive, "unchanged real-window redraws reuse the density-correct cache")
            })
        ]
        func finish() -> Never {
            panel.hideClock()
            let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
            let result: [String: Any] = ["passed": passed, "checks": checks, "liveChecksBeforeFirstCache": true,
                                         "backingScale": panel.backingScaleFactor]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-display.json"))
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("Cannot write live-display results: \(error)\n", stderr); exit(1) }
            exit(passed ? 0 : 1)
        }
        func schedule(_ index: Int) {
            guard index < stages.count else { finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + stages[index].0) {
                stages[index].1()
                schedule(index + 1)
            }
        }
        schedule(0)
        app.run()
        finish()
    }
}
