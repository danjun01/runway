import Foundation

/// Pure budgeting math over a snapshot. No networking, no UI, so it's easy to
/// reason about and to test.
struct BudgetEngine {
    var snapshot: Snapshot
    var budgets: [BudgetCategory]
    /// Money to set aside each month before anything counts as spendable.
    var monthlySavingsGoal: Double
    var today: Date = .now
    /// Income sources the user confirmed, edited, ignored, or added. Detected
    /// sources fill in the rest (see Income.swift).
    var savedIncome: [IncomeSource] = []
    /// Merchant key -> bucket id, from "move to bucket".
    var bucketRules: [String: String] = [:]

    var cal: Calendar { Day.calendar }
    var monthStart: Date { Day.startOfMonth(today) }
    var monthEnd: Date { Day.endOfMonth(today) }
    var startOfToday: Date { cal.startOfDay(for: today) }

    // MARK: Spending

    func bucketId(for t: Transaction) -> String? {
        BudgetCategory.bucketId(for: t, rules: bucketRules, budgets: budgets)
    }

    var spendingThisMonth: [Transaction] {
        snapshot.transactions.filter { t in
            t.day >= monthStart && t.day <= monthEnd && bucketId(for: t) != nil
        }
    }

    func spent(in categoryId: String) -> Double {
        spendingThisMonth
            .filter { bucketId(for: $0) == categoryId }
            .reduce(0) { $0 + $1.amount }
    }

    func transactions(in categoryId: String) -> [Transaction] {
        spendingThisMonth.filter { bucketId(for: $0) == categoryId }
    }

    var totalBudgeted: Double { budgets.reduce(0) { $0 + $1.monthlyAmount } }
    var totalSpent: Double { spendingThisMonth.reduce(0) { $0 + $1.amount } }

    /// Fixed bills you've budgeted for but haven't paid yet this month.
    var billsRemaining: Double {
        budgets.filter(\.isFixed).reduce(0) { $0 + max(0, $1.monthlyAmount - spent(in: $1.id)) }
    }

    // MARK: Suggested budget

