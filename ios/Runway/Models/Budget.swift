import Foundation

/// One bucket in the budget, YNAB style: money assigned each month to a
/// purpose. `monthlyAmount` is what's assigned.
struct BudgetCategory: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    /// Bills (rent, utilities, loans) are reserved out of safe-to-spend until paid.
    var isFixed: Bool
    var monthlyAmount: Double

    var isCustom: Bool { id.hasPrefix("custom:") }

    static func custom(name: String, isFixed: Bool, amount: Double) -> BudgetCategory {
        BudgetCategory(id: "custom:\(UUID().uuidString)", name: name, symbol: isFixed ? "doc.text.fill" : "tray.fill",
                       isFixed: isFixed, monthlyAmount: amount)
    }
}

extension BudgetCategory {
    /// The starting set of envelopes. Amounts are filled in from spending history.
    static let defaults: [BudgetCategory] = [
        .init(id: "rent", name: "Rent & utilities", symbol: "house.fill", isFixed: true, monthlyAmount: 0),
        .init(id: "bills", name: "Bills & services", symbol: "doc.text.fill", isFixed: true, monthlyAmount: 0),
        .init(id: "loans", name: "Loan payments", symbol: "building.columns.fill", isFixed: true, monthlyAmount: 0),
        .init(id: "groceries", name: "Groceries", symbol: "cart.fill", isFixed: false, monthlyAmount: 0),
        .init(id: "dining", name: "Dining out", symbol: "fork.knife", isFixed: false, monthlyAmount: 0),
        .init(id: "transport", name: "Transportation", symbol: "car.fill", isFixed: false, monthlyAmount: 0),
        .init(id: "shopping", name: "Shopping", symbol: "bag.fill", isFixed: false, monthlyAmount: 0),
        .init(id: "fun", name: "Fun", symbol: "sparkles", isFixed: false, monthlyAmount: 0),
        .init(id: "health", name: "Health & care", symbol: "heart.fill", isFixed: false, monthlyAmount: 0),
        .init(id: "home", name: "Home", symbol: "hammer.fill", isFixed: false, monthlyAmount: 0),
        .init(id: "travel", name: "Travel", symbol: "airplane", isFixed: false, monthlyAmount: 0),
        .init(id: "other", name: "Everything else", symbol: "square.grid.2x2.fill", isFixed: false, monthlyAmount: 0),
    ]

    /// Which envelope a transaction belongs to, or nil when it isn't spending
    /// (income, transfers, and credit card payments, which would double count).
    static func categoryId(for t: Transaction) -> String? {
        categoryId(primary: t.category, detailed: t.detailedCategory)
    }

    static func categoryId(primary: String, detailed: String?) -> String? {
        let detailed = detailed ?? ""
        switch primary {
        case "INCOME", "TRANSFER_IN", "TRANSFER_OUT":
            return nil
        case "LOAN_PAYMENTS":
            return detailed == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" ? nil : "loans"
        case "RENT_AND_UTILITIES":
            return "rent"
        case "GENERAL_SERVICES":
            return "bills"
        case "FOOD_AND_DRINK":
            return detailed == "FOOD_AND_DRINK_GROCERIES" ? "groceries" : "dining"
        case "TRANSPORTATION":
            return "transport"
        case "GENERAL_MERCHANDISE":
            return "shopping"
        case "ENTERTAINMENT":
            return "fun"
        case "MEDICAL", "PERSONAL_CARE":
            return "health"
        case "HOME_IMPROVEMENT":
            return "home"
        case "TRAVEL":
            return "travel"
        default:
            return "other"
        }
    }

    /// The bucket a transaction lands in once the user's own rules
    /// (merchant key -> bucket id) are applied. Income and card payments are
    /// never spending, whatever the rules say.
    static func bucketId(for t: Transaction, rules: [String: String], budgets: [BudgetCategory]) -> String? {
        if t.category == "INCOME" || t.detailedCategory == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" { return nil }
        if let id = rules[MerchantKey.of(t.displayName)], budgets.contains(where: { $0.id == id }) { return id }
        guard let id = categoryId(for: t) else { return nil }
        // A deleted bucket's spending lands in "Everything else" rather than disappearing.
        if budgets.contains(where: { $0.id == id }) || !budgets.contains(where: { $0.id == "other" }) { return id }
        return "other"
    }
}

struct ChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var content: String
    var isError = false
}
