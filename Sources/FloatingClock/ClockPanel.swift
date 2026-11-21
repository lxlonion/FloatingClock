import AppKit
import ClockCore

final class ClockPanel: NSPanel, NSWindowDelegate {
    let face = ClockFaceView()
    let quickAccessPanel = QuickAccessPanel()
    let addTimerButton = QuickAccessButton(title: "", target: nil, action: nil)
    let timerTray = TimerTrayView(frame: .zero)
    let timerHint = NSTextField(labelWithString: "＋ 倒计时  ·  − 累计时间")
    var timerCoordinator: TimerCoordinator? {
        didSet { timerTray.coordinator = timerCoordinator; refreshTimers() }
    }
    private var ticker: Timer?
    private var pointerTracker: Timer?
    private var settings: ClockSettings
    private var pointerInside = false
    private var layingOut = false
    private var trayHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    private var settledOrigin: CGPoint?
    var onPositionChanged: ((CGPoint) -> Void)?
    var onQuickMenuRequested: ((NSView) -> Void)?
    var layoutScreenFrameOverride: CGRect? { didSet { constrainPosition() } }
    var mouseLocationProvider: () -> CGPoint = { NSEvent.mouseLocation }

    override var canBecomeKey: Bool { !settings.isLocked && !(timerCoordinator?.timers.isEmpty ?? true) }
    override var canBecomeMain: Bool { false }
    var clockScreenFrame: CGRect { convertToScreen(face.dialFrame ?? face.bounds) }

    init(settings value: ClockSettings) {
        let settings = value.normalized()
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
        face.onDragMoved = { [weak self] dial in
            self?.layoutPanel(anchoredAt: dial, constrainToScreen: false)
            self?.refreshPointerLocation()
            self?.updateQuickAccess()
        }
        face.onDragFinished = { [weak self] in self?.constrainPosition() }
        face.onHoverChanged = { [weak self] inside in
            guard let self, !self.settings.isLocked else { return }
            self.pointerInside = inside
            self.updateQuickAccess()
        }
        addTimerButton.isTimerEntry = true
        addTimerButton.isBordered = false
        addTimerButton.target = self
        addTimerButton.action = #selector(addTimer)
        addTimerButton.toolTip = "添加倒计时 / 累计计时（最多三组）"
        addTimerButton.setAccessibilityLabel("添加计时，最多三组")
        face.addSubview(timerTray)
        timerHint.font = .systemFont(ofSize: 10)
        timerHint.textColor = .secondaryLabelColor
        timerHint.alignment = .center
        timerHint.isHidden = true
        face.addSubview(timerHint)
        face.addSubview(addTimerButton)
        timerTray.isHidden = true
        delegate = self
        quickAccessPanel.onOpen = { [weak self] view in self?.onQuickMenuRequested?(view) }
        layoutPanel(anchoredAt: clockScreenFrame, preservingOrigin: true)
        apply(settings)
    }

    func apply(_ value: ClockSettings) {
        let previous = settings
        settings = value.normalized()
        face.settings = settings
        alphaValue = face.compositingAlpha
        timerTray.alphaValue = face.relativeContentAlpha
        timerHint.alphaValue = face.relativeContentAlpha
        addTimerButton.alphaValue = face.relativeContentAlpha
        ignoresMouseEvents = settings.isLocked

        let appearance: NSAppearance? = settings.appearance == .system ? nil :
            NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
        if timerTray.appearance?.name != appearance?.name {
            timerTray.appearance = appearance
            timerHint.appearance = appearance
        }
        let faceSizeChanged = previous.faceSize != settings.faceSize
        if faceSizeChanged || previous.appearance != settings.appearance || previous.timerDisplayFormat != settings.timerDisplayFormat {
            timerTray.refresh(settings: settings)
            if updateTimerHeights() || faceSizeChanged {
                settlePosition(anchoredAt: clockScreenFrame)
            }
        }
        if settings.isLocked && !previous.isLocked { makeFirstResponder(nil); resignKey() }
        refreshPointerLocation()
        updateQuickAccess()
        if isVisible && settings.showsSeconds != previous.showsSeconds { startTicker() }
        if isVisible && settings.isLocked != previous.isLocked { startPointerTracking() }
    }

