import Foundation

public struct ClockReadout {
    public let day: String
    public let weekday: String
    public let minute: String

    public init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.day, .weekday, .minute], from: date)
        day = String(components.day ?? 1)
        weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][(components.weekday ?? 1) - 1]
        minute = String(format: "%02d", components.minute ?? 0)
    }
}
