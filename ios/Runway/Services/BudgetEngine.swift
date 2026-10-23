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

    // MARK: Bills

    struct UpcomingBill: Identifiable, Hashable {
        var streamId: String
        var name: String
        var date: Date
        var amount: Double
        var accountId: String
        /// The bucket this bill falls in, if any.
        var bucketId: String?
        var id: String { "\(streamId)-\(Day.string(date))" }
    }

    /// Every bill Plaid expects between today and month end that hasn't been
    /// charged yet. A bill that's a few days late still counts, as due today.
    var upcomingBills: [UpcomingBill] {
        snapshot.recurring.filter(\.isBill).flatMap { stream in
            remainingOccurrences(of: stream, overdueGraceDays: 7).map { date in
                UpcomingBill(streamId: stream.id, name: stream.displayName, date: date,
                             amount: max(stream.averageAmount, stream.lastAmount), accountId: stream.accountId,
                             bucketId: bucket(ofStream: stream))
            }
        }
        .sorted { ($0.date, $0.name) < ($1.date, $1.name) }
    }

    private func bucket(ofStream stream: RecurringStream) -> String? {
        if let id = bucketRules[MerchantKey.of(stream.displayName)], budgets.contains(where: { $0.id == id }) { return id }
        return BudgetCategory.categoryId(primary: stream.category ?? "OTHER", detailed: stream.detailedCategory)
    }

    /// What's left in bill buckets where Plaid hasn't found any recurring bill,
    /// so a bill it can't see (rent paid by check, say) still gets set aside.
    /// Where Plaid does track bills, its dates and amounts win: the assigned
    /// amount may be an average of past months and would set aside money for
    /// bills that aren't coming.
    var budgetedBillsNotDetected: Double {
        let tracked = Set(snapshot.recurring.filter(\.isBill).compactMap(bucket(ofStream:)))
        return budgets.filter { $0.isFixed && !tracked.contains($0.id) }.reduce(0) {
            $0 + max(0, $1.monthlyAmount - spent(in: $1.id))
        }
    }

    /// Bills still to pay this month: detected bills plus assigned ones Plaid isn't tracking.
    var billsRemaining: Double {
        upcomingBills.reduce(0) { $0 + $1.amount } + budgetedBillsNotDetected
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
        /// Everything owed on cards, pending charges included.
        var creditCardBalances: Double
        /// The part of `creditCardBalances` that's still pending.
        var pendingCardCharges: Double
        var billsRemaining: Double
        var savingsGoal: Double
        var daysLeft: Int
        var lowPoint: LowPoint

        var amount: Double { cash + expectedIncome - creditCardBalances - billsRemaining - savingsGoal }
        var perDay: Double { max(0, amount) / Double(max(1, daysLeft)) }
        /// The same number if no more paychecks came this month: what's backed by money you already have.
        var inHand: Double { amount - expectedIncome }

        /// What you can spend from checking right now without it going negative
        /// before the paychecks that make up the rest of the month's number.
        var spendableNow: Double { max(0, min(amount, lowPoint.balance)) }

        /// True when the month adds up but not all of it is available yet.
        var isTimingLimited: Bool { amount > 0 && lowPoint.balance < amount }
    }

    var cashAccounts: [Account] { snapshot.accounts.filter(\.isSpendableCash) }
    var savingsAccounts: [Account] { snapshot.accounts.filter(\.isSavings) }
    var creditAccounts: [Account] { snapshot.accounts.filter(\.isCredit) }

    /// What's left to spend through the end of the month: spendable cash plus
    /// paychecks still coming, minus everything already owed on cards (so no
    /// card ever carries a balance), unpaid bills, and the savings goal.
    var safeToSpend: SafeToSpend {
        let events = upcomingIncome(through: monthEnd)
        let bills = upcomingBills
        let plans = cardPlans
        let cash = spendableCash
        return SafeToSpend(
            cash: cash,
            expectedIncome: events.reduce(0) { $0 + $1.amount },
            incomeEvents: events,
            creditCardBalances: plans.reduce(0) { $0 + $1.reserved },
            pendingCardCharges: plans.reduce(0) { $0 + $1.pendingCharges },
            billsRemaining: bills.reduce(0) { $0 + $1.amount } + budgetedBillsNotDetected,
            savingsGoal: monthlySavingsGoal,
            daysLeft: Day.daysLeftInMonth(today),
            lowPoint: checkingLowPoint(cash: cash, income: events, bills: bills, cards: plans)
        )
    }

    var spendableCash: Double { cashAccounts.reduce(0) { $0 + spendable($1) } }

    /// Spendable money in a checking-like account. The available balance already
    /// reflects pending debits; when a bank doesn't report one, take them off the
    /// current balance.
    func spendable(_ account: Account) -> Double {
        if let available = account.availableBalance { return available }
        return (account.currentBalance ?? 0) - pendingCharges(on: account)
    }

    private func pendingCharges(on account: Account) -> Double {
        snapshot.transactions
            .filter { $0.accountId == account.id && $0.pending && $0.amount > 0 }
            .reduce(0) { $0 + $1.amount }
    }

    /// Paychecks from counted income sources that haven't arrived yet, from
    /// today (or a few days ago, if one is running late) through `end`.
    func upcomingIncome(through end: Date) -> [IncomeEvent] {
        expectedPaychecks(through: end).map {
            IncomeEvent(name: $0.name, date: Day.string($0.date), amount: $0.amount)
        }
    }

    // MARK: Recurring dates

    /// Dates a recurring stream is still expected to hit, from today through
    /// month end. Occurrences up to `overdueGraceDays` late count as today. An
    /// occurrence is skipped when a matching transaction has already shown up:
    /// Plaid can take a day or more to attach new transactions to a stream, and
    /// counting it again would double it (a bill already on a card).
    private func remainingOccurrences(of stream: RecurringStream, overdueGraceDays: Int) -> [Date] {
        let earliest = cal.date(byAdding: .day, value: -overdueGraceDays, to: startOfToday)!
        let last = Day.parse(stream.lastDate)
        let key = MerchantKey.of(stream.displayName)
        var unattached = snapshot.transactions
            .filter { t in
                t.day > last && t.day <= startOfToday && t.accountId == stream.accountId
                    && (t.amount < 0) == (stream.direction == "inflow") && !key.isEmpty
                    && MerchantKey.matches(MerchantKey.of(t.displayName), key)
            }
            .map(\.day)
            .sorted()

        var dates: [Date] = []
        var next = stream.predictedNextDate.map(Day.parse) ?? advance(last, by: stream.frequency)
        while let date = next, date <= monthEnd {
            if date > last {
                // The matching transaction may land a little early or late.
                let window = cal.date(byAdding: .day, value: -10, to: date)!
                if let i = unattached.firstIndex(where: { $0 >= window }) {
                    unattached.remove(at: i)
                } else if date >= earliest {
                    dates.append(max(date, startOfToday))
                }
            }
            next = advance(date, by: stream.frequency)
        }
        return dates
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

    // MARK: Timing

    struct LowPoint {
        /// The lowest checking is projected to go this month, before any spending you choose.
        var balance: Double
        var date: Date
        /// What's due that day, e.g. "Sapphire Preferred ••9934 payment".
        var cause: String?
        /// The next paycheck after the low point, when the rest of the month's money arrives.
        var nextPaycheck: Date?
    }

    /// Walks checking forward day by day through month end using only what's
    /// already committed: paychecks in; bills paid from checking and card
    /// statement payments (by their due dates) out. Bills charged to a card are
    /// paid with next month's statement, so they don't touch checking this month.
    /// Assigned bills Plaid isn't tracking have no date, so they're left to the
    /// monthly number rather than guessed at here. Same-day money out is counted
    /// before money in, since a deposit can land later in the day than a charge.
    private func checkingLowPoint(cash: Double, income: [IncomeEvent], bills: [UpcomingBill],
                                  cards: [CardPlan]) -> LowPoint {
        let creditIds = Set(creditAccounts.map(\.id))
        var flows: [(date: Date, amount: Double, label: String?)] = []
        for bill in bills where !creditIds.contains(bill.accountId) {
            flows.append((bill.date, -bill.amount, bill.name))
        }
        // Only cards whose bank reports a due date; a past due date means it's due now.
        for card in cards where card.payToAvoidInterest > 0 {
            guard let dueDate = card.dueDate else { continue }
            let due = max(dueDate, startOfToday)
            if due <= monthEnd { flows.append((due, -card.payToAvoidInterest, "\(card.account.displayName) payment")) }
        }
        for event in income { flows.append((Day.parse(event.date), event.amount, nil)) }
        flows.sort { ($0.date, $0.amount) < ($1.date, $1.amount) }

        var balance = cash
        var low = LowPoint(balance: cash, date: startOfToday)
        for flow in flows {
            balance += flow.amount
            if balance < low.balance { low = LowPoint(balance: balance, date: flow.date, cause: flow.label) }
        }
        low.nextPaycheck = income.map { Day.parse($0.date) }.first { $0 > low.date }
        return low
    }

    // MARK: Can I afford it?

    enum Affordability: Equatable {
        /// Yes, with this much left for the rest of the month.
        case yes(left: Double, perDay: Double)
        /// It fits this month, but checking would go negative if spent before this paycheck.
        case afterPaycheck(Date, spendableNow: Double)
        /// It doesn't fit this month; this is how much it's over by.
        case no(over: Double)
    }

    func canAfford(_ cost: Double) -> Affordability {
        let safe = safeToSpend
        if cost > safe.amount { return .no(over: cost - max(0, safe.amount)) }
        if cost > safe.spendableNow {
            guard let payday = safe.lowPoint.nextPaycheck else { return .no(over: cost - safe.spendableNow) }
            return .afterPaycheck(payday, spendableNow: safe.spendableNow)
        }
        let left = safe.amount - cost
        return .yes(left: left, perDay: left / Double(max(1, safe.daysLeft)))
    }

    // MARK: Credit cards

    struct CardPlan: Identifiable, Hashable {
        var account: Account
        /// Posted balance, as the bank reports it.
        var currentBalance: Double
        /// Charges still pending that the bank's balance doesn't include yet.
        var pendingCharges: Double = 0
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

        /// What safe-to-spend sets aside for this card.
        var reserved: Double { currentBalance + pendingCharges }
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
                pendingCharges: pendingNotInBalance(account),
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

    /// Pending charges on a card that its balance doesn't include yet. Most banks
    /// leave pending charges out of the balance but take them off available
    /// credit, so when the card reports a limit and available credit, the gap
    /// between those and the balance shows how much is already counted. Without
    /// them, assume none of it is.
    private func pendingNotInBalance(_ account: Account) -> Double {
        let pending = pendingCharges(on: account)
        guard pending > 0 else { return 0 }
        if let limit = account.limit, let available = account.availableBalance, limit > 0 {
            let uncounted = limit - available - (account.currentBalance ?? 0)
            return min(pending, max(0, uncounted))
        }
        return pending
    }

    /// Pays statements in due-date order, first from cash in checking, then
    /// from paychecks projected to land before each due date.
    private func fundCards(_ plans: [CardPlan]) -> [CardPlan] {
        var cash = max(0, spendableCash)
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
                ofWhichPendingCardCharges: safe.pendingCardCharges.rounded2,
                minusUnpaidBillsThisMonth: safe.billsRemaining.rounded2,
                minusMonthlySavingsGoal: safe.savingsGoal.rounded2,
                backedByMoneyInHand: safe.inHand.rounded2,
                upcomingBills: upcomingBills.map {
                    ChatContext.Bill(name: $0.name, date: Day.string($0.date), amount: $0.amount.rounded2,
                                     account: accountName[$0.accountId] ?? "")
                },
                lowestCheckingBalanceThisMonth: safe.lowPoint.balance.rounded2,
                lowestCheckingBalanceDate: Day.string(safe.lowPoint.date),
                lowestCheckingBalanceCause: safe.lowPoint.cause,
                spendableBeforeNextPaycheck: safe.spendableNow.rounded2,
                method: "spendable cash (available balance, so pending debits are out) + projected paychecks before month end - full balance of every credit card including pending charges - bills not yet paid this month (recurring bills Plaid detects, plus whatever is left in assigned bill buckets Plaid isn't tracking) - savings goal. backedByMoneyInHand is the same without the projected paychecks. Only spendableBeforeNextPaycheck can be spent now without checking going negative before the next paycheck."
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
        var minusCreditCardBalances, ofWhichPendingCardCharges, minusUnpaidBillsThisMonth, minusMonthlySavingsGoal: Double
        var backedByMoneyInHand: Double
        var upcomingBills: [Bill]
        var lowestCheckingBalanceThisMonth: Double
        var lowestCheckingBalanceDate: String
        var lowestCheckingBalanceCause: String?
        var spendableBeforeNextPaycheck: Double
        var method: String
    }
    struct Bill: Encodable {
        var name, date: String
        var amount: Double
        var account: String
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
