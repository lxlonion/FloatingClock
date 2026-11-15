import CoreGraphics

public struct TimerAttachmentLayout {
    public let frame: CGRect
    public let dialFrame: CGRect
    public let trayFrame: CGRect
    public let isAbove: Bool

    /// Keep the dial anchored and grow toward the center of its own display.
    public init(clock: CGRect, trayHeight: CGFloat, screen: CGRect, footerHeight: CGFloat = 0) {
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
        let width = max(clock.width, 284)
        let height = clock.height + trayHeight + footerHeight
        let x = min(max(clock.midX - width / 2, screen.minX), max(screen.minX, screen.maxX - width))
        let preferredY = clock.minY - (isAbove ? footerHeight : trayHeight + footerHeight)
        let y = min(max(preferredY, screen.minY), max(screen.minY, screen.maxY - height))
        frame = CGRect(x: x, y: y, width: width, height: height)
        dialFrame = CGRect(x: (width - clock.width) / 2, y: (isAbove ? 0 : trayHeight) + footerHeight, width: clock.width, height: clock.height)
        trayFrame = CGRect(x: ClockLayout.padding, y: (isAbove ? clock.height - ClockLayout.padding : ClockLayout.padding) + footerHeight,
                           width: width - ClockLayout.padding * 2, height: trayHeight)
    }
}
