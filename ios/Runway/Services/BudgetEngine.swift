import Foundation

/// Pure budgeting math over a snapshot. No networking, no UI, so it's easy to
/// reason about and to test.
struct BudgetEngine {
    var snapshot: Snapshot
    var budgets: [BudgetCategory]
    /// Money to set aside each month before anything counts as spendable.
    var monthlySavingsGoal: Double
    var today: Date = .now

    private var cal: Calendar { Day.calendar }
    private var monthStart: Date { Day.startOfMonth(today) }
    private var monthEnd: Date { Day.endOfMonth(today) }

    // MARK: Spending

    var spendingThisMonth: [Transaction] {
        snapshot.transactions.filter { t in
            t.day >= monthStart && t.day <= monthEnd && BudgetCategory.categoryId(for: t) != nil
        }
    }

    func spent(in categoryId: String) -> Double {
        spendingThisMonth
            .filter { BudgetCategory.categoryId(for: $0) == categoryId }
            .reduce(0) { $0 + $1.amount }
    }

    func transactions(in categoryId: String) -> [Transaction] {
        spendingThisMonth.filter { BudgetCategory.categoryId(for: $0) == categoryId }
    }

    var totalBudgeted: Double { budgets.reduce(0) { $0 + $1.monthlyAmount } }
    var totalSpent: Double { spendingThisMonth.reduce(0) { $0 + $1.amount } }

    /// Fixed bills you've budgeted for but haven't paid yet this month.
    var billsRemaining: Double {
        budgets.filter(\.isFixed).reduce(0) { $0 + max(0, $1.monthlyAmount - spent(in: $1.id)) }
    }

    // MARK: Suggested budget

    /// Average monthly spend per envelope over up to the last 90 days of
    /// history, rounded up to the nearest $10.
    func suggestedBudgets() -> [BudgetCategory] {
        let windowStart = cal.date(byAdding: .day, value: -90, to: cal.startOfDay(for: today))!
        let history = snapshot.transactions.filter { $0.day >= windowStart && $0.day < cal.startOfDay(for: today) }
        guard let earliest = history.map(\.day).min() else { return BudgetCategory.defaults }
        let days = max(14, cal.dateComponents([.day], from: earliest, to: today).day ?? 30)
        let months = Double(days) / 30.4

        var totals: [String: Double] = [:]
        for t in history {
            guard let id = BudgetCategory.categoryId(for: t) else { continue }
            totals[id, default: 0] += t.amount
        }
        return BudgetCategory.defaults.map { category in
            var c = category
            let monthly = max(0, (totals[c.id] ?? 0) / months)
            c.monthlyAmount = monthly < 1 ? 0 : (monthly / 10).rounded(.up) * 10
            return c
        }
    }

    // MARK: Safe to spend

    struct IncomeEvent: Encodable, Hashable {
        var name: String
        var date: String
        var amount: Double
    }

    struct SafeToSpend {
        var cash: Double
        var expectedIncome: Double
        var incomeEvents: [IncomeEvent]
        var creditCardBalances: Double
        var billsRemaining: Double
        var savingsGoal: Double
        var daysLeft: Int

        var amount: Double { cash + expectedIncome - creditCardBalances - billsRemaining - savingsGoal }
        var perDay: Double { max(0, amount) / Double(max(1, daysLeft)) }
    }

    var cashAccounts: [Account] { snapshot.accounts.filter(\.isSpendableCash) }
    var savingsAccounts: [Account] { snapshot.accounts.filter(\.isSavings) }
    var creditAccounts: [Account] { snapshot.accounts.filter(\.isCredit) }

    /// What's left to spend through the end of the month: spendable cash plus
    /// paychecks still coming, minus everything already owed on cards (so no
    /// card ever carries a balance), unpaid bills, and the savings goal.
    var safeToSpend: SafeToSpend {
        let events = upcomingIncome(through: monthEnd)
        return SafeToSpend(
            cash: cashAccounts.reduce(0) { $0 + $1.balance },
            expectedIncome: events.reduce(0) { $0 + $1.amount },
            incomeEvents: events,
            creditCardBalances: creditAccounts.reduce(0) { $0 + max(0, $1.balance) },
            billsRemaining: billsRemaining,
            savingsGoal: monthlySavingsGoal,
            daysLeft: Day.daysLeftInMonth(today)
        )
    }

