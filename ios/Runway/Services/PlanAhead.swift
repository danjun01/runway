import Foundation

/// Planned (non-monthly) expenses, self-employment taxes, and the months-ahead forecast.
extension BudgetEngine {

    // MARK: Planned expenses

    struct PlannedStatus: Identifiable, Hashable {
        var expense: PlannedExpense
        /// When the next payment is due.
        var nextDue: Date
        /// Set aside in earlier months toward that payment.
        var saved: Double
        /// To set aside this month.
        var thisMonth: Double
        /// Paid earlier this month; nothing is held for it now.
        var paidThisMonth: Bool
        /// False once a one-time expense has been paid.
        var isActive: Bool
        var id: String { expense.id }

        /// What safe-to-spend holds back for it right now.
        var reserved: Double { paidThisMonth || !isActive ? 0 : saved + thisMonth }
        /// How much of the next payment is set aside, counting this month's share.
        var progress: Double { expense.amount > 0 ? min(1, (saved + thisMonth) / expense.amount) : 1 }
    }

    /// Replays each planned expense month by month from when it was set up:
    /// every month sets aside an equal share of what's still needed before the
    /// due date, and once the due date passes the cycle starts over.
    func status(of expense: PlannedExpense) -> PlannedStatus {
        var due = Day.parse(expense.dueDate)
        var saved = max(0, expense.savedAtStart)
        var month = Day.startOfMonth(Day.parse(expense.startMonth))
        let thisMonthStart = monthStart
        var active = true
        var paidThisMonth = false

        func advanceCycle() {
            if let every = expense.everyMonths, every > 0 {
                due = cal.date(byAdding: .month, value: every, to: due)!
            } else {
                active = false
            }
            saved = 0
        }

        if month > thisMonthStart { month = thisMonthStart }
        while month <= thisMonthStart, active {
            // A payment due before this month has been made.
            while active, due < month { advanceCycle() }
            guard active else { break }
            let monthsLeft = max(1, (cal.dateComponents([.month], from: month, to: Day.startOfMonth(due)).month ?? 0) + 1)
            let share = max(0, expense.amount - saved) / Double(monthsLeft)
            if month < thisMonthStart {
                saved += share
                month = cal.date(byAdding: .month, value: 1, to: month)!
                continue
            }
            // This month. A payment due earlier this month has already gone out.
            if due < startOfToday {
                paidThisMonth = true
                advanceCycle()
                return PlannedStatus(expense: expense, nextDue: due, saved: 0, thisMonth: 0,
                                     paidThisMonth: true, isActive: active)
            }
            return PlannedStatus(expense: expense, nextDue: due, saved: saved, thisMonth: share,
                                 paidThisMonth: paidThisMonth, isActive: true)
        }
        return PlannedStatus(expense: expense, nextDue: due, saved: 0, thisMonth: 0, paidThisMonth: false, isActive: active)
    }

    var plannedStatuses: [PlannedStatus] {
        plannedExpenses.map(status(of:)).sorted { $0.nextDue < $1.nextDue }
    }

    /// Plaid recurring charges that come less than monthly (yearly renewals,
    /// insurance) and aren't planned yet: good candidates to plan for.
    var plannedExpenseSuggestions: [RecurringStream] {
        let planned = Set(plannedExpenses.compactMap(\.streamId))
        return snapshot.recurring.filter {
            $0.direction == "outflow" && $0.isActive && $0.frequency == "ANNUALLY" && !planned.contains($0.id)
                && $0.averageAmount >= 20
        }
    }

    var plannedStreamIds: Set<String> { Set(plannedExpenses.compactMap(\.streamId)) }

    /// Full monthly amounts of bill buckets with no Plaid-tracked bill in them.
    var untrackedBillBudgets: Double {
        let tracked = Set(snapshot.recurring.filter(\.isBill).compactMap(billBucket(ofStream:)))
        return budgets.filter { $0.isFixed && !tracked.contains($0.id) }.reduce(0) { $0 + $1.monthlyAmount }
    }

    // MARK: Taxes

    struct TaxStatus: Hashable {
        var rate: Double
        /// Set aside now for taxes not yet paid: the share of untaxed income received since the last estimated payment was due, less payments made since.
        var reserved: Double
        /// The share of untaxed pay still expected this month.
        var fromExpectedPay: Double
        /// The estimated payment for the current period and when it's due.
        var nextDue: Date
        var nextEstimate: Double
        /// Untaxed income this calendar year, and the tax payments Runway has seen.
        var untaxedIncomeThisYear: Double
        var paidThisYear: Double
    }

