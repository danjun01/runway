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
