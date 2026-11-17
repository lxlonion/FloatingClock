import AppKit
import ClockCore

final class QuickAccessButton: NSButton {
    static let timerSymbolName = "timer"
    var settings = ClockSettings() { didSet { needsDisplay = true } }
    var faceScale: CGFloat = 1 { didSet { needsDisplay = true } }
    var isTimerEntry = false { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { performClick(nil) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ClockPalette(settings.appearance, effectiveAppearance: effectiveAppearance)
        if isTimerEntry {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.7, dy: 0.7))
            palette.accent.withAlphaComponent(isHighlighted ? 0.72 : 1).setFill()
            circle.fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: bounds.width * 0.52, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [palette.onAccent]))
            if let image = NSImage(systemSymbolName: Self.timerSymbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = image.size
                image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            return
        }
        let ink = palette.ink
        let face = palette.face
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
    var isEntryVisible: Bool { isVisible && !button.isHidden }
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
