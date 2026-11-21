import Foundation

public enum CalendarViewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case day = "Day", week = "Week", month = "Month"
    public var id: Self { self }

    public func window(for date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .day: return calendar.dateInterval(of: .day, for: date)!
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
            let end = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))!.end
            return DateInterval(start: start, end: end)
        }
    }

    public func advance(_ date: Date, by step: Int, calendar: Calendar) -> Date {
        let unit: Calendar.Component
        switch self {
        case .day: unit = .day
        case .week: unit = .weekOfYear
        case .month: unit = .month
        }
        return calendar.date(byAdding: unit, value: step, to: date) ?? date
    }
}

public enum CalendarWindow {
    public static func days(in window: DateInterval, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var date = window.start
        while date < window.end {
            days.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = calendar.startOfDay(for: next)
        }
        return days
    }
}

public enum DayPaging {
    /// Returns the physical direction of a completed drag. A short, deliberate flick also counts.
    public static func horizontalDirection(translation: Double, projected: Double, width: Double) -> Int? {
        guard width > 0, abs(translation) >= 28 else { return nil }
        let distance = max(54, width * 0.26)
        let flick = projected.sign == translation.sign && abs(projected) >= distance * 1.25
        guard abs(translation) >= distance || flick else { return nil }
        return translation < 0 ? 1 : -1
    }

    public static func pullProgress(overscroll: Double) -> Double {
        min(1, max(0, (overscroll - 8) / 52))
    }

    public static func pullProgress(travel: Double, viewportHeight: Double) -> Double {
        let threshold = max(44, viewportHeight * 0.18)
        return min(1, max(0, travel / threshold))
    }
}
