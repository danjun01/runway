import XCTest
@testable import Runway

/// Pending charges, detected bills, the checking low point, "can I afford it",
/// and the daily summary.
final class SafeToSpendTimingTests: XCTestCase {
    private let today = Day.parse("2026-10-20")

    private func txn(_ date: String, _ amount: Double, _ category: String, _ detailed: String? = nil,
                     account: String = "chk", name: String = "x", merchant: String? = nil,
                     pending: Bool = false) -> Transaction {
        Transaction(id: UUID().uuidString, accountId: account, date: date, name: name, merchant: merchant, amount: amount,
                    category: category, detailedCategory: detailed, pending: pending, logoUrl: nil)
    }

    private func account(_ id: String, type: String, subtype: String, balance: Double,
                         available: Double? = nil, limit: Double? = nil) -> Account {
        Account(id: id, itemId: "i", institution: "Bank", name: id, mask: nil, type: type, subtype: subtype,
                currentBalance: balance, availableBalance: available ?? balance, limit: limit, currency: "USD")
    }

    private var defaultAccounts: [Account] {
        [
            account("chk", type: "depository", subtype: "checking", balance: 2000),
            account("sav", type: "depository", subtype: "savings", balance: 9000),
            account("visa", type: "credit", subtype: "credit card", balance: 700),
        ]
    }

    private func snapshot(accounts: [Account]? = nil, transactions: [Transaction] = [], cards: [CreditCard] = [],
                          recurring: [RecurringStream] = []) -> Snapshot {
        Snapshot(syncedAt: "", institutions: [], accounts: accounts ?? defaultAccounts,
                 transactions: transactions, creditCards: cards, recurring: recurring)
    }

    private func paycheck(next: String) -> RecurringStream {
        RecurringStream(id: "p", accountId: "chk", direction: "inflow", description: "PAYROLL", merchant: nil,
                        averageAmount: 1000, lastAmount: 1000, frequency: "BIWEEKLY", lastDate: "2026-10-16",
                        predictedNextDate: next, category: "INCOME", isActive: true)
    }

    private func bill(_ id: String, _ name: String, next: String, last: String, amount: Double, account: String = "visa",
                      category: String = "RENT_AND_UTILITIES", detailed: String = "RENT_AND_UTILITIES_INTERNET_AND_CABLE") -> RecurringStream {
        RecurringStream(id: id, accountId: account, direction: "outflow", description: name.uppercased(), merchant: name,
                        averageAmount: amount, lastAmount: amount, frequency: "MONTHLY", lastDate: last,
                        predictedNextDate: next, category: category, detailedCategory: detailed, isActive: true)
    }

    private func engine(_ snapshot: Snapshot, budgets: [BudgetCategory] = BudgetCategory.defaults) -> BudgetEngine {
        BudgetEngine(snapshot: snapshot, budgets: budgets, monthlySavingsGoal: 0, today: today)
    }

    // MARK: Pending

    func testPendingCardChargesAreReserved() {
        let pendingDinner = txn("2026-10-19", 50, "FOOD_AND_DRINK", account: "visa", pending: true)
        let safe = engine(snapshot(transactions: [pendingDinner])).safeToSpend
        XCTAssertEqual(safe.creditCardBalances, 750)
        XCTAssertEqual(safe.pendingCardCharges, 50)
    }

    func testPendingChargesTheBankAlreadyCountedArentAddedTwice() {
        let pendingDinner = txn("2026-10-19", 50, "FOOD_AND_DRINK", account: "visa", pending: true)
        func reserved(available: Double) -> Double {
            let accounts = [
                account("chk", type: "depository", subtype: "checking", balance: 2000),
                account("visa", type: "credit", subtype: "credit card", balance: 700, available: available, limit: 5000),
            ]
            return engine(snapshot(accounts: accounts, transactions: [pendingDinner])).safeToSpend.creditCardBalances
        }
        XCTAssertEqual(reserved(available: 4250), 750) // available credit took the $50 off; the balance didn't
        XCTAssertEqual(reserved(available: 4300), 700) // the $700 balance already includes it
    }

