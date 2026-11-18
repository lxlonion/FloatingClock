import AppKit

final class TransparencyDisclosureButton: NSButton {
    var isExpanded = false { didSet { updateIndicator() } }

    init() {
        super.init(frame: .zero)
        title = "分层透明度"
        bezelStyle = .accessoryBarAction
        controlSize = .small
        font = .systemFont(ofSize: 12)
        imagePosition = .imageLeading
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel(title)
        updateIndicator()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateIndicator() {
        image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        setAccessibilityExpanded(isExpanded)
    }
}