    /// Average monthly spend per bucket over up to the last 90 days of
    /// history, rounded up to the nearest $10.
    func suggestedBudgets() -> [BudgetCategory] {
        let windowStart = cal.date(byAdding: .day, value: -90, to: startOfToday)!
        let history = snapshot.transactions.filter { $0.day >= windowStart && $0.day < startOfToday }
        guard let earliest = history.map(\.day).min() else { return budgets }
        let days = max(14, cal.dateComponents([.day], from: earliest, to: today).day ?? 30)
        let months = Double(days) / 30.4

        var totals: [String: Double] = [:]
        for t in history {
            guard let id = bucketId(for: t) else { continue }
            totals[id, default: 0] += t.amount
        }
        return budgets.map { category in
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
        /// Paychecks projected to land between now and month end. Not in the account yet.
        var expectedIncome: Double
        var incomeEvents: [IncomeEvent]
        var creditCardBalances: Double
        var billsRemaining: Double
        var savingsGoal: Double
        var daysLeft: Int

        var amount: Double { cash + expectedIncome - creditCardBalances - billsRemaining - savingsGoal }
        var perDay: Double { max(0, amount) / Double(max(1, daysLeft)) }
        /// The same number if no more paychecks came this month: what's backed by money you already have.
        var inHand: Double { amount - expectedIncome }
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

    /// Paychecks from counted income sources that haven't arrived yet, from
    /// today (or a few days ago, if one is running late) through `end`.
    func upcomingIncome(through end: Date) -> [IncomeEvent] {
        expectedPaychecks(through: end).map {
            IncomeEvent(name: $0.name, date: Day.string($0.date), amount: $0.amount)
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
        /// Where the money to pay `payToAvoidInterest` by the due date comes from.
        var funding: CardFunding = .nothingDue
        var id: String { account.id }
    }

    enum CardFunding: Hashable {
        case nothingDue
        /// Checking already covers it.
        case cashOnHand
        /// Covered once the paycheck projected for this date arrives.
        case paycheck(Date)
        /// Not covered by cash plus paychecks due before the card is.
        case short(Double)
    }

    var cardPlans: [CardPlan] {
        let plans = creditAccounts.map { account in
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
        return fundCards(plans)
    }

    /// Pays statements in due-date order, first from cash in checking, then
    /// from paychecks projected to land before each due date.
    private func fundCards(_ plans: [CardPlan]) -> [CardPlan] {
        var cash = max(0, cashAccounts.reduce(0) { $0 + $1.balance })
        var paychecks = expectedPaychecks(through: plans.compactMap(\.dueDate).max() ?? monthEnd)
            .map { (date: $0.date, left: $0.amount) }
        return plans.map { plan in
            var plan = plan
            var need = plan.payToAvoidInterest
            guard need > 0.005 else { return plan }
            let fromCash = min(cash, need)
            cash -= fromCash
            need -= fromCash
            var lastPaycheck: Date?
            for i in paychecks.indices where need > 0.005 && paychecks[i].left > 0 {
                guard paychecks[i].date <= (plan.dueDate ?? monthEnd) else { break }
                let take = min(paychecks[i].left, need)
                paychecks[i].left -= take
                need -= take
                lastPaycheck = paychecks[i].date
            }
            if need > 0.005 {
                plan.funding = .short(need)
            } else if let lastPaycheck {
                plan.funding = .paycheck(lastPaycheck)
            } else {
                plan.funding = .cashOnHand
            }
            return plan
        }
    }

    // MARK: Chat context

    /// The snapshot Claude sees. Kept compact: recent transactions only, and
    /// totals instead of raw history for older months.
    func chatContext() -> ChatContext {
        let safe = safeToSpend
        let plan = self.plan
        let accountName = Dictionary(snapshot.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let recentCutoff = cal.date(byAdding: .day, value: -60, to: today)!

        var monthly: [String: [String: Double]] = [:]
        for t in snapshot.transactions {
            guard let id = bucketId(for: t) else { continue }
            let month = String(t.date.prefix(7))
            monthly[month, default: [:]][name(of: id), default: 0] += t.amount
        }

        return ChatContext(
            today: Day.string(today),
            daysLeftInMonth: safe.daysLeft,
            conventions: "Transaction amounts: positive = money spent, negative = money received. Credit card balances are amounts owed. \"Arrived\" income is already in the account; \"expected\" income is projected from the user's pay schedule and is not in the account yet.",
            safeToSpend: ChatContext.Safe(
                amount: safe.amount.rounded2,
                perDay: safe.perDay.rounded2,
                spendableCash: safe.cash.rounded2,
                expectedIncomeBeforeMonthEnd: safe.expectedIncome.rounded2,
                incomeEvents: safe.incomeEvents,
                minusCreditCardBalances: safe.creditCardBalances.rounded2,
                minusUnpaidBillsThisMonth: safe.billsRemaining.rounded2,
                minusMonthlySavingsGoal: safe.savingsGoal.rounded2,
                backedByMoneyInHand: safe.inHand.rounded2,
                method: "spendable cash + projected paychecks before month end - full current balance of every credit card - assigned bills not yet paid this month - savings goal. backedByMoneyInHand is the same without the projected paychecks."
            ),
            income: ChatContext.Income(
                sources: incomeSources.map { source in
                    ChatContext.IncomeLine(
                        name: source.name,
                        status: Self.describe(source.status),
                        amountPerPaycheck: source.amount.rounded2, frequency: source.frequency.label.lowercased(),
                        nextPayday: nextPayday(of: source).map(Day.string), monthlyEstimate: source.monthlyEstimate.rounded2)
                },
                thisMonth: plan.paychecks.map {
                    ChatContext.PaycheckLine(name: $0.name, date: Day.string($0.date), amount: $0.amount.rounded2,
                                             state: Self.describe($0.state))
                }
            ),
            plan: ChatContext.PlanInfo(
                incomeArrivedThisMonth: plan.arrived.rounded2,
                incomeExpectedRestOfMonth: plan.expected.rounded2,
                savingsGoal: plan.savingsGoal.rounded2,
                totalAssigned: plan.assigned.rounded2,
                leftToAssign: plan.leftToAssign.rounded2,
                method: "Zero-based monthly plan. This month's income (arrived + expected) is assigned to the savings goal, then bills, then flexible buckets, in that order; arrived money backs the earliest assignments and the rest waits on projected paychecks.",
                buckets: plan.buckets.filter { $0.assigned > 0 || $0.spent > 0 }.map {
                    ChatContext.BucketLine(bucket: $0.category.name, kind: $0.category.isFixed ? "bill" : "flexible",
                                           assigned: $0.assigned, spent: $0.spent.rounded2, available: $0.available.rounded2,
                                           backedByArrivedIncome: $0.fromArrived.rounded2,
                                           waitingOnProjectedIncome: $0.fromExpected.rounded2,
                                           waitingOnPaycheckDate: $0.waitingOn.map(Day.string))
                }
            ),
            accounts: snapshot.accounts.map {
                ChatContext.AccountLine(name: $0.displayName, institution: $0.institution, type: $0.subtype ?? $0.type,
                      balance: $0.balance.rounded2, creditLimit: $0.limit)
            },
            creditCards: cardPlans.map {
                ChatContext.Card(name: $0.account.displayName, currentBalance: $0.currentBalance.rounded2,
                      statementBalance: $0.statementBalance, payToAvoidInterest: $0.payToAvoidInterest.rounded2,
                      dueDate: $0.dueDate.map(Day.string), newSpendingSinceStatement: $0.newSpending.rounded2,
                      minimumPayment: $0.minimumPayment, purchaseApr: $0.apr, isOverdue: $0.isOverdue,
                      statementCoveredBy: Self.describe($0.funding))
            },
            spendingByMonth: monthly.keys.sorted().suffix(6).map { month in
                ChatContext.MonthTotal(month: month, total: monthly[month]!.values.reduce(0, +).rounded2,
                      byCategory: monthly[month]!.mapValues(\.rounded2))
            },
            recurringBills: snapshot.recurring.filter { $0.isActive && $0.direction == "outflow" }.map {
                ChatContext.Recurring(name: $0.displayName, averageAmount: $0.averageAmount.rounded2,
                      frequency: $0.frequency.lowercased(), lastDate: $0.lastDate, nextDate: $0.predictedNextDate)
            },
            recentTransactions: snapshot.transactions
                .filter { $0.day >= recentCutoff }
                .prefix(300)
                .map {
                    ChatContext.Txn(date: $0.date, name: $0.displayName, amount: $0.amount.rounded2,
                          category: bucketId(for: $0).map(name(of:)) ?? $0.category.lowercased(),
                          account: accountName[$0.accountId] ?? "", pending: $0.pending)
                }
        )
    }

    private static func describe(_ status: IncomeSource.Status) -> String {
        switch status {
        case .confirmed: "confirmed by user"
        case .detected: "auto-detected, counted"
        case .suggested: "possible income, not counted until the user confirms it"
        case .ignored: "user said this is not income, not counted"
        }
    }

    private static func describe(_ state: Paycheck.State) -> String {
        switch state {
        case .arrived: "arrived"
        case .expected: "expected (projected, not in the account yet)"
        case .missed: "was expected but hasn't arrived (not counted)"
        }
    }

    private static func describe(_ funding: CardFunding) -> String {
        switch funding {
        case .nothingDue: "nothing due"
        case .cashOnHand: "cash already in checking"
        case .paycheck(let date): "projected paycheck on \(Day.string(date)) (not arrived yet)"
        case .short(let amount): "short by \(amount.rounded2) even counting paychecks before the due date"
        }
    }

    func name(of categoryId: String) -> String {
        budgets.first { $0.id == categoryId }?.name ?? categoryId
    }
}

struct ChatContext: Encodable {
    struct Safe: Encodable {
        var amount, perDay, spendableCash, expectedIncomeBeforeMonthEnd: Double
        var incomeEvents: [BudgetEngine.IncomeEvent]
        var minusCreditCardBalances, minusUnpaidBillsThisMonth, minusMonthlySavingsGoal: Double
        var backedByMoneyInHand: Double
        var method: String
    }
    struct Income: Encodable {
        var sources: [IncomeLine]
        var thisMonth: [PaycheckLine]
    }
    struct IncomeLine: Encodable {
        var name, status: String
        var amountPerPaycheck: Double
        var frequency: String
        var nextPayday: String?
        var monthlyEstimate: Double
    }
    struct PaycheckLine: Encodable {
        var name, date: String
        var amount: Double
        var state: String
    }
    struct PlanInfo: Encodable {
        var incomeArrivedThisMonth, incomeExpectedRestOfMonth, savingsGoal, totalAssigned, leftToAssign: Double
        var method: String
        var buckets: [BucketLine]
    }
    struct BucketLine: Encodable {
        var bucket, kind: String
        var assigned, spent, available, backedByArrivedIncome, waitingOnProjectedIncome: Double
        var waitingOnPaycheckDate: String?
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
        var statementCoveredBy: String
    }
    struct MonthTotal: Encodable {
        var month: String
        var total: Double
        var byCategory: [String: Double]
    }
    struct Recurring: Encodable {
        var name: String
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
    var income: Income
    var plan: PlanInfo
    var accounts: [AccountLine]
    var creditCards: [Card]
    var spendingByMonth: [MonthTotal]
    var recurringBills: [Recurring]
    var recentTransactions: [Txn]
}

extension Double {
    var rounded2: Double { (self * 100).rounded() / 100 }
}