    /// Estimated-tax periods: income from Jan–Mar is due Apr 15, Apr–May Jun 15,
    /// Jun–Aug Sep 15, and Sep–Dec Jan 15 of the next year.
    func taxPeriod(containing date: Date) -> (start: Date, end: Date, due: Date) {
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        switch month {
        case 1...3: return (day(year, 1, 1), day(year, 3, 31), day(year, 4, 15))
        case 4...5: return (day(year, 4, 1), day(year, 5, 31), day(year, 6, 15))
        case 6...8: return (day(year, 6, 1), day(year, 8, 31), day(year, 9, 15))
        default: return (day(year, 9, 1), day(year, 12, 31), day(year + 1, 1, 15))
        }
    }

    var untaxedSources: [IncomeSource] { countedIncome.filter { $0.untaxed == true } }

    func untaxedIncome(from start: Date, through end: Date) -> Double {
        untaxedSources.flatMap(deposits(of:)).filter { $0.day >= start && $0.day <= end }
            .reduce(0) { $0 - $1.amount }
    }

    var taxPayments: [Transaction] {
        snapshot.transactions.filter { $0.detailedCategory == "GOVERNMENT_AND_NON_PROFIT_TAX_PAYMENT" && $0.amount > 0 }
    }

    var taxStatus: TaxStatus? {
        guard taxSettings.enabled, !untaxedSources.isEmpty else { return nil }
        let rate = min(max(taxSettings.rate, 0), 0.6)
        let current = taxPeriod(containing: startOfToday)
        // Income in the previous period stays set aside until its payment is due.
        let previous = taxPeriod(containing: cal.date(byAdding: .day, value: -1, to: current.start)!)
        let openFrom = previous.due >= startOfToday ? previous.start : current.start
        let paymentsSince = previous.due >= startOfToday ? cal.date(byAdding: .day, value: -1, to: previous.start)! : previous.due
        let paid = taxPayments.filter { $0.day > paymentsSince && $0.day <= startOfToday }.reduce(0) { $0 + $1.amount }
        let received = untaxedIncome(from: openFrom, through: startOfToday)

        let untaxedIds = Set(untaxedSources.map(\.id))
        let expectedThisMonth = expectedPaychecks(through: monthEnd).filter { untaxedIds.contains($0.sourceId) }
            .reduce(0) { $0 + $1.amount }
        let expectedInPeriod = expectedPaychecks(through: current.end).filter { untaxedIds.contains($0.sourceId) }
            .reduce(0) { $0 + $1.amount }

        let yearStart = cal.date(from: DateComponents(year: cal.component(.year, from: today), month: 1, day: 1))!
        // A payment in early January is usually last year's fourth estimate.
        let yearPaymentsFrom = cal.date(byAdding: .day, value: 15, to: yearStart)!
        return TaxStatus(
            rate: rate,
            reserved: max(0, rate * received - paid),
            fromExpectedPay: rate * expectedThisMonth,
            nextDue: current.due,
            nextEstimate: rate * (untaxedIncome(from: current.start, through: startOfToday) + expectedInPeriod),
            untaxedIncomeThisYear: untaxedIncome(from: yearStart, through: startOfToday),
            paidThisYear: taxPayments.filter { $0.day >= yearPaymentsFrom && $0.day <= startOfToday }.reduce(0) { $0 + $1.amount }
        )
    }

    // MARK: Forecast

    struct ForecastMonth: Identifiable, Hashable {
        struct Due: Hashable {
            var name: String
            var amount: Double
            var date: Date
        }
        var month: Date
        var income: Double
        /// Recurring bills and assigned bill buckets Plaid isn't tracking.
        var bills: Double
        /// Assigned flexible buckets.
        var spending: Double
        var savingsGoal: Double
        /// Set aside this month for planned expenses.
        var plannedSetAside: Double
        var taxSetAside: Double
        /// Planned expenses and estimated tax payments that fall due this month, paid from what was set aside.
        var due: [Due]
        var id: Date { month }

        var left: Double { income - bills - spending - savingsGoal - plannedSetAside - taxSetAside }
    }

