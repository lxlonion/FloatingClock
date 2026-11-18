import AppKit

final class TransparencyDisclosureButton: NSButton {
    private let label = NSTextField(labelWithString: "分层透明度")
    private let indicator = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    var isExpanded = false { didSet { updateIndicator() } }

    init(horizontalInset: CGFloat = 0) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label.stringValue)
        label.font = .systemFont(ofSize: 12)
        indicator.contentTintColor = .secondaryLabelColor

        for view in [label, indicator] {
            view.setAccessibilityElement(false)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: indicator.leadingAnchor, constant: -8),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 12),
            indicator.heightAnchor.constraint(equalToConstant: 12)
        ])
        updateIndicator()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 29) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || isHovered {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    private func updateIndicator() {
        let symbolName = isExpanded ? "chevron.up" : "chevron.down"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        indicator.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        setAccessibilityExpanded(isExpanded)
    }
}
