import Foundation

/// Longer-view numbers: how old your money is when you spend it, spending
/// month over month, and whether account balances add up.
extension BudgetEngine {

    // MARK: Age of money

    /// Roughly how many days a dollar sits in your accounts before you spend
    /// it: income is used first-in, first-out, and this is the average age of
    /// the money behind your last 10 purchases. Higher means more cushion.
    /// Nil until there are enough purchases to say.
    var ageOfMoney: Int? {
        let txns = snapshot.transactions.filter { !$0.pending }.sorted { $0.date < $1.date }
        let cashIds = Set(cashAccounts.map(\.id))
        func isInflow(_ t: Transaction) -> Bool { t.amount < 0 && t.category == "INCOME" && cashIds.contains(t.accountId) }
        func isOutflow(_ t: Transaction) -> Bool { t.amount > 0 && bucketId(for: t) != nil }
        guard let first = txns.first, txns.filter(isOutflow).count >= 10 else { return nil }

        // Money already in the accounts when the history starts.
        let cash = cashAccounts.reduce(0) { $0 + ($1.currentBalance ?? $1.balance) }
        let totalIn = txns.filter(isInflow).reduce(0) { $0 - $1.amount }
        let totalOut = txns.filter(isOutflow).reduce(0) { $0 + $1.amount }
        let opening = max(0, cash + totalOut - totalIn)

        var queue: [(date: Date, left: Double)] = opening > 0.005 ? [(first.day, opening)] : []
        var head = 0
        var ages: [Double] = []
        for t in txns {
            if isInflow(t) {
                queue.append((t.day, -t.amount))
            } else if isOutflow(t) {
                var need = t.amount, weighted = 0.0, covered = 0.0
                while need > 0.005 && head < queue.count {
                    let take = min(queue[head].left, need)
                    let days = Double(cal.dateComponents([.day], from: queue[head].date, to: t.day).day ?? 0)
                    weighted += take * days
                    covered += take
                    queue[head].left -= take
                    need -= take
                    if queue[head].left <= 0.005 { head += 1 }
                }
                if covered > 0 { ages.append(weighted / covered) }
            }
        }
        let recent = ages.suffix(10)
        guard recent.count == 10 else { return nil }
        return Int((recent.reduce(0, +) / 10).rounded())
    }

    // MARK: Trends

    struct MonthSpending: Identifiable, Hashable {
        var month: Date
        var total: Double
        var byBucket: [String: Double]
        var id: String { Day.monthKey(month) }
    }

    /// Spending per month, oldest first, ending with this month.
    func spendingHistory(months: Int = 6) -> [MonthSpending] {
        (0..<months).reversed().map { back in
            let month = Day.addMonths(-back, to: today)
            var byBucket: [String: Double] = [:]
            for t in spending(in: month) {
                for part in allocations(for: t) { byBucket[part.bucketId, default: 0] += part.amount }
            }
            return MonthSpending(month: month, total: byBucket.values.reduce(0, +), byBucket: byBucket)
        }
    }

    /// This month's spending per bucket next to its average over the three
    /// months before (only months that had any spending count).
    struct BucketTrend: Identifiable, Hashable {
        var category: BudgetCategory
        var thisMonth: Double
        var usual: Double
        var id: String { category.id }
    }

    func bucketTrends() -> [BucketTrend] {
        let history = spendingHistory(months: 4)
        guard let current = history.last else { return [] }
        let before = history.dropLast().filter { $0.total > 0 }
        return budgets.compactMap { category in
            let now = current.byBucket[category.id] ?? 0
            let usual = before.isEmpty ? 0 : before.reduce(0) { $0 + ($1.byBucket[category.id] ?? 0) } / Double(before.count)
            guard now > 0.5 || usual > 0.5 else { return nil }
            return BucketTrend(category: category, thisMonth: now, usual: usual)
        }
        .sorted { $0.thisMonth > $1.thisMonth }
    }
}

// MARK: Reconciling

/// An account's balance and the transactions Runway had for it at one sync.
struct BalanceCheckpoint: Codable, Equatable {
    var balance: Double
    var transactionIds: [String]
}

enum Reconcile {
    /// The bank balance is the truth. Starting from the last sync's balance,
    /// apply every newly posted transaction; whatever the bank's balance
    /// differs from that by is money Runway can't account for (a missing or
    /// duplicated transaction). Positive means the bank has more than expected.
    static func drift(since checkpoint: BalanceCheckpoint, account: Account, transactions: [Transaction]) -> Double {
        let known = Set(checkpoint.transactionIds)
        let new = transactions.filter { $0.accountId == account.id && !$0.pending && !known.contains($0.id) }
        let moved = new.reduce(0) { $0 + $1.amount }
        // Plaid amounts are positive when money leaves. That lowers cash and raises what's owed on a card.
        let expected = account.isCredit ? checkpoint.balance + moved : checkpoint.balance - moved
        return (account.currentBalance ?? account.balance) - expected
    }

    static func checkpoint(for account: Account, transactions: [Transaction]) -> BalanceCheckpoint {
        BalanceCheckpoint(balance: account.currentBalance ?? account.balance,
                          transactionIds: transactions.filter { $0.accountId == account.id && !$0.pending }.map(\.id))
    }
}