    /// The next `months` months, starting next month (this month is Safe to
    /// spend's job): income on its schedule, regular bills, the budget, and money
    /// set aside for what's coming later. Big expenses show in the month they're
    /// due but are paid from set-asides, so they don't swing that month's bottom line.
    func forecast(months: Int = 12) -> [ForecastMonth] {
        let flexible = budgets.filter { !$0.isFixed }.reduce(0) { $0 + $1.monthlyAmount }
        let untrackedBills = untrackedBillBudgets
        let untaxedIds = Set(untaxedSources.map(\.id))
        let rate = taxSettings.enabled ? min(max(taxSettings.rate, 0), 0.6) : 0
        let streams = snapshot.recurring.filter { $0.isBill && !plannedStreamIds.contains($0.id) }

        var result: [ForecastMonth] = []
        var planned = plannedExpenses.map { (expense: $0, status: status(of: $0)) }
        for offset in 0...max(1, months) {
            let start = cal.date(byAdding: .month, value: offset, to: monthStart)!
            let end = Day.endOfMonth(start)
            var due: [ForecastMonth.Due] = []

            // This month only seeds the planned expenses' running totals.
            if offset == 0 { continue }

            // Income and its tax share.
            var income = 0.0
            var untaxed = 0.0
            for source in countedIncome {
                let pay = Double(paydays(of: source, from: start, through: end).count) * source.amount
                income += pay
                if untaxedIds.contains(source.id) { untaxed += pay }
            }

            // Bills: each tracked stream's charges that month, plus untracked bill budgets.
            var bills = untrackedBills
            for stream in streams {
                bills += Double(occurrences(of: stream, from: start, through: end).count) * max(stream.averageAmount, stream.lastAmount)
            }

            // Planned expenses: this month's set-aside, and any that fall due.
            var setAside = 0.0
            for i in planned.indices {
                let expense = planned[i].expense
                var s = planned[i].status
                guard s.isActive else { continue }
                // Roll last month's set-aside into what's saved, and start over after a payment.
                if s.nextDue < start {
                    if let every = expense.everyMonths, every > 0 {
                        s.nextDue = cal.date(byAdding: .month, value: every, to: s.nextDue)!
                        s.saved = 0
                    } else {
                        s.isActive = false
                        planned[i].status = s
                        continue
                    }
                } else {
                    s.saved += s.thisMonth
                }
                let monthsLeft = max(1, (cal.dateComponents([.month], from: start, to: Day.startOfMonth(s.nextDue)).month ?? 0) + 1)
                s.thisMonth = max(0, expense.amount - s.saved) / Double(monthsLeft)
                s.paidThisMonth = false
                setAside += s.thisMonth
                if s.nextDue <= end { due.append(.init(name: expense.name, amount: expense.amount, date: s.nextDue)) }
                planned[i].status = s
            }

            // Estimated tax payments due this month.
            if rate > 0, !untaxedIds.isEmpty {
                for month in [1, 4, 6, 9] where cal.component(.month, from: start) == month {
                    let dueDate = cal.date(byAdding: .day, value: 14, to: start)!
                    if dueDate >= startOfToday {
                        due.append(.init(name: "Estimated taxes", amount: estimatedPayment(dueOn: dueDate, rate: rate), date: dueDate))
                    }
                }
            }

            result.append(ForecastMonth(month: start, income: income, bills: bills, spending: flexible,
                                        savingsGoal: monthlySavingsGoal, plannedSetAside: setAside,
                                        taxSetAside: rate * untaxed, due: due.sorted { $0.date < $1.date }))
        }
        return result
    }

    /// The estimated payment due on a date: the tax share of untaxed income in the period it covers, received or expected.
    private func estimatedPayment(dueOn date: Date, rate: Double) -> Double {
        let period = taxPeriod(containing: cal.date(byAdding: .month, value: -1, to: date)!)
        let received = untaxedIncome(from: period.start, through: min(period.end, startOfToday))
        var expected = 0.0
        let from = max(period.start, cal.date(byAdding: .day, value: 1, to: startOfToday)!)
        if from <= period.end {
            for source in untaxedSources {
                expected += Double(paydays(of: source, from: from, through: period.end).count) * source.amount
            }
        }
        return rate * (received + expected)
    }

    /// Dates a recurring stream is projected to charge between two dates.
    private func occurrences(of stream: RecurringStream, from start: Date, through end: Date) -> [Date] {
        let step: DateComponents
        switch stream.frequency {
        case "WEEKLY": step = DateComponents(day: 7)
        case "BIWEEKLY": step = DateComponents(day: 14)
        case "SEMI_MONTHLY": step = DateComponents(day: 15)
        case "MONTHLY": step = DateComponents(month: 1)
        case "ANNUALLY": step = DateComponents(year: 1)
        default: return []
        }
        var date = stream.predictedNextDate.map(Day.parse) ?? Day.parse(stream.lastDate)
        guard date != .distantPast else { return [] }
        var dates: [Date] = []
        var guardCount = 0
        while date <= end, guardCount < 500 {
            if date >= start { dates.append(date) }
            date = cal.date(byAdding: step, to: date)!
            guardCount += 1
        }
        return dates
    }
}