    func refreshTimers() {
        timerTray.refresh(settings: settings)
        if updateTimerHeights() {
            if face.isDragging {
                layoutPanel(anchoredAt: clockScreenFrame, constrainToScreen: false)
            } else {
                settlePosition(anchoredAt: clockScreenFrame)
            }
            refreshPointerLocation()
        }
        if timerCoordinator?.timers.isEmpty == true { makeFirstResponder(nil); resignKey() }
        addTimerButton.toolTip = (timerCoordinator?.timers.count ?? 0) >= 3 ? "已达三组上限，请先删除一组" : "添加倒计时 / 累计计时（最多三组）"
        updateQuickAccess()
    }

    private func updateTimerHeights() -> Bool {
        let height = timerTray.contentHeight
        let newFooterHeight: CGFloat = timerCoordinator?.timers.count == 1 ? 28 : 0
        guard height != trayHeight || newFooterHeight != footerHeight else { return false }
        trayHeight = height
        footerHeight = newFooterHeight
        timerHint.isHidden = footerHeight == 0
        timerTray.isHidden = trayHeight == 0
        return true
    }

    func showClock() {
        orderFrontRegardless()
        refreshPointerLocation()
        updateQuickAccess()
        startTicker()
        startPointerTracking()
    }

    func hideClock() {
        hideQuickAccess()
        addTimerButton.isHidden = true
        face.quickAccessCorner = nil
        pointerInside = false
        face.setAccessibilityChildren([])
        orderOut(nil)
        ticker?.invalidate()
        ticker = nil
        pointerTracker?.invalidate()
        pointerTracker = nil
    }

    func moveToCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let side = settings.faceSize + ClockLayout.padding * 2
        let origin = ClockLayout.defaultOrigin(size: side, screen: screen.visibleFrame)
        settlePosition(anchoredAt: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        showClock()
    }

    func restorePosition(_ origin: StoredPoint?) {
        var dial = clockScreenFrame
        if let origin { dial.origin = CGPoint(x: origin.x, y: origin.y) }
        settlePosition(anchoredAt: dial, preservingOrigin: true)
    }

    func constrainPosition() {
        settlePosition(anchoredAt: clockScreenFrame)
        refreshPointerLocation()
        updateQuickAccess()
    }

    private func settlePosition(anchoredAt dial: CGRect, preservingOrigin: Bool = false) {
        layoutPanel(anchoredAt: dial, preservingOrigin: preservingOrigin)
        let origin = clockScreenFrame.origin
        guard origin != settledOrigin else { return }
        settledOrigin = origin
        onPositionChanged?(origin)
    }

    func windowDidMove(_ notification: Notification) {
        guard !layingOut else { return }
        layoutPanel(anchoredAt: clockScreenFrame, constrainToScreen: false)
        refreshPointerLocation()
        updateQuickAccess()
    }
    func windowDidResize(_ notification: Notification) { if !layingOut { updateQuickAccess() } }

