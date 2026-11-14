import AppKit
import ClockCore

final class QuickAccessButton: NSButton {
    var settings = ClockSettings() { didSet { needsDisplay = true } }
    var faceScale: CGFloat = 1 { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { performClick(nil) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = settings.appearance == .dark ||
            (settings.appearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let ink = dark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.17, alpha: 1)
        let face = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedRed: 0.975, green: 0.967, blue: 0.945, alpha: 1)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5 * faceScale, yRadius: 5 * faceScale)
        face.setFill(); shape.fill()
        ink.withAlphaComponent(isHighlighted ? 0.16 : 0.05).setFill(); shape.fill()
        ink.withAlphaComponent(0.16).setStroke(); shape.lineWidth = 0.7; shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * faceScale, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.8)
        ]
        let size = "+".size(withAttributes: attributes)
        "+".draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Only this small window receives clicks while the clock window passes them through.
final class QuickAccessPanel: NSPanel {
    let button = QuickAccessButton(title: "+", target: nil, action: nil)
    var onOpen: ((NSView) -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 20, height: 20),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "时钟快捷入口"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        button.isBordered = false
        button.target = self
        button.action = #selector(openMenu)
        button.toolTip = "时钟快捷设置"
        button.setAccessibilityLabel("时钟快捷设置")
        button.autoresizingMask = [.width, .height]
        contentView = button
    }

    @objc private func openMenu() { onOpen?(button) }
}
