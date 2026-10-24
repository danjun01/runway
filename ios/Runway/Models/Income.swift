import Foundation

enum PayFrequency: String, Codable, CaseIterable, Identifiable, Hashable {
    case weekly, biweekly, semiMonthly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .semiMonthly: "Twice a month"
        case .monthly: "Monthly"
        }
    }

    /// Average paychecks in a month, for monthly estimates.
    var perMonth: Double {
        switch self {
        case .weekly: 52.0 / 12
        case .biweekly: 26.0 / 12
        case .semiMonthly: 2
        case .monthly: 1
        }
    }

    /// How far from the expected day a deposit can land and still count as that paycheck.
    var matchWindowDays: Int { self == .weekly ? 2 : 4 }

    init?(plaid: String) {
        switch plaid {
        case "WEEKLY": self = .weekly
        case "BIWEEKLY": self = .biweekly
        case "SEMI_MONTHLY": self = .semiMonthly
        case "MONTHLY": self = .monthly
        default: return nil
        }
    }
}

/// Money that comes in on a schedule: a salary, a stipend, a roommate's share
/// of rent. Runway detects these from history; the user can confirm, edit,
/// ignore, or add their own. Only user-touched sources are persisted, so
/// detection keeps improving for the rest.
struct IncomeSource: Codable, Equatable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Found by Runway and looks like income. Not counted until the user
        /// confirms it, so a wrong guess can't inflate the numbers.
        case detected
        /// Regular money in that might not be income (e.g. transfers). Not counted until confirmed.
        case suggested
        case confirmed
        case ignored
    }

    var id: String
    var name: String
    /// Typical amount of one paycheck.
    var amount: Double
    var frequency: PayFrequency
    /// Any known payday. Paydays are projected forward and back from it.
    var anchorDate: String
    /// Deposits whose name normalizes to this belong to the source.
    var matchKey: String
    var status: Status
    /// Plaid's recurring stream, when the source came from one. Its transaction
    /// ids match deposits exactly even when names drift.
    var streamId: String?
    /// No taxes are withheld (freelance or 1099 income), so part of each deposit is set aside for taxes.
    var untaxed: Bool?

    var counts: Bool { status == .confirmed }
    var isManual: Bool { id.hasPrefix("manual:") }
    var monthlyEstimate: Double { amount * frequency.perMonth }

    static func manual(name: String, amount: Double, frequency: PayFrequency, nextDate: Date) -> IncomeSource {
        IncomeSource(id: "manual:\(UUID().uuidString)", name: name, amount: amount, frequency: frequency,
                     anchorDate: Day.string(nextDate), matchKey: MerchantKey.of(name), status: .confirmed)
    }
}

/// One paycheck in a month, either one that has landed or one that's projected.
struct Paycheck: Identifiable, Hashable {
    enum State: String, Hashable {
        /// The deposit is in the account.
        case arrived
        /// Projected from the income schedule; not in the account yet.
        case expected
        /// Was due a few days ago and hasn't shown up. Not counted.
        case missed
    }

    var sourceId: String
    var name: String
    var date: Date
    var amount: Double
    var state: State
    var id: String { "\(sourceId)|\(Day.string(date))|\(state.rawValue)" }
}

/// A cost that doesn't come every month: car insurance every 6 months, property
/// tax, an annual subscription. Runway sets a little aside each month so the
/// bill is covered when it lands, YNAB style.
struct PlannedExpense: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var amount: Double
    /// The next time it's due (yyyy-MM-dd), as of when it was last edited.
    var dueDate: String
    /// Months between payments, or nil for a one-time expense.
    var everyMonths: Int?
    /// Already put aside for the next payment when it was last edited.
    var savedAtStart: Double
    /// The month (yyyy-MM-dd, first of the month) setting aside began.
    var startMonth: String
    /// The Plaid recurring stream it was created from, so the same charge isn't also counted as a bill.
    var streamId: String?

    static func new(name: String, amount: Double, dueDate: Date, everyMonths: Int?, saved: Double,
                    streamId: String? = nil, today: Date = .now) -> PlannedExpense {
        PlannedExpense(id: "planned:\(UUID().uuidString)", name: name, amount: amount, dueDate: Day.string(dueDate),
                       everyMonths: everyMonths, savedAtStart: saved, startMonth: Day.string(Day.startOfMonth(today)),
                       streamId: streamId)
    }

    var repeatText: String {
        switch everyMonths {
        case nil: "One time"
        case 1: "Every month"
        case 12: "Every year"
        case let n?: "Every \(n) months"
        }
    }
}

/// Self-employment taxes: a share of income that has no tax withheld gets set
/// aside, and estimated payments are due four times a year.
struct TaxSettings: Codable, Equatable {
    var enabled = false
    /// The share of untaxed income to set aside, e.g. 0.3 for 30%.
    var rate = 0.3
}
