import Foundation

/// Income detection, paycheck projection, and the monthly plan (assigning
/// arrived and expected income to buckets).
extension BudgetEngine {

    // MARK: Income sources

    /// Every income source: the user's saved ones first, then anything
    /// detected that the user hasn't touched yet.
    var incomeSources: [IncomeSource] {
        var result = savedIncome
        for source in detectedIncome() {
            let known = result.contains { $0.id == source.id || $0.streamId != nil && $0.streamId == source.streamId
                || MerchantKey.matches($0.matchKey, source.matchKey) }
            if !known { result.append(source) }
        }
        return result
    }

    var countedIncome: [IncomeSource] { incomeSources.filter(\.counts) }

    /// Detected but not yet confirmed or dismissed by the user.
    var unreviewedIncome: [IncomeSource] {
        incomeSources.filter { $0.status == .detected || $0.status == .suggested }
    }

    /// Plaid's recurring inflows, plus regular paychecks Runway spots in the
    /// transaction history itself (Plaid needs a few months before it reports
    /// streams, and sometimes misses one).
    func detectedIncome() -> [IncomeSource] {
        let creditIds = Set(creditAccounts.map(\.id))
        var found: [IncomeSource] = []
        for stream in snapshot.recurring where stream.direction == "inflow" && stream.isActive {
            guard let frequency = PayFrequency(plaid: stream.frequency), !creditIds.contains(stream.accountId),
                  stream.averageAmount >= 1 else { continue }
            found.append(IncomeSource(
                id: "plaid:\(stream.id)", name: stream.displayName, amount: stream.averageAmount.rounded2,
                frequency: frequency, anchorDate: stream.predictedNextDate ?? stream.lastDate,
                matchKey: MerchantKey.of(stream.displayName), status: stream.isIncome ? .detected : .suggested,
                streamId: stream.id))
        }
        for source in incomeFromHistory()
        where !found.contains(where: { MerchantKey.matches($0.matchKey, source.matchKey) }) {
            found.append(source)
        }
        return found
    }

