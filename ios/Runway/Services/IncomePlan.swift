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
    func paychecksThisMonth() -> [Paycheck] { paychecks(in: monthStart) }

    /// The same for any month. Past months only have arrived and missed
    /// paychecks; future months are all expected.
    func paychecks(in month: Date) -> [Paycheck] {
        let monthStart = Day.startOfMonth(month)
        let monthEnd = Day.endOfMonth(month)
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

    /// How one bucket's money stands in a month: what rolled over from last
    /// month, what was assigned, what was spent, and how this month's
    /// assignment is backed (income already in the account, or paychecks
    /// still on the way).
    struct BucketFunding: Identifiable, Hashable {
        var category: BudgetCategory
        /// Unspent money from earlier months.
        var carried: Double = 0
        var assigned: Double
        var spent: Double
        var fromArrived: Double
        var fromExpected: Double
        /// The latest projected paycheck this bucket is waiting on.
        var waitingOn: Date?
        /// What the bucket's target asks for this month in total, and how
        /// much of that still needs assigning. Zero without a target.
        var targetThisMonth: Double = 0
        var targetRemaining: Double = 0
        /// What's left to spend. Negative means the bucket is overspent.
        var available: Double { carried + assigned - spent }
        /// Money the bucket had to spend this month.
        var funded: Double { carried + assigned }
        var isOverspent: Bool { available < -0.005 }
        var id: String { category.id }
    }

    /// A month's zero-based plan: income (arrived + expected) plus anything
    /// left unassigned last month is assigned to the savings goal first, then
    /// bills, then flexible buckets, so the money that has actually landed
    /// backs the most important things.
    struct Plan {
        var month: Date
        var paychecks: [Paycheck]
        var savingsGoal: Double
        /// Last month's left-to-assign. Negative when last month was over-assigned.
        var carriedOver: Double = 0
        /// Overspending in last month's buckets. It comes out of this month's money.
        var overspentLastMonth: Double = 0
        var buckets: [BucketFunding]

        var arrived: Double { paychecks.filter { $0.state == .arrived }.reduce(0) { $0 + $1.amount } }
        var expected: Double { paychecks.filter { $0.state == .expected }.reduce(0) { $0 + $1.amount } }
        var income: Double { arrived + expected }
        var assigned: Double { buckets.reduce(0) { $0 + $1.assigned } }
        /// Money from earlier months that's free to assign this month.
        var startingFunds: Double { carriedOver - overspentLastMonth }
        var leftToAssign: Double { income + startingFunds - savingsGoal - assigned }
        /// Assigned money (including savings) that's waiting on projected paychecks.
        var assignedFromExpected: Double {
            max(0, min(expected, savingsGoal + max(0, assigned) - arrived - max(0, startingFunds)))
        }
        var overspent: [BucketFunding] { buckets.filter(\.isOverspent) }
        /// Money still needed this month to keep every target on track.
        var targetsRemaining: Double { buckets.reduce(0) { $0 + $1.targetRemaining } }
    }

    var plan: Plan { plan(for: monthStart) }

    func plan(for month: Date) -> Plan {
        let month = Day.startOfMonth(month)
        let paychecks = self.paychecks(in: month)
        let roll = rollover(into: month)
        let starting = max(0, roll.unassigned - roll.overspent)
        var pools: [(date: Date?, left: Double)] = [(nil, starting + paychecks.filter { $0.state == .arrived }.reduce(0) { $0 + $1.amount })]
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
            let assigned = self.assigned(category.id, in: month)
            let source = draw(assigned)
            let carried = roll.carried[category.id] ?? 0
            let goal = targetThisMonth(category, carried: carried, month: month)
            return BucketFunding(category: category, carried: carried, assigned: assigned,
                                 spent: spent(in: category.id, month: month),
                                 fromArrived: source.arrived, fromExpected: source.expected, waitingOn: source.last,
                                 targetThisMonth: goal, targetRemaining: max(0, goal - assigned))
        }
        return Plan(month: month, paychecks: paychecks, savingsGoal: monthlySavingsGoal, carriedOver: roll.unassigned,
                    overspentLastMonth: roll.overspent, buckets: buckets)
    }

    // MARK: Targets

    /// What a bucket's target asks to be assigned in `month`, given what
    /// rolled into it. Saving up spreads what's still missing evenly over
    /// the months left, counting this one and the target month; a refill
    /// tops the bucket up to its amount.
    func targetThisMonth(_ category: BudgetCategory, carried: Double, month: Date) -> Double {
        guard let target = category.target, target.amount > 0 else { return 0 }
        switch target.kind {
        case .refill:
            return max(0, target.amount - carried)
        case .saveBy:
            guard let by = target.by else { return 0 }
            let key = Day.monthKey(month)
            guard key <= by else { return 0 }
            let months = (cal.dateComponents([.month], from: Day.startOfMonth(month), to: Day.month(by)).month ?? 0) + 1
            let missing = max(0, target.amount - carried)
            return (missing / Double(max(1, months)) * 100).rounded(.up) / 100
        }
    }

    // MARK: Months and rollover

    var currentMonthKey: String { Day.monthKey(today) }

    /// The budget's first month. Nothing rolls over from before it.
    var startMonthKey: String { min(budgetStart ?? currentMonthKey, currentMonthKey) }

    /// What's assigned to a bucket in a month. A month the user changed keeps
    /// its own amounts; otherwise the plan repeats the bucket's monthly amount.
    /// Past months are frozen by the app when they close, so a bucket missing
    /// from a past month is one that didn't exist yet.
    func assigned(_ categoryId: String, in month: Date) -> Double {
        let key = Day.monthKey(month)
        if let amount = assignments[key]?[categoryId] { return amount }
        if key < currentMonthKey { return 0 }
        return budgets.first { $0.id == categoryId }?.monthlyAmount ?? 0
    }

    struct Rollover {
        /// Unspent money per bucket.
        var carried: [String: Double] = [:]
        /// Left-to-assign at the end of last month (negative if over-assigned).
        var unassigned = 0.0
        /// Last month's overspending, summed over buckets.
        var overspent = 0.0
    }

    /// What rolls into `month` from the months before it. Unspent bucket
    /// money stays in its bucket. Overspending doesn't follow the bucket into
    /// the new month (it starts at zero); it comes out of next month's money
    /// to assign instead. Unassigned money rolls into next month's.
    func rollover(into month: Date) -> Rollover {
        var roll = Rollover()
        let target = Day.startOfMonth(month)
        var m = Day.month(startMonthKey)
        var guardMonths = 0
        while m < target && guardMonths < 240 {
            let isPast = Day.monthKey(m) < currentMonthKey
            let income = self.paychecks(in: m)
                .filter { $0.state == .arrived || (!isPast && $0.state == .expected) }
                .reduce(0) { $0 + $1.amount }
            var assignedTotal = 0.0, overspent = 0.0
            var carried: [String: Double] = [:]
            for category in budgets {
                let assigned = self.assigned(category.id, in: m)
                assignedTotal += assigned
                let available = (roll.carried[category.id] ?? 0) + assigned - spent(in: category.id, month: m)
                if available >= 0 { carried[category.id] = available } else { overspent -= available }
            }
            roll.unassigned += income - roll.overspent - monthlySavingsGoal - assignedTotal
            roll.carried = carried
            roll.overspent = overspent
            m = Day.addMonths(1, to: m)
            guardMonths += 1
        }
        return roll
    }

    func funding(for categoryId: String) -> BucketFunding? {
        plan.buckets.first { $0.id == categoryId }
    }

    /// The next scheduled payday for a source, today or later.
    func nextPayday(of source: IncomeSource) -> Date? {
        paydays(of: source, from: startOfToday, through: cal.date(byAdding: .day, value: 62, to: startOfToday)!).first
    }
}
