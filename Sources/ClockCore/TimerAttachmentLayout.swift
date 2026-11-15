import CoreGraphics

public struct TimerAttachmentLayout {
    public let frame: CGRect
    public let dialFrame: CGRect
    public let trayFrame: CGRect
    public let isAbove: Bool

    /// Keep the dial anchored and grow toward the center of its own display.
    public init(clock: CGRect, trayHeight: CGFloat, screen: CGRect, footerHeight: CGFloat = 0,
                constrainToScreen: Bool = true) {
        guard trayHeight > 0 else {
            frame = clock
            dialFrame = CGRect(origin: .zero, size: clock.size)
            trayFrame = .zero
            isAbove = false
            return
        }
        let below = clock.minY - screen.minY
        let above = screen.maxY - clock.maxY
        let belowHeight = trayHeight + footerHeight
        isAbove = below < belowHeight && above >= trayHeight ? true :
            (above < trayHeight && below >= belowHeight ? false : clock.midY < screen.midY)
        let width = max(clock.width, ClockLayout.minimumPanelWidth)
        let height = clock.height + trayHeight + footerHeight
        let preferredX = clock.midX - width / 2
        let preferredY = clock.minY - (isAbove ? footerHeight : trayHeight + footerHeight)
        // While dragging, preserve the dial's screen position even if the tray
        // crosses an edge. Constrain the complete panel when the drag finishes.
        let x = constrainToScreen ? min(max(preferredX, screen.minX), max(screen.minX, screen.maxX - width)) : preferredX
        let y = constrainToScreen ? min(max(preferredY, screen.minY), max(screen.minY, screen.maxY - height)) : preferredY
        frame = CGRect(x: x, y: y, width: width, height: height)
        dialFrame = CGRect(x: (width - clock.width) / 2, y: (isAbove ? 0 : trayHeight) + footerHeight, width: clock.width, height: clock.height)
        trayFrame = CGRect(x: ClockLayout.padding, y: (isAbove ? clock.height - ClockLayout.padding : ClockLayout.padding) + footerHeight,
                           width: width - ClockLayout.padding * 2, height: trayHeight)
    }
}
