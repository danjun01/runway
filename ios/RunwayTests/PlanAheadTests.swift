import XCTest
@testable import Runway

final class PlanAheadTests: XCTestCase {
    private let today = Day.parse("2026-10-20")

    private func snapshot(transactions: [Transaction] = []) -> Snapshot {
        Snapshot(syncedAt: "", institutions: [], accounts: [
            Account(id: "chk", itemId: "i", institution: "Bank", name: "chk", mask: nil, type: "depository",
                    subtype: "checking", currentBalance: 2000, availableBalance: 2000, limit: nil, currency: "USD"),
        ], transactions: transactions, creditCards: [], recurring: [])
    }

    private func expense(_ amount: Double, due: String, every: Int?, saved: Double = 0, start: String) -> PlannedExpense {
        PlannedExpense(id: "e", name: "Car insurance", amount: amount, dueDate: due, everyMonths: every,
                       savedAtStart: saved, startMonth: start)
    }

    private func engine(_ snap: Snapshot? = nil, planned: [PlannedExpense] = [], income: [IncomeSource] = [],
                        tax: TaxSettings = TaxSettings()) -> BudgetEngine {
        var e = BudgetEngine(snapshot: snap ?? snapshot(), budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        e.plannedExpenses = planned
        e.savedIncome = income
        e.taxSettings = tax
        return e
    }

    // MARK: Planned expenses

    func testSetsAsideAnEqualShareEachMonth() {
        let e = engine(planned: [expense(600, due: "2027-03-15", every: 6, start: "2026-10-01")])
        let s = e.status(of: e.plannedExpenses[0])
        XCTAssertEqual(s.thisMonth, 100) // Oct through Mar is 6 months
        XCTAssertEqual(s.reserved, 100)
        XCTAssertEqual(e.safeToSpend.plannedSetAside, 100)
        XCTAssertEqual(e.safeToSpend.amount, 1900)
    }

    func testEarlierMonthsHaveAlreadyBeenSetAside() {
        let e = engine(planned: [expense(500, due: "2026-12-10", every: nil, start: "2026-08-01")])
        let s = e.status(of: e.plannedExpenses[0])
        XCTAssertEqual(s.saved, 200, accuracy: 0.001) // Aug and Sep, 100 each
        XCTAssertEqual(s.thisMonth, 100, accuracy: 0.001)
        XCTAssertEqual(s.reserved, 300, accuracy: 0.001)
    }

    func testPaidEarlierThisMonthHoldsNothingBack() {
        let e = engine(planned: [expense(1200, due: "2026-10-05", every: 12, saved: 1200, start: "2026-10-01")])
        let s = e.status(of: e.plannedExpenses[0])
        XCTAssertTrue(s.paidThisMonth)
        XCTAssertEqual(s.reserved, 0)
        XCTAssertEqual(Day.string(s.nextDue), "2027-10-05")
    }

    func testANewCycleStartsAfterEachPayment() {
        // Paid Aug 15; next due Feb 15, so Sep through Feb share the $300.
        let e = engine(planned: [expense(300, due: "2026-08-15", every: 6, start: "2026-07-01")])
        let s = e.status(of: e.plannedExpenses[0])
        XCTAssertEqual(Day.string(s.nextDue), "2027-02-15")
        XCTAssertEqual(s.saved, 50, accuracy: 0.001)
        XCTAssertEqual(s.thisMonth, 50, accuracy: 0.001)
    }

    func testOneTimeExpenseIsDoneOncePaid() {
        let e = engine(planned: [expense(400, due: "2026-09-01", every: nil, start: "2026-07-01")])
        let s = e.status(of: e.plannedExpenses[0])
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.reserved, 0)
    }

    func testPlannedSetAsideComesOutOfTheMonthsPlan() {
        let e = engine(planned: [expense(600, due: "2027-03-15", every: 6, start: "2026-10-01")])
        XCTAssertEqual(e.plan.plannedSetAside, 100)
        XCTAssertEqual(e.plan.leftToAssign, e.plan.income - 100 - e.plan.assigned, accuracy: 0.001)
    }