    func upcomingIncome(through end: Date) -> [IncomeEvent] {
        let startOfToday = cal.startOfDay(for: today)
        var events: [IncomeEvent] = []
        for stream in snapshot.recurring where stream.isIncome && stream.isActive {
            let last = Day.parse(stream.lastDate)
            var next = stream.predictedNextDate.map(Day.parse) ?? advance(last, by: stream.frequency)
            // A paycheck that landed today is already in the balance.
            while let date = next, date <= end {
                if date >= startOfToday && date > last {
                    events.append(IncomeEvent(name: stream.displayName, date: Day.string(date), amount: stream.averageAmount))
                }
                next = advance(date, by: stream.frequency)
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    private func advance(_ date: Date, by frequency: String) -> Date? {
        switch frequency {
        case "WEEKLY": return cal.date(byAdding: .day, value: 7, to: date)
        case "BIWEEKLY": return cal.date(byAdding: .day, value: 14, to: date)
        case "SEMI_MONTHLY": return cal.date(byAdding: .day, value: 15, to: date)
        case "MONTHLY": return cal.date(byAdding: .month, value: 1, to: date)
        case "ANNUALLY": return cal.date(byAdding: .year, value: 1, to: date)
        default: return nil
        }
    }

    // MARK: Credit cards

    struct CardPlan: Identifiable, Hashable {
        var account: Account
        var currentBalance: Double
        var statementBalance: Double?
        /// What's still owed on the last statement. Pay this by the due date to avoid interest.
        var payToAvoidInterest: Double
        var dueDate: Date?
        /// Charges since the statement closed; due on the next statement.
        var newSpending: Double
        var minimumPayment: Double?
        var apr: Double?
        var isOverdue: Bool
        var id: String { account.id }
    }

    var cardPlans: [CardPlan] {
        creditAccounts.map { account in
            let card = snapshot.creditCards.first { $0.accountId == account.id }
            let balance = max(0, account.balance)
            var owedOnStatement = balance
            if let card, let statement = card.lastStatementBalance {
                var paid = 0.0
                if let paidOn = card.lastPaymentDate, let closed = card.lastStatementDate, paidOn >= closed {
                    paid = card.lastPaymentAmount ?? 0
                }
                owedOnStatement = min(balance, max(0, statement - paid))
            }
            return CardPlan(
                account: account,
                currentBalance: balance,
                statementBalance: card?.lastStatementBalance,
                payToAvoidInterest: owedOnStatement,
                dueDate: card?.nextPaymentDueDate.map(Day.parse),
                newSpending: max(0, balance - owedOnStatement),
                minimumPayment: card?.minimumPayment,
                apr: card?.purchaseApr,
                isOverdue: card?.isOverdue ?? false
            )
        }
        .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    // MARK: Chat context

    /// The snapshot Claude sees. Kept compact: recent transactions only, and
    /// totals instead of raw history for older months.
    func chatContext() -> ChatContext {
        let safe = safeToSpend
        let accountName = Dictionary(snapshot.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let recentCutoff = cal.date(byAdding: .day, value: -60, to: today)!

        var monthly: [String: [String: Double]] = [:]
        for t in snapshot.transactions {
            guard let id = BudgetCategory.categoryId(for: t) else { continue }
            let month = String(t.date.prefix(7))
            monthly[month, default: [:]][name(of: id), default: 0] += t.amount
        }

        return ChatContext(
            today: Day.string(today),
            daysLeftInMonth: safe.daysLeft,
            conventions: "Transaction amounts: positive = money spent, negative = money received. Credit card balances are amounts owed.",
            safeToSpend: ChatContext.Safe(
                amount: safe.amount.rounded2,
                perDay: safe.perDay.rounded2,
                spendableCash: safe.cash.rounded2,
                expectedIncomeBeforeMonthEnd: safe.expectedIncome.rounded2,
                incomeEvents: safe.incomeEvents,
                minusCreditCardBalances: safe.creditCardBalances.rounded2,
                minusUnpaidBillsThisMonth: safe.billsRemaining.rounded2,
                minusMonthlySavingsGoal: safe.savingsGoal.rounded2,
                method: "spendable cash + income expected before month end - full current balance of every credit card - budgeted bills not yet paid this month - savings goal"
            ),
            accounts: snapshot.accounts.map {
                ChatContext.AccountLine(name: $0.displayName, institution: $0.institution, type: $0.subtype ?? $0.type,
                      balance: $0.balance.rounded2, creditLimit: $0.limit)
            },
            creditCards: cardPlans.map {
                ChatContext.Card(name: $0.account.displayName, currentBalance: $0.currentBalance.rounded2,
                      statementBalance: $0.statementBalance, payToAvoidInterest: $0.payToAvoidInterest.rounded2,
                      dueDate: $0.dueDate.map(Day.string), newSpendingSinceStatement: $0.newSpending.rounded2,
                      minimumPayment: $0.minimumPayment, purchaseApr: $0.apr, isOverdue: $0.isOverdue)
            },
            budgetThisMonth: budgets.filter { $0.monthlyAmount > 0 || spent(in: $0.id) > 0 }.map {
                let used = spent(in: $0.id)
                return ChatContext.BudgetLine(category: $0.name, kind: $0.isFixed ? "bill" : "flexible",
                                              monthlyBudget: $0.monthlyAmount, spent: used.rounded2,
                                              remaining: ($0.monthlyAmount - used).rounded2)
            },
            spendingByMonth: monthly.keys.sorted().suffix(6).map { month in
                ChatContext.MonthTotal(month: month, total: monthly[month]!.values.reduce(0, +).rounded2,
                      byCategory: monthly[month]!.mapValues(\.rounded2))
            },
            recurring: snapshot.recurring.filter(\.isActive).map {
                ChatContext.Recurring(name: $0.displayName, direction: $0.direction == "inflow" ? "income" : "bill",
                      averageAmount: $0.averageAmount.rounded2, frequency: $0.frequency.lowercased(),
                      lastDate: $0.lastDate, nextDate: $0.predictedNextDate)
            },
            recentTransactions: snapshot.transactions
                .filter { $0.day >= recentCutoff }
                .prefix(300)
                .map {
                    ChatContext.Txn(date: $0.date, name: $0.displayName, amount: $0.amount.rounded2,
                          category: BudgetCategory.categoryId(for: $0).map(name(of:)) ?? $0.category.lowercased(),
                          account: accountName[$0.accountId] ?? "", pending: $0.pending)
                }
        )
    }

    private func name(of categoryId: String) -> String {
        budgets.first { $0.id == categoryId }?.name ?? categoryId
    }
}

struct ChatContext: Encodable {
    struct Safe: Encodable {
        var amount, perDay, spendableCash, expectedIncomeBeforeMonthEnd: Double
        var incomeEvents: [BudgetEngine.IncomeEvent]
        var minusCreditCardBalances, minusUnpaidBillsThisMonth, minusMonthlySavingsGoal: Double
        var method: String
    }
    struct AccountLine: Encodable {
        var name, institution, type: String
        var balance: Double
        var creditLimit: Double?
    }
    struct Card: Encodable {
        var name: String
        var currentBalance: Double
        var statementBalance: Double?
        var payToAvoidInterest: Double
        var dueDate: String?
        var newSpendingSinceStatement: Double
        var minimumPayment, purchaseApr: Double?
        var isOverdue: Bool
    }
    struct BudgetLine: Encodable {
        var category, kind: String
        var monthlyBudget, spent, remaining: Double
    }
    struct MonthTotal: Encodable {
        var month: String
        var total: Double
        var byCategory: [String: Double]
    }
    struct Recurring: Encodable {
        var name, direction: String
        var averageAmount: Double
        var frequency, lastDate: String
        var nextDate: String?
    }
    struct Txn: Encodable {
        var date, name: String
        var amount: Double
        var category, account: String
        var pending: Bool
    }

    var today: String
    var daysLeftInMonth: Int
    var conventions: String
    var safeToSpend: Safe
    var accounts: [AccountLine]
    var creditCards: [Card]
    var budgetThisMonth: [BudgetLine]
    var spendingByMonth: [MonthTotal]
    var recurring: [Recurring]
    var recentTransactions: [Txn]
}

extension Double {
    var rounded2: Double { (self * 100).rounded() / 100 }
}