    /// Groups income deposits by payer and keeps the ones that arrive on a
    /// steady weekly, biweekly, twice-monthly, or monthly rhythm.
    private func incomeFromHistory() -> [IncomeSource] {
        let windowStart = cal.date(byAdding: .day, value: -120, to: startOfToday)!
        let creditIds = Set(creditAccounts.map(\.id))
        let deposits = snapshot.transactions.filter {
            $0.amount < 0 && $0.category == "INCOME" && !creditIds.contains($0.accountId) && $0.day >= windowStart
        }
        let byPayer = Dictionary(grouping: deposits) { MerchantKey.of($0.displayName) }
        var result: [IncomeSource] = []
        for (key, txns) in byPayer where !key.isEmpty && txns.count >= 2 {
            let sorted = txns.sorted { $0.date < $1.date }
            let gaps = zip(sorted, sorted.dropFirst()).map { cal.dateComponents([.day], from: $0.day, to: $1.day).day ?? 0 }
            let gap = median(gaps.map(Double.init))
            let frequency: PayFrequency
            switch gap {
            case 5..<10: frequency = .weekly
            case 10..<20: frequency = gaps.allSatisfy { (13...15).contains($0) } ? .biweekly : .semiMonthly
            case 25..<36: frequency = .monthly
            default: continue
            }
            let last = sorted.last!
            result.append(IncomeSource(
                id: "history:\(key)", name: last.displayName,
                amount: median(sorted.suffix(3).map { -$0.amount }).rounded2,
                frequency: frequency, anchorDate: last.date, matchKey: key, status: .detected))
        }
        return result.sorted { $0.monthlyEstimate > $1.monthlyEstimate }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Paydays

    /// Scheduled paydays for a source between two dates, inclusive.
    func paydays(of source: IncomeSource, from start: Date, through end: Date) -> [Date] {
        let anchor = Day.parse(source.anchorDate)
        guard anchor != .distantPast, start <= end else { return [] }
        var dates: [Date] = []
        switch source.frequency {
        case .weekly, .biweekly:
            let step = source.frequency == .weekly ? 7 : 14
            let offset = cal.dateComponents([.day], from: anchor, to: start).day ?? 0
            let steps = Int((Double(offset) / Double(step)).rounded(.down))
            var date = cal.date(byAdding: .day, value: steps * step, to: anchor)!
            if date < start { date = cal.date(byAdding: .day, value: step, to: date)! }
            while date <= end {
                dates.append(date)
                date = cal.date(byAdding: .day, value: step, to: date)!
            }
        case .monthly, .semiMonthly:
            let anchorDay = cal.component(.day, from: anchor)
            let days = source.frequency == .monthly
                ? [anchorDay]
                : (anchorDay <= 15 ? [anchorDay, anchorDay + 15] : [anchorDay - 15, anchorDay])
            var month = Day.startOfMonth(start)
            while month <= end {
                let length = cal.range(of: .day, in: .month, for: month)?.count ?? 28
                for day in days {
                    let date = cal.date(byAdding: .day, value: min(day, length) - 1, to: month)!
                    if date >= start && date <= end { dates.append(date) }
                }
                month = cal.date(byAdding: .month, value: 1, to: month)!
            }
        }
        return dates
    }

    /// Deposits that belong to an income source.
    func deposits(of source: IncomeSource) -> [Transaction] {
        let creditIds = Set(creditAccounts.map(\.id))
        let streamIds = Set(snapshot.recurring.first { $0.id == source.streamId }?.transactionIds ?? [])
        return snapshot.transactions.filter { t in
            t.amount < 0 && !creditIds.contains(t.accountId)
                && (streamIds.contains(t.id) || MerchantKey.matches(MerchantKey.of(t.displayName), source.matchKey))
        }
    }

    /// Days a late paycheck still counts as expected before it's flagged missed.
    private var graceDays: Int { 3 }

    /// Every paycheck this month: arrived, still expected, or missed. Deposits
    /// are matched to scheduled paydays within a few days; a deposit with no
    /// payday nearby still counts as arrived. Income-category deposits from
    /// payers that aren't a source show up as "Other income".
    func paychecksThisMonth() -> [Paycheck] {
        var result: [Paycheck] = []
        var claimed = Set<String>()
        let ignored = incomeSources.filter { $0.status == .ignored }
        let graceStart = cal.date(byAdding: .day, value: -graceDays, to: startOfToday)!

        for source in countedIncome {
            var monthDeposits = deposits(of: source).filter {
                $0.day >= monthStart && $0.day <= monthEnd && !claimed.contains($0.id)
            }
            for payday in paydays(of: source, from: monthStart, through: monthEnd) {
                let window = source.frequency.matchWindowDays
                let match = monthDeposits.firstIndex { t in
                    abs(cal.dateComponents([.day], from: payday, to: t.day).day ?? 99) <= window
                }
                if let match {
                    let t = monthDeposits.remove(at: match)
                    claimed.insert(t.id)
                    result.append(Paycheck(sourceId: source.id, name: source.name, date: t.day, amount: -t.amount, state: .arrived))
                } else {
                    result.append(Paycheck(sourceId: source.id, name: source.name, date: payday, amount: source.amount,
                                           state: payday >= graceStart ? .expected : .missed))
                }
            }
            for t in monthDeposits {
                claimed.insert(t.id)
                result.append(Paycheck(sourceId: source.id, name: source.name, date: t.day, amount: -t.amount, state: .arrived))
            }
        }

        let creditIds = Set(creditAccounts.map(\.id))
        for t in snapshot.transactions where t.category == "INCOME" && t.amount < 0 && !claimed.contains(t.id)
            && t.day >= monthStart && t.day <= monthEnd && !creditIds.contains(t.accountId) {
            let key = MerchantKey.of(t.displayName)
            if ignored.contains(where: { MerchantKey.matches($0.matchKey, key) }) { continue }
            result.append(Paycheck(sourceId: "other", name: t.displayName, date: t.day, amount: -t.amount, state: .arrived))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Paychecks that haven't arrived yet, through `end` (which may be past
    /// this month, for card due dates early next month).
    func expectedPaychecks(through end: Date) -> [Paycheck] {
        var result = paychecksThisMonth().filter { $0.state == .expected && $0.date <= end }
        if end > monthEnd {
            let nextStart = cal.date(byAdding: .day, value: 1, to: monthEnd)!
            for source in countedIncome {
                for date in paydays(of: source, from: nextStart, through: end) {
                    result.append(Paycheck(sourceId: source.id, name: source.name, date: date, amount: source.amount, state: .expected))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    // MARK: Plan

    /// How one bucket's assigned money is backed: by income already in the
    /// account, or by paychecks still on the way.
    struct BucketFunding: Identifiable, Hashable {
        var category: BudgetCategory
        var assigned: Double
        var spent: Double
        var fromArrived: Double
        var fromExpected: Double
        /// The latest projected paycheck this bucket is waiting on.
        var waitingOn: Date?
        var available: Double { assigned - spent }
        var id: String { category.id }
    }

    /// This month's zero-based plan: income (arrived + expected) is assigned
    /// to the savings goal first, then bills, then flexible buckets, so the
    /// money that has actually landed backs the most important things.
    struct Plan {
        var paychecks: [Paycheck]
        var savingsGoal: Double
        var buckets: [BucketFunding]

        var arrived: Double { paychecks.filter { $0.state == .arrived }.reduce(0) { $0 + $1.amount } }
        var expected: Double { paychecks.filter { $0.state == .expected }.reduce(0) { $0 + $1.amount } }
        var income: Double { arrived + expected }
        var assigned: Double { buckets.reduce(0) { $0 + $1.assigned } }
        var leftToAssign: Double { income - savingsGoal - assigned }
        /// Assigned money (including savings) that's waiting on projected paychecks.
        var assignedFromExpected: Double { max(0, min(expected, savingsGoal + assigned - arrived)) }
    }

    var plan: Plan {
        let paychecks = paychecksThisMonth()
        var pools: [(date: Date?, left: Double)] = [(nil, paychecks.filter { $0.state == .arrived }.reduce(0) { $0 + $1.amount })]
        pools += paychecks.filter { $0.state == .expected }.map { (date: Optional($0.date), left: $0.amount) }

        func draw(_ amount: Double) -> (arrived: Double, expected: Double, last: Date?) {
            var need = amount, arrived = 0.0, expected = 0.0
            var last: Date?
            for i in pools.indices where need > 0.005 && pools[i].left > 0 {
                let take = min(pools[i].left, need)
                pools[i].left -= take
                need -= take
                if let date = pools[i].date {
                    expected += take
                    last = date
                } else {
                    arrived += take
                }
            }
            return (arrived, expected, last)
        }

        _ = draw(monthlySavingsGoal)
        let ordered = budgets.filter(\.isFixed) + budgets.filter { !$0.isFixed }
        let buckets = ordered.map { category in
            let source = draw(category.monthlyAmount)
            return BucketFunding(category: category, assigned: category.monthlyAmount, spent: spent(in: category.id),
                                 fromArrived: source.arrived, fromExpected: source.expected, waitingOn: source.last)
        }
        return Plan(paychecks: paychecks, savingsGoal: monthlySavingsGoal, buckets: buckets)
    }

    func funding(for categoryId: String) -> BucketFunding? {
        plan.buckets.first { $0.id == categoryId }
    }

    /// The next scheduled payday for a source, today or later.
    func nextPayday(of source: IncomeSource) -> Date? {
        paydays(of: source, from: startOfToday, through: cal.date(byAdding: .day, value: 62, to: startOfToday)!).first
    }
}
