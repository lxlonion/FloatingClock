import AppKit
import ClockCore

final class ClockPanel: NSPanel, NSWindowDelegate {
    let face = ClockFaceView()
    let quickAccessPanel = QuickAccessPanel()
    private var ticker: Timer?
    private var settings: ClockSettings
    var onPositionChanged: ((CGPoint) -> Void)?
    var onQuickMenuRequested: ((NSView) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(settings: ClockSettings) {
        self.settings = settings
        let side = settings.faceSize + ClockLayout.padding * 2
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let origin = settings.origin.map { CGPoint(x: $0.x, y: $0.y) } ??
            ClockLayout.defaultOrigin(size: side, screen: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let clamped = ClockLayout.clampedOrigin(origin, size: side, screens: visibleFrames)
        super.init(contentRect: CGRect(origin: clamped, size: CGSize(width: side, height: side)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "漂浮时钟"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // Above ordinary app windows and floating panels, while system menus remain usable.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        contentView = face
        face.autoresizingMask = [.width, .height]
        face.setAccessibilityElement(true)
        face.setAccessibilityRole(.image)
        face.setAccessibilityLabel("漂浮指针时钟；从菜单栏调整设置")
        face.onDragFinished = { [weak self] in self?.constrainAndSavePosition() }
        delegate = self
        quickAccessPanel.onOpen = { [weak self] view in self?.onQuickMenuRequested?(view) }
        apply(settings)
    }

    func apply(_ value: ClockSettings) {
        settings = value.normalized()
        let side = settings.faceSize + ClockLayout.padding * 2
        if abs(frame.width - side) > 0.1 {
            let origin = CGPoint(x: frame.midX - side / 2, y: frame.midY - side / 2)
            let clamped = ClockLayout.clampedOrigin(origin, size: side, screens: NSScreen.screens.map(\.visibleFrame))
            setFrame(CGRect(origin: clamped, size: CGSize(width: side, height: side)), display: true)
        }
        alphaValue = settings.alpha
        ignoresMouseEvents = settings.isLocked
        face.settings = settings
        updateQuickAccess()
        if isVisible { startTicker() }
    }

    func showClock() {
        orderFrontRegardless()
        updateQuickAccess()
        startTicker()
    }

    func hideClock() {
        hideQuickAccess()
        orderOut(nil)
        ticker?.invalidate()
        ticker = nil
    }

    func moveToCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        setFrameOrigin(ClockLayout.defaultOrigin(size: frame.width, screen: screen.visibleFrame))
        constrainAndSavePosition()
        showClock()
    }

    func constrainAndSavePosition() {
        let origin = ClockLayout.clampedOrigin(frame.origin, size: frame.width, screens: NSScreen.screens.map(\.visibleFrame))
        if frame.origin != origin { setFrameOrigin(origin) }
        onPositionChanged?(origin)
        updateQuickAccess()
    }

    func windowDidMove(_ notification: Notification) { updateQuickAccess() }
    func windowDidResize(_ notification: Notification) { updateQuickAccess() }

    private func updateQuickAccess() {
        guard settings.isLocked, isVisible,
              let screenFrame = (screen ?? NSScreen.main)?.visibleFrame else {
            hideQuickAccess()
            return
        }
        let corner = QuickAccessLayout.corner(for: frame, on: screenFrame)
        face.quickAccessCorner = corner
        let card = face.bounds.insetBy(dx: ClockLayout.padding, dy: ClockLayout.padding)
        let buttonFrame = QuickAccessLayout.buttonFrame(in: card, corner: corner)
        quickAccessPanel.button.settings = settings
        quickAccessPanel.button.faceScale = card.width / 224
        quickAccessPanel.level = level
        quickAccessPanel.collectionBehavior = collectionBehavior
        quickAccessPanel.alphaValue = max(0.7, settings.alpha)
        quickAccessPanel.setFrame(convertToScreen(buttonFrame), display: true)
        if quickAccessPanel.parent !== self { addChildWindow(quickAccessPanel, ordered: .above) }
        quickAccessPanel.orderFrontRegardless()
    }

    private func hideQuickAccess() {
        face.quickAccessCorner = nil
        if quickAccessPanel.parent === self { removeChildWindow(quickAccessPanel) }
        quickAccessPanel.orderOut(nil)
    }

    private func startTicker() {
        ticker?.invalidate()
        face.needsDisplay = true
        let timer = Timer(timeInterval: settings.showsSeconds ? 1 / 30 : 1, repeats: true) { [weak self] _ in
            self?.face.needsDisplay = true
        }
        timer.tolerance = settings.showsSeconds ? 0.008 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    deinit { ticker?.invalidate() }
}
