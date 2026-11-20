import AppKit
import ClockCore

struct ClockPalette {
    let dark: Bool

    init(_ appearance: ClockAppearance, effectiveAppearance: NSAppearance) {
        dark = appearance == .dark ||
            (appearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var face: NSColor { dark ? color(0.12, 0.12, 0.12) : color(0.975, 0.967, 0.945) }
    var ink: NSColor { dark ? color(0.94, 0.94, 0.94) : color(0.17, 0.17, 0.17) }
    var accent: NSColor { dark ? color(1, 0.53, 0.35) : color(0.79, 0.31, 0.18) }
    var onAccent: NSColor { dark ? color(0.12, 0.12, 0.12) : color(1, 1, 1) }
    var warning: NSColor { dark ? color(1, 0.73, 0.34) : color(0.61, 0.36, 0.08) }
    var error: NSColor { .systemRed }
    var inputBackground: NSColor { NSColor.white.withAlphaComponent(dark ? 0.055 : 0.7) }
    var timerRowBackground: NSColor { ink.withAlphaComponent(dark ? 0.085 : 0.035) }
}