    func testForecastStartsNextMonthAndShowsWhenThingsAreDue() {
        let e = engine(planned: [expense(600, due: "2027-03-15", every: 6, start: "2026-10-01")])
        let months = e.forecast()
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(Day.string(months[0].month), "2026-11-01")
        XCTAssertEqual(months[0].plannedSetAside, 100, accuracy: 0.001)
        let march = months.first { Day.string($0.month) == "2027-03-01" }!
        XCTAssertEqual(march.due.map(\.name), ["Car insurance"])
        // After March's payment the next $600 is spread over Apr through Sep.
        let april = months.first { Day.string($0.month) == "2027-04-01" }!
        XCTAssertEqual(april.plannedSetAside, 100, accuracy: 0.001)
    }

    // MARK: Taxes

    private var freelance: IncomeSource {
        IncomeSource(id: "manual:acme", name: "Acme Studio", amount: 5000, frequency: .monthly, anchorDate: "2026-10-01",
                     matchKey: MerchantKey.of("Acme Studio"), status: .confirmed, untaxed: true)
    }

    private func deposit(_ date: String, _ amount: Double) -> Transaction {
        Transaction(id: UUID().uuidString, accountId: "chk", date: date, name: "ACME STUDIO", merchant: nil, amount: -amount,
                    category: "INCOME", detailedCategory: "INCOME_WAGES", pending: false, logoUrl: nil)
    }

    func testUntaxedIncomeHasItsTaxShareHeldBack() throws {
        let irs = Transaction(id: "irs", accountId: "chk", date: "2026-09-15", name: "IRS USATAXPYMT", merchant: nil,
                              amount: 2000, category: "GOVERNMENT_AND_NON_PROFIT",
                              detailedCategory: "GOVERNMENT_AND_NON_PROFIT_TAX_PAYMENT", pending: false, logoUrl: nil)
        let snap = snapshot(transactions: [deposit("2026-09-01", 5000), deposit("2026-10-01", 5000), irs])
        let e = engine(snap, income: [freelance], tax: TaxSettings(enabled: true, rate: 0.3))
        let tax = try XCTUnwrap(e.taxStatus)
        // Sep 1 onward is the open period (due Jan 15); the Sep 15 payment was for the summer.
        XCTAssertEqual(tax.reserved, 3000, accuracy: 0.001)
        XCTAssertEqual(Day.string(tax.nextDue), "2027-01-15")
        // Sep and Oct received, Nov and Dec expected.
        XCTAssertEqual(tax.nextEstimate, 6000, accuracy: 0.001)
        XCTAssertEqual(e.safeToSpend.taxSetAside, 3000, accuracy: 0.001)
        XCTAssertEqual(e.plan.taxSetAside, 1500, accuracy: 0.001) // October's $5,000
    }

    func testTaxesAreOffUntilTurnedOn() {
        let snap = snapshot(transactions: [deposit("2026-10-01", 5000)])
        XCTAssertNil(engine(snap, income: [freelance]).taxStatus)
        var withheld = freelance
        withheld.untaxed = false
        XCTAssertNil(engine(snap, income: [withheld], tax: TaxSettings(enabled: true, rate: 0.3)).taxStatus)
    }

    func testTaxPeriods() {
        let e = engine()
        XCTAssertEqual(Day.string(e.taxPeriod(containing: Day.parse("2026-02-10")).due), "2026-04-15")
        XCTAssertEqual(Day.string(e.taxPeriod(containing: Day.parse("2026-05-10")).due), "2026-06-15")
        XCTAssertEqual(Day.string(e.taxPeriod(containing: Day.parse("2026-08-31")).due), "2026-09-15")
        XCTAssertEqual(Day.string(e.taxPeriod(containing: Day.parse("2026-12-01")).due), "2027-01-15")
    }
}