    private func layoutPanel(anchoredAt dial: CGRect, constrainToScreen: Bool = true, preservingOrigin: Bool = false) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        var screenAnchor = dial
        if constrainToScreen && layoutScreenFrameOverride == nil {
            screenAnchor.origin = ClockLayout.clampedOrigin(dial.origin, size: dial.width, screens: NSScreen.screens.map(\.visibleFrame))
        }
        let screenFrame = layoutScreenFrame(for: screenAnchor)
        let minimumTrayViewport = min(trayHeight, 80)
        let maximumSide = max(1, min(screenFrame.width, screenFrame.height - footerHeight - minimumTrayViewport))
        let preferredSide = settings.faceSize + ClockLayout.padding * 2
        let side = constrainToScreen ? min(preferredSide, maximumSide) : dial.width
        let preferredOrigin = preservingOrigin ? dial.origin : CGPoint(x: dial.midX - side / 2, y: dial.midY - side / 2)
        let origin = constrainToScreen ? ClockLayout.clampedOrigin(preferredOrigin, size: side, screens: [screenFrame]) : preferredOrigin
        let displayDial = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let layout = TimerAttachmentLayout(clock: displayDial, trayHeight: trayHeight, screen: screenFrame,
                                           footerHeight: footerHeight, constrainToScreen: constrainToScreen)
        if frame != layout.frame { setFrame(layout.frame, display: false) }
        face.dialFrame = layout.dialFrame
        timerTray.frame = layout.trayFrame
        timerHint.frame = CGRect(x: ClockLayout.padding + 10, y: ClockLayout.padding + 6,
                                 width: layout.frame.width - ClockLayout.padding * 2 - 20, height: 16)
        face.invalidateDial()
        invalidateCursorRects(for: face)
    }

    private func layoutScreenFrame(for dial: CGRect) -> CGRect {
        if let layoutScreenFrameOverride { return layoutScreenFrameOverride }
        return NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(dial), ib = b.visibleFrame.intersection(dial)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func refreshPointerLocation() {
        pointerInside = isVisible && frame.contains(mouseLocationProvider())
    }

    private func updateQuickAccess() {
        let screenFrame = layoutScreenFrame(for: clockScreenFrame)
        let corner = QuickAccessLayout.corner(for: clockScreenFrame, on: screenFrame)
        let card = face.dialCard
        let buttonFrame = QuickAccessLayout.buttonFrame(in: card, corner: corner)
        addTimerButton.frame = buttonFrame
        addTimerButton.settings = settings
        addTimerButton.faceScale = card.width / 224
        let showTimerEntry = !settings.isLocked && isVisible && pointerInside
        addTimerButton.isHidden = !showTimerEntry
        if settings.isLocked && isVisible {
            face.quickAccessCorner = pointerInside ? corner : nil
            quickAccessPanel.button.settings = settings
            quickAccessPanel.button.faceScale = card.width / 224
            quickAccessPanel.button.isHidden = !pointerInside
            quickAccessPanel.level = level
            quickAccessPanel.collectionBehavior = collectionBehavior
            quickAccessPanel.alphaValue = settings.contentAlpha
            quickAccessPanel.setFrame(convertToScreen(buttonFrame), display: true)
            if quickAccessPanel.parent !== self { addChildWindow(quickAccessPanel, ordered: .above) }
            quickAccessPanel.ignoresMouseEvents = !pointerInside
            quickAccessPanel.orderFrontRegardless()
            quickAccessPanel.display()
            quickAccessPanel.button.setAccessibilityParent(pointerInside ? face : nil)
        } else {
            hideQuickAccess()
            face.quickAccessCorner = showTimerEntry ? corner : nil
        }
        var children: [Any] = []
        if !timerTray.isHidden { children.append(timerTray) }
        if !timerHint.isHidden { children.append(timerHint) }
        if showTimerEntry { children.append(addTimerButton) }
        if quickAccessPanel.isEntryVisible { children.append(quickAccessPanel.button) }
        face.setAccessibilityChildren(children)
    }

    private func hideQuickAccess() {
        quickAccessPanel.button.isHidden = true
        quickAccessPanel.ignoresMouseEvents = true
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
            row.scrollToVisible(row.bounds)
            makeFirstResponder(row.durationInput.minutes.field)
            row.durationInput.minutes.field.selectText(nil)
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        face.invalidateDial()
        let timer = Timer(timeInterval: settings.showsSeconds ? 1 / 30 : 1, repeats: true) { [weak self] _ in
            self?.face.invalidateDial()
        }
        timer.tolerance = settings.showsSeconds ? 0.008 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func startPointerTracking() {
        pointerTracker?.invalidate()
        pointerTracker = nil
        guard settings.isLocked && isVisible else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let wasInside = self.pointerInside
            self.refreshPointerLocation()
            if wasInside != self.pointerInside { self.updateQuickAccess() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pointerTracker = timer
    }

    deinit { ticker?.invalidate(); pointerTracker?.invalidate() }
}
