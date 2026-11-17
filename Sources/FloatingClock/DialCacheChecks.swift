import AppKit
import ClockCore

enum DialCacheChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let face = ClockFaceView(frame: CGRect(x: 0, y: 0, width: 284, height: 284))
        var settings = ClockSettings()
        settings.selectedClockSlot = .third
        settings.thirdClockTimeZone.identifier = "Etc/UTC"
        settings.showsMinuteNumerals = true
        settings.minuteNumeralOpacity = 80
        let date = ISO8601DateFormatter().date(from: "2026-07-14T10:15:10Z")!
        face.settings = settings
        face.fixedDate = date

        func render(scale: CGFloat = 1, rect: CGRect? = nil, cached: Bool = true,
                    space: CFString = CGColorSpace.sRGB, flipped: Bool = false,
                    clip: CGRect? = nil) -> NSBitmapImageRep {
            let rect = rect ?? face.bounds
            let context = CGContext(data: nil, width: Int(ceil(rect.width * scale)), height: Int(ceil(rect.height * scale)),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: space)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: scale, y: scale)
            if flipped {
                context.translateBy(x: 0, y: rect.height)
                context.scaleBy(x: 1, y: -1)
            }
            context.translateBy(x: -rect.minX, y: -rect.minY)
            if let clip { context.clip(to: clip) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
            face.drawDial(rect, usesStaticCache: cached)
            NSGraphicsContext.restoreGraphicsState()
            return NSBitmapImageRep(cgImage: context.makeImage()!)
        }
        func maximumDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
                  a.samplesPerPixel == b.samplesPerPixel, let ap = a.bitmapData, let bp = b.bitmapData else { return 255 }
            var maximum = 0
            for y in 0..<a.pixelsHigh {
                for x in 0..<(a.pixelsWide * a.samplesPerPixel) {
                    maximum = max(maximum, abs(Int(ap[y * a.bytesPerRow + x]) - Int(bp[y * b.bytesPerRow + x])))
                }
            }
            return maximum
        }
        func expectRebuild(_ name: String, _ change: () -> Void) {
            let count = face.staticDialRenderCount
            change()
            let image = render()
            check(face.staticDialRenderCount == count + 1 && maximumDifference(image, render(cached: false)) <= 1,
                  "static dial cache refreshes \(name) and matches uncached pixels")
        }
        func expectReuse(_ name: String, _ change: () -> Void) {
            let count = face.staticDialRenderCount
            change()
            let image = render()
            check(face.staticDialRenderCount == count && maximumDifference(image, render(cached: false)) <= 1,
                  "static dial cache reuses \(name) without stale pixels")
        }

        let first = render()
        let count = face.staticDialRenderCount
        var last = first
        for frame in 1...30 {
            face.fixedDate = date.addingTimeInterval(Double(frame) / 30)
            face.invalidateDial()
            last = render()
        }
        check(count == 1 && face.staticDialRenderCount == count && maximumDifference(first, last) > 10,
              "30 moving-second-hand frames build the static dial only once")
        expectRebuild("minute rollover") { face.fixedDate = date.addingTimeInterval(50) }
        expectRebuild("style") { settings.style = .cardinalNumbers; face.settings = settings }
        expectRebuild("explicit appearance") { settings.appearance = .dark; face.settings = settings }
        expectRebuild("minute size") { settings.minuteNumeralSize = 65; face.settings = settings }
        expectRebuild("minute opacity and live halo") { settings.minuteNumeralOpacity = 100; face.settings = settings }
        expectRebuild("bottom-left date occlusion") { face.quickAccessCorner = .bottomLeft }
        expectRebuild("bottom-right weekday occlusion") { face.quickAccessCorner = .bottomRight }
        expectRebuild("date restoration") { face.quickAccessCorner = nil }
        expectReuse("top-corner hover") { face.quickAccessCorner = .topRight }
        expectReuse("hand, window, timer and inactive-slot settings") {
            settings.showsSeconds = false
            settings.transparency = 90
            settings.isLocked = true
            settings.timerDisplayFormat = .hoursMinutes
            settings.secondClockTimeZone.identifier = "Asia/Shanghai"
            settings.origin = StoredPoint(x: -100, y: 42)
            face.settings = settings
        }
        expectRebuild("fractional-offset time zone") {
            settings.thirdClockTimeZone.identifier = "Asia/Kathmandu"
            face.settings = settings
        }
        expectRebuild("slot and local midnight") {
            face.fixedDate = ISO8601DateFormatter().date(from: "2026-07-15T04:20:00Z")!
            settings.selectedClockSlot = .second
            settings.secondClockTimeZone = .pacific
            face.settings = settings
        }
        expectRebuild("New York DST date") { settings.selectedClockSlot = .third; settings.thirdClockTimeZone = .newYork; face.settings = settings }
        expectRebuild("disabled DST date") { settings.thirdClockTimeZone.usesDaylightSavingTime = false; face.settings = settings }
        expectRebuild("minute layer disabled") { settings.showsMinuteNumerals = false; face.settings = settings }
        expectReuse("minute changes with minute numerals hidden") { face.fixedDate = face.fixedDate!.addingTimeInterval(60) }
        expectRebuild("midnight with only the date visible") { face.fixedDate = face.fixedDate!.addingTimeInterval(3600) }
        expectRebuild("date disabled") { settings.showsDate = false; face.settings = settings }
        expectReuse("hidden date and minute settings") {
            face.fixedDate = face.fixedDate!.addingTimeInterval(86_400)
            settings.minuteNumeralSize = 80
            settings.minuteNumeralOpacity = 20
            face.settings = settings
        }
        settings.appearance = .system
        face.appearance = NSAppearance(named: .aqua)
        face.settings = settings
        _ = render()
        expectRebuild("inherited system appearance") { face.appearance = NSAppearance(named: .darkAqua) }
        settings.appearance = .light
        face.settings = settings
        _ = render()
        expectReuse("system changes under a fixed appearance") { face.appearance = NSAppearance(named: .aqua) }
        expectRebuild("a backing-property notification") { face.viewDidChangeBackingProperties() }
        expectRebuild("dial movement when the timer tray changes direction") {
            face.frame.size.height += 120
            face.dialFrame = CGRect(x: 0, y: 120, width: 284, height: 284)
        }

        // Exercise actual raster density, pixel phase and target color space,
        // not just key equality. Each comparison uses the original direct draw.
        for appearance in [ClockAppearance.light, .dark] {
            for size in [260.0, 300.5, 420] {
                face.frame.size = CGSize(width: size + 25, height: size + 25)
                face.dialFrame = CGRect(x: 0.25, y: 0.5, width: size + 24, height: size + 24)
                for style in ClockStyle.allCases {
                    for numerals in [false, true] {
                        settings.appearance = appearance
                        settings.style = style
                        settings.showsDate = true
                        settings.showsSeconds = true
                        settings.showsMinuteNumerals = numerals
                        settings.minuteNumeralOpacity = 100
                        face.settings = settings
                        for scale in [CGFloat(1), 2] {
                            for cropped in [false, true] {
                                let rect = cropped ? face.bounds.insetBy(dx: 6.25, dy: 7.5) : face.bounds
                                let cached = render(scale: scale, rect: rect)
                                let reference = render(scale: scale, rect: rect, cached: false)
                                let difference = maximumDifference(cached, reference)
                                check(difference <= 1,
                                      "\(appearance.rawValue) \(size) \(style.rawValue) minutes=\(numerals) \(scale)x cropped=\(cropped) cached/direct pixels differ by at most 1/255 (actual \(difference))")
                            }
                        }
                    }
                }
            }
        }
        _ = render()
        var builds = face.staticDialRenderCount
        let retina = render(scale: 2)
        check(face.staticDialRenderCount == builds + 1 && maximumDifference(retina, render(scale: 2, cached: false)) <= 1,
              "switching from 1x to 2x rebuilds a sharp static layer")
        builds = face.staticDialRenderCount
        let p3 = render(scale: 2, space: CGColorSpace.displayP3)
        check(face.staticDialRenderCount == builds + 1 && maximumDifference(p3, render(scale: 2, cached: false, space: CGColorSpace.displayP3)) <= 1,
              "changing destination color space rebuilds the static layer")
        builds = face.staticDialRenderCount
        _ = render(scale: 2, space: CGColorSpace.displayP3)
        check(face.staticDialRenderCount == builds, "an unchanged Retina and color-space destination reuses its layer")
        _ = render(rect: face.bounds.insetBy(dx: 6, dy: 6))
        builds = face.staticDialRenderCount
        let full = render()
        check(face.staticDialRenderCount == builds && maximumDifference(full, render(cached: false)) <= 1,
              "a cache built during a cropped repaint still contains the complete dial")

        for appearance in [ClockAppearance.light, .dark] {
            settings.appearance = appearance
            face.settings = settings
            for scale in [CGFloat(1), 2] {
                // Flipped targets retain the original AppKit drawing path;
                // returning to the live orientation must keep its cached layer.
                for flipped in [false, true, false] {
                    let previousBuilds = face.staticDialRenderCount
                    let image = render(scale: scale, flipped: flipped)
                    let reference = render(scale: scale, cached: false, flipped: flipped)
                    let difference = maximumDifference(image, reference)
                    check(difference <= 1,
                          "\(appearance.rawValue) \(scale)x flipped=\(flipped) cached/direct text differs by at most 1/255 (actual \(difference))")
                    builds = face.staticDialRenderCount
                    _ = render(scale: scale, flipped: flipped)
                    check(face.staticDialRenderCount == builds && (!flipped || builds == previousBuilds),
                          flipped ? "a flipped target preserves text without replacing the normal cache" : "an unchanged normal target reuses its static layer")
                }
            }
        }
        // Clip through actual ticks/numerals, not just the outer padding.
        face.viewDidChangeBackingProperties()
        _ = render(clip: CGRect(x: face.bounds.midX - 20, y: 0, width: 40, height: face.bounds.midY))
        builds = face.staticDialRenderCount
        let afterPartialRepaint = render()
        check(face.staticDialRenderCount == builds && maximumDifference(afterPartialRepaint, render(cached: false)) <= 1,
              "a dirty region clipped through the dial still builds a complete reusable cache")
    }
}
