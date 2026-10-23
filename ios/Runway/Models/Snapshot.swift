import Foundation

/// Everything the backend returns from `GET /api/snapshot`. Dates come over the
/// wire as `yyyy-MM-dd` strings and are parsed on demand with `Day`.
struct Snapshot: Codable, Equatable {
    var syncedAt: String
    var institutions: [Institution]
    var accounts: [Account]
    var transactions: [Transaction]
    var creditCards: [CreditCard]
    var recurring: [RecurringStream]
}

struct Institution: Codable, Equatable, Identifiable, Hashable {
    var itemId: String
    var name: String
    var id: String { itemId }
}

struct Account: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var itemId: String
    var institution: String
    var name: String
    var officialName: String?
    var mask: String?
    var type: String
    var subtype: String?
    var currentBalance: Double?
    var availableBalance: Double?
    var limit: Double?
    var currency: String

    var isCredit: Bool { type == "credit" }
    var isSavings: Bool {
        type == "depository" && ["savings", "cd", "money market", "hsa"].contains(subtype ?? "")
    }
    /// Checking-like money you can spend today.
    var isSpendableCash: Bool { type == "depository" && !isSavings }

    var displayName: String {
        if let mask { return "\(name) ••\(mask)" }
        return name
    }

    /// For cash accounts, what you could spend now. For cards, what you owe.
    var balance: Double {
        if isCredit { return currentBalance ?? 0 }
        return availableBalance ?? currentBalance ?? 0
    }
}

struct Transaction: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var accountId: String
    var date: String
    var name: String
    var merchant: String?
    /// Plaid's sign convention: positive is money leaving the account.
    var amount: Double
    var category: String
    var detailedCategory: String?
    var pending: Bool
    var logoUrl: String?

    var displayName: String { merchant ?? name }
    var day: Date { Day.parse(date) }
}

struct CreditCard: Codable, Equatable, Hashable {
    var accountId: String
    var lastStatementBalance: Double?
    var lastStatementDate: String?
    var nextPaymentDueDate: String?
    var minimumPayment: Double?
    var lastPaymentAmount: Double?
    var lastPaymentDate: String?
    var isOverdue: Bool
    var purchaseApr: Double?
}

struct RecurringStream: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var accountId: String
    var direction: String
    var description: String
    var merchant: String?
    var averageAmount: Double
    var lastAmount: Double
    var frequency: String
    var lastDate: String
    var predictedNextDate: String?
    var category: String?
    var isActive: Bool
    /// The deposits or charges Plaid grouped into this stream.
    var transactionIds: [String]?

    var isIncome: Bool { direction == "inflow" && (category == nil || category == "INCOME") }
    var displayName: String { merchant ?? description }
}

/// A loose, stable name for a merchant or payer, so "ACME CORP PAYROLL PPD
/// ID: 1234" and "Acme Corp" can be recognized as the same place.
enum MerchantKey {
    private static let noise: Set<String> = [
        "ppd", "id", "des", "indn", "web", "ach", "dir", "dep", "direct", "deposit", "from", "the", "inc", "llc", "co", "pos",
    ]

    static func of(_ name: String) -> String {
        let words = name.lowercased()
            .map { $0.isLetter ? $0 : " " }
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 && !noise.contains($0) }
        return words.prefix(3).joined(separator: " ")
    }

    /// True when one key is a word-for-word prefix of the other.
    static func matches(_ a: String, _ b: String) -> Bool {
        let aw = a.split(separator: " "), bw = b.split(separator: " ")
        let n = min(aw.count, bw.count)
        return n > 0 && aw.prefix(n) == bw.prefix(n)
    }
}

/// Calendar-day helpers. All budgeting math works in whole local days.
enum Day {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ string: String) -> Date {
        formatter.date(from: String(string.prefix(10))) ?? .distantPast
    }

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    static var calendar: Calendar { Calendar.current }

    static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    static func endOfMonth(_ date: Date) -> Date {
        calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth(date))!
    }

    /// Days from `date` through the end of its month, counting today.
    static func daysLeftInMonth(_ date: Date) -> Int {
        let start = calendar.startOfDay(for: date)
        let end = endOfMonth(date)
        return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}