    func testCheckingWithoutAnAvailableBalanceSubtractsPendingDebits() {
        let accounts = [Account(id: "chk", itemId: "i", institution: "Bank", name: "chk", mask: nil, type: "depository",
                                subtype: "checking", currentBalance: 2000, availableBalance: nil, limit: nil, currency: "USD")]
        let snap = snapshot(accounts: accounts, transactions: [txn("2026-10-20", 40, "FOOD_AND_DRINK", pending: true)])
        XCTAssertEqual(engine(snap).safeToSpend.cash, 1960)
    }

    // MARK: Bills

    func testDetectedBillsCountUntilTheyPost() {
        let spectrum = bill("s", "Spectrum", next: "2026-10-25", last: "2026-09-25", amount: 70)
        let cardPayment = bill("c", "Chase Card", next: "2026-10-28", last: "2026-09-28", amount: 900, account: "chk",
                               category: "LOAN_PAYMENTS", detailed: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
        let savings = bill("t", "To Savings", next: "2026-10-26", last: "2026-09-26", amount: 300, account: "chk",
                           category: "TRANSFER_OUT", detailed: "TRANSFER_OUT_SAVINGS")
        let upcoming = engine(snapshot(recurring: [spectrum, cardPayment, savings]))
        XCTAssertEqual(upcoming.upcomingBills.map(\.name), ["Spectrum"])
        XCTAssertEqual(upcoming.billsRemaining, 70)

        // Charged early, before Plaid attached it to the stream: it's in the card balance now.
        let posted = engine(snapshot(transactions: [txn("2026-10-19", 70, "RENT_AND_UTILITIES", account: "visa",
                                                        name: "SPECTRUM", merchant: "Spectrum")],
                                     recurring: [spectrum]))
        XCTAssertTrue(posted.upcomingBills.isEmpty)
    }

    func testLateBillsCountAsDueTodayForAWeek() {
        let late = bill("s", "Spectrum", next: "2026-10-15", last: "2026-09-15", amount: 70)
        XCTAssertEqual(engine(snapshot(recurring: [late])).upcomingBills.map { Day.string($0.date) }, ["2026-10-20"])
        let stale = bill("s", "Spectrum", next: "2026-10-01", last: "2026-09-01", amount: 70)
        XCTAssertTrue(engine(snapshot(recurring: [stale])).upcomingBills.isEmpty)
    }

    func testPlaidTrackedBillsReplaceTheAssignedAmountForThatBucket() {
        let rent = bill("r", "Parkview", next: "2026-10-28", last: "2026-09-28", amount: 1500, account: "chk",
                        detailed: "RENT_AND_UTILITIES_RENT")
        var budgets = BudgetCategory.defaults
        budgets[0].monthlyAmount = 1600 // rent & utilities
        XCTAssertEqual(engine(snapshot(recurring: [rent]), budgets: budgets).billsRemaining, 1500)
        // Insurance billed next month: nothing due now, and the assigned amount doesn't make one up.
        let insurance = bill("i", "Geico", next: "2026-11-07", last: "2026-10-07", amount: 120,
                             category: "GENERAL_SERVICES", detailed: "GENERAL_SERVICES_INSURANCE")
        budgets[1].monthlyAmount = 900
        XCTAssertEqual(engine(snapshot(recurring: [insurance]), budgets: budgets).billsRemaining, 1600)
        // With no bills tracked at all, assigned amounts are all there is.
        XCTAssertEqual(engine(snapshot(), budgets: budgets).billsRemaining, 2500)
    }

    // MARK: Timing

    func testCheckingLowPointWhenACardIsDueBeforePayday() {
        let accounts = [
            account("chk", type: "depository", subtype: "checking", balance: 1000),
            account("visa", type: "credit", subtype: "credit card", balance: 900),
        ]
        let card = CreditCard(accountId: "visa", lastStatementBalance: 900, lastStatementDate: "2026-10-01",
                              nextPaymentDueDate: "2026-10-25", minimumPayment: 25, lastPaymentAmount: nil,
                              lastPaymentDate: nil, isOverdue: false, purchaseApr: 24.9)
        let e = engine(snapshot(accounts: accounts, cards: [card], recurring: [paycheck(next: "2026-10-30")]))
        let safe = e.safeToSpend
        XCTAssertEqual(safe.amount, 1100) // 1,000 + 1,000 paycheck - 900 card
        XCTAssertEqual(safe.lowPoint.balance, 100)
        XCTAssertEqual(Day.string(safe.lowPoint.date), "2026-10-25")
        XCTAssertEqual(safe.lowPoint.nextPaycheck.map(Day.string), "2026-10-30")
        XCTAssertEqual(safe.spendableNow, 100)
        XCTAssertTrue(safe.isTimingLimited)

        XCTAssertEqual(e.canAfford(50), .yes(left: 1050, perDay: 1050.0 / 12))
        XCTAssertEqual(e.canAfford(500), .afterPaycheck(Day.parse("2026-10-30"), spendableNow: 100))
        XCTAssertEqual(e.canAfford(2000), .no(over: 900))
    }

    func testOnlyBillsPaidFromCheckingLowerTheCheckingProjection() {
        let onCard = bill("a", "Spectrum", next: "2026-10-25", last: "2026-09-25", amount: 70)
        let fromChecking = bill("b", "Parkview", next: "2026-10-26", last: "2026-09-26", amount: 1500, account: "chk",
                                detailed: "RENT_AND_UTILITIES_RENT")
        XCTAssertEqual(engine(snapshot(recurring: [onCard])).safeToSpend.lowPoint.balance, 2000)
        let low = engine(snapshot(recurring: [onCard, fromChecking])).safeToSpend.lowPoint
        XCTAssertEqual(low.balance, 500)
        XCTAssertEqual(low.cause, "Parkview")
    }

    // MARK: Names and buckets

    func testMerchantKeysDropReferenceCodes() {
        XCTAssertEqual(MerchantKey.of("UBER *TRIP 8H2K"), MerchantKey.of("UBER *TRIP 3MZQ"))
        XCTAssertEqual(MerchantKey.of("UBER *TRIP 3MZQ"), "uber trip")
    }

    func testEmptyMerchantNamesFallBackToTheDescription() {
        let t = txn("2026-10-15", -3100, "INCOME", name: "HARTFORD FIRE IN PAYROLL", merchant: "")
        XCTAssertEqual(t.displayName, "HARTFORD FIRE IN PAYROLL")
        var stream = paycheck(next: "2026-10-30")
        stream.merchant = ""
        XCTAssertEqual(stream.displayName, "PAYROLL")
    }

    func testSpendingInADeletedBucketLandsInEverythingElse() {
        let dinner = txn("2026-10-05", 40, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT", name: "UCHI")
        let e = engine(snapshot(transactions: [dinner]), budgets: BudgetCategory.defaults.filter { $0.id != "dining" })
        XCTAssertEqual(e.bucketId(for: dinner), "other")
        XCTAssertEqual(e.spent(in: "other"), 40)
    }

    // MARK: Daily summary

    func testDailySummaryText() {
        let e = engine(snapshot())
        let fire = DailySummary.nextFireDate(minutes: 9 * 60, after: today)
        XCTAssertEqual(Day.string(fire), "2026-10-20") // midnight today, so 9:00 is still ahead
        XCTAssertEqual(Day.calendar.component(.hour, from: fire), 9)
        // 2,000 - 700 on the card, spread over Oct 21 through Oct 31.
        XCTAssertEqual(DailySummary.message(for: e, on: Day.parse("2026-10-21").addingTimeInterval(9 * 3600)),
                       "$1,300 left this month, about $118 a day for 11 days.")
        XCTAssertTrue(DailySummary.message(for: e, on: Day.parse("2026-11-01")).hasPrefix("A new month"))
    }
}
