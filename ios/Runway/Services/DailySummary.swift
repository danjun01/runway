import BackgroundTasks
import Foundation
import UserNotifications

/// The morning notification with the day's safe-to-spend number. iOS won't run
/// the app on a timer, so whenever the numbers change the next notification is
/// rescheduled with them, and a background refresh is requested shortly before
/// it fires so it usually goes out with fresh data.
enum DailySummary {
    static let refreshTaskId = "com.danjun01.runway.refresh"
    private static let notificationId = "daily-safe-to-spend"

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId])
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskId)
    }

    static func schedule(engine: BudgetEngine, minutes: Int, now: Date = .now) async {
        let fire = nextFireDate(minutes: minutes, after: now)
        let content = UNMutableNotificationContent()
        content.title = "Safe to spend"
        content.body = message(for: engine, on: fire)
        let components = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(identifier: notificationId, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        try? await center.add(request)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        refresh.earliestBeginDate = fire.addingTimeInterval(-2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    /// The next time of day at `minutes` past midnight, later than `now`.
    static func nextFireDate(minutes: Int, after now: Date) -> Date {
        let cal = Day.calendar
        let todayAt = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now)!
        return todayAt > now ? todayAt : cal.date(byAdding: .day, value: 1, to: todayAt)!
    }

    /// The notification text: the month's number, spread over the days left on
    /// the day it fires.
    static func message(for engine: BudgetEngine, on fire: Date) -> String {
        guard Day.calendar.isDate(fire, equalTo: engine.today, toGranularity: .month) else {
            return "A new month starts today. Open Runway to see what's safe to spend."
        }
        let safe = engine.safeToSpend
        guard safe.amount > 0 else {
            return "You're over by \((-safe.amount).currency()) this month. Open Runway for a plan."
        }
        let days = Day.daysLeftInMonth(fire)
        var text = days == 1
            ? "\(safe.amount.currency()) left for the last day of the month."
            : "\(safe.amount.currency()) left this month, about \((safe.amount / Double(days)).currency()) a day for \(days) days."
        if safe.isTimingLimited, let payday = safe.lowPoint.nextPaycheck, payday > fire {
            text += " Keep it under \(safe.spendableNow.currency()) until your paycheck on \(payday.shortDay)."
        }
        return text
    }
}
