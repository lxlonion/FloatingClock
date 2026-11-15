import AppKit
import ClockCore

final class ClockPanel: NSPanel, NSWindowDelegate {
    let face = ClockFaceView()
    let quickAccessPanel = QuickAccessPanel()
    let recordingButton = QuickAccessButton(title: "", target: nil, action: nil)
    let timerTray = TimerTrayView(frame: .zero)
    var timerCoordinator: TimerCoordinator? {
        didSet { timerTray.coordinator = timerCoordinator; refreshTimers() }
    }
    private var ticker: Timer?
    private var settings: ClockSettings
    private var pointerInside = false
    private var layingOut = false
    private var trayHeight: CGFloat = 0
    var onPositionChanged: ((CGPoint) -> Void)?
    var onQuickMenuRequested: ((NSView) -> Void)?

    override var canBecomeKey: Bool { !settings.isLocked && !(timerCoordinator?.timers.isEmpty ?? true) }
    override var canBecomeMain: Bool { false }
    var clockScreenFrame: CGRect { convertToScreen(face.dialFrame ?? face.bounds) }

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
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        contentView = face
        face.autoresizingMask = [.width, .height]
        face.dialFrame = CGRect(x: 0, y: 0, width: side, height: side)
        face.setAccessibilityElement(true)
        face.setAccessibilityRole(.group)
        face.setAccessibilityLabel("漂浮指针时钟；右键打开快捷设置，解锁后移入显示计时入口")
        face.onDragFinished = { [weak self] in self?.constrainAndSavePosition() }
        face.onHoverChanged = { [weak self] inside in
            self?.pointerInside = inside
            self?.updateQuickAccess()
        }
        recordingButton.isRecordingEntry = true
        recordingButton.isBordered = false
        recordingButton.target = self
        recordingButton.action = #selector(addTimer)
        recordingButton.toolTip = "添加倒计时 / 累计计时（最多三组）"
        recordingButton.setAccessibilityLabel("添加计时，最多三组")
        face.addSubview(timerTray)
        face.addSubview(recordingButton)
        timerTray.isHidden = true
        delegate = self
        quickAccessPanel.onOpen = { [weak self] view in self?.onQuickMenuRequested?(view) }
        apply(settings)
    }

    func apply(_ value: ClockSettings) {
        let previousDial = clockScreenFrame
        settings = value.normalized()
        let side = settings.faceSize + ClockLayout.padding * 2
        let origin = CGPoint(x: previousDial.midX - side / 2, y: previousDial.midY - side / 2)
        let clamped = ClockLayout.clampedOrigin(origin, size: side, screens: NSScreen.screens.map(\.visibleFrame))
        alphaValue = settings.alpha
        ignoresMouseEvents = settings.isLocked
        if settings.isLocked { makeFirstResponder(nil); resignKey() }
        face.settings = settings
        timerTray.appearance = settings.appearance == .system ? nil : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
        timerTray.refresh(settings: settings)
        layoutPanel(anchoredAt: CGRect(origin: clamped, size: CGSize(width: side, height: side)))
        refreshPointerLocation()
        updateQuickAccess()
        if isVisible { startTicker() }
    }

    func refreshTimers() {
        let height = TimerTrayView.height(count: timerCoordinator?.timers.count ?? 0,
                                         hasNotice: timerCoordinator?.notificationMessage != nil)
        timerTray.refresh(settings: settings)
        timerTray.isHidden = height == 0
        if height != trayHeight {
            let dial = clockScreenFrame
            trayHeight = height
            layoutPanel(anchoredAt: dial)
            onPositionChanged?(clockScreenFrame.origin)
            refreshPointerLocation()
        }
        if timerCoordinator?.timers.isEmpty == true { makeFirstResponder(nil); resignKey() }
        recordingButton.toolTip = (timerCoordinator?.timers.count ?? 0) >= 3 ? "已达三组上限，请先删除一组" : "添加倒计时 / 累计计时（最多三组）"
        updateQuickAccess()
    }

    func showClock() {
        orderFrontRegardless()
        refreshPointerLocation()
        updateQuickAccess()
        startTicker()
    }

    func hideClock() {
        hideQuickAccess()
        recordingButton.isHidden = true
        face.quickAccessCorner = nil
        pointerInside = false
        face.setAccessibilityChildren([])
        orderOut(nil)
        ticker?.invalidate()
        ticker = nil
    }

    func moveToCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let side = settings.faceSize + ClockLayout.padding * 2
        let origin = ClockLayout.defaultOrigin(size: side, screen: screen.visibleFrame)
        layoutPanel(anchoredAt: CGRect(x: origin.x, y: origin.y, width: side, height: side))
        constrainAndSavePosition()
        showClock()
    }

    func constrainAndSavePosition() {
        let dial = clockScreenFrame
        let origin = ClockLayout.clampedOrigin(dial.origin, size: dial.width, screens: NSScreen.screens.map(\.visibleFrame))
        layoutPanel(anchoredAt: CGRect(origin: origin, size: dial.size))
        onPositionChanged?(clockScreenFrame.origin)
        refreshPointerLocation()
        updateQuickAccess()
    }

    func windowDidMove(_ notification: Notification) {
        guard !layingOut else { return }
        refreshPointerLocation()
        updateQuickAccess()
    }
    func windowDidResize(_ notification: Notification) { if !layingOut { updateQuickAccess() } }

    private func layoutPanel(anchoredAt dial: CGRect) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let screenFrame = NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(dial), ib = b.visibleFrame.intersection(dial)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = TimerAttachmentLayout(clock: dial, trayHeight: trayHeight, screen: screenFrame)
        setFrame(layout.frame, display: true)
        face.dialFrame = layout.dialFrame
        timerTray.frame = layout.trayFrame
        face.needsDisplay = true
    }

    private func refreshPointerLocation() {
        pointerInside = isVisible && frame.contains(NSEvent.mouseLocation)
    }

    private func updateQuickAccess() {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let corner = QuickAccessLayout.corner(for: clockScreenFrame, on: screenFrame)
        let card = face.dialCard
        let buttonFrame = QuickAccessLayout.buttonFrame(in: card, corner: corner)
        recordingButton.frame = buttonFrame
        recordingButton.settings = settings
        recordingButton.faceScale = card.width / 224
        let showRecording = !settings.isLocked && isVisible && pointerInside
        recordingButton.isHidden = !showRecording
        if settings.isLocked && isVisible {
            face.quickAccessCorner = corner
            quickAccessPanel.button.settings = settings
            quickAccessPanel.button.faceScale = card.width / 224
            quickAccessPanel.level = level
            quickAccessPanel.collectionBehavior = collectionBehavior
            quickAccessPanel.alphaValue = max(0.7, settings.alpha)
            quickAccessPanel.setFrame(convertToScreen(buttonFrame), display: true)
            if quickAccessPanel.parent !== self { addChildWindow(quickAccessPanel, ordered: .above) }
            quickAccessPanel.orderFrontRegardless()
            quickAccessPanel.button.setAccessibilityParent(face)
        } else {
            hideQuickAccess()
            face.quickAccessCorner = showRecording ? corner : nil
        }
        var children: [Any] = []
        if !timerTray.isHidden { children.append(timerTray) }
        if showRecording { children.append(recordingButton) }
        if quickAccessPanel.isVisible { children.append(quickAccessPanel.button) }
        face.setAccessibilityChildren(children)
    }

    private func hideQuickAccess() {
        quickAccessPanel.button.setAccessibilityParent(nil)
        if quickAccessPanel.parent === self { removeChildWindow(quickAccessPanel) }
        quickAccessPanel.orderOut(nil)
    }

    @objc private func addTimer() {
        guard !settings.isLocked, let id = timerCoordinator?.add() else { return }
        refreshTimers()
        makeKey()
        face.layoutSubtreeIfNeeded()
        if let row = timerTray.rows.first(where: { $0.id == id }) {
            makeFirstResponder(row.durationInput.minutes.field)
            row.durationInput.minutes.field.selectText(nil)
        }
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
