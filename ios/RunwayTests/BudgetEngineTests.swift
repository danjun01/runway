import XCTest
@testable import Runway

final class BudgetEngineTests: XCTestCase {
    private let today = Day.parse("2026-10-20")

    private func txn(_ date: String, _ amount: Double, _ category: String, _ detailed: String? = nil,
                     account: String = "chk") -> Transaction {
        Transaction(id: UUID().uuidString, accountId: account, date: date, name: "x", merchant: nil, amount: amount,
                    category: category, detailedCategory: detailed, pending: false, logoUrl: nil)
    }

    private func account(_ id: String, type: String, subtype: String, balance: Double) -> Account {
        Account(id: id, itemId: "i", institution: "Bank", name: id, mask: nil, type: type, subtype: subtype,
                currentBalance: balance, availableBalance: balance, limit: nil, currency: "USD")
    }

    private func snapshot(transactions: [Transaction] = [], cards: [CreditCard] = [],
                          recurring: [RecurringStream] = []) -> Snapshot {
        Snapshot(syncedAt: "", institutions: [], accounts: [
            account("chk", type: "depository", subtype: "checking", balance: 2000),
            account("sav", type: "depository", subtype: "savings", balance: 9000),
            account("visa", type: "credit", subtype: "credit card", balance: 700),
        ], transactions: transactions, creditCards: cards, recurring: recurring)
    }

    func testCardPaymentsAndTransfersAreNotSpending() {
        XCTAssertNil(BudgetCategory.categoryId(for: txn("2026-10-01", 500, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")))
        XCTAssertNil(BudgetCategory.categoryId(for: txn("2026-10-01", 500, "TRANSFER_OUT")))
        XCTAssertEqual(BudgetCategory.categoryId(for: txn("2026-10-01", 80, "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES")), "groceries")
        XCTAssertEqual(BudgetCategory.categoryId(for: txn("2026-10-01", 20, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT")), "dining")
    }

    func testSafeToSpendReservesCardsBillsAndSavings() {
        var budgets = BudgetCategory.defaults
        budgets[0].monthlyAmount = 1500 // rent, 1,200 paid so far
        let snap = snapshot(transactions: [txn("2026-10-01", 1200, "RENT_AND_UTILITIES", "RENT_AND_UTILITIES_RENT")])
        let engine = BudgetEngine(snapshot: snap, budgets: budgets, monthlySavingsGoal: 100, today: today)
        let safe = engine.safeToSpend

        XCTAssertEqual(safe.cash, 2000) // savings excluded
        XCTAssertEqual(safe.creditCardBalances, 700)
        XCTAssertEqual(safe.billsRemaining, 300)
        XCTAssertEqual(safe.amount, 2000 - 700 - 300 - 100)
        XCTAssertEqual(safe.daysLeft, 12) // Oct 20 through Oct 31
        XCTAssertEqual(safe.perDay, 900.0 / 12, accuracy: 0.001)
    }

    func testBiweeklyPaychecksBeforeMonthEndCount() {
        let pay = RecurringStream(id: "p", accountId: "chk", direction: "inflow", description: "PAYROLL", merchant: nil,
                                  averageAmount: 1000, lastAmount: 1000, frequency: "BIWEEKLY", lastDate: "2026-10-16",
                                  predictedNextDate: "2026-10-30", category: "INCOME", isActive: true)
        let engine = BudgetEngine(snapshot: snapshot(recurring: [pay]), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(engine.safeToSpend.incomeEvents.map(\.date), ["2026-10-30"])
        XCTAssertEqual(engine.safeToSpend.expectedIncome, 1000)
    }

    func testPaymentAfterStatementReducesWhatsOwed() throws {
        let card = CreditCard(accountId: "visa", lastStatementBalance: 600, lastStatementDate: "2026-10-05",
                              nextPaymentDueDate: "2026-10-30", minimumPayment: 25, lastPaymentAmount: 200,
                              lastPaymentDate: "2026-10-10", isOverdue: false, purchaseApr: 24.9)
        let engine = BudgetEngine(snapshot: snapshot(cards: [card]), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today)
        let plan = try XCTUnwrap(engine.cardPlans.first)
        XCTAssertEqual(plan.payToAvoidInterest, 400)
        XCTAssertEqual(plan.newSpending, 300) // 700 balance - 400 left on the statement
    }

    func testSuggestedBudgetRoundsUpToTens() {
        let snap = snapshot(transactions: [
            txn("2026-08-25", 101, "ENTERTAINMENT"),
            txn("2026-09-25", 101, "ENTERTAINMENT"),
            txn("2026-10-19", 101, "ENTERTAINMENT"),
        ])
        let engine = BudgetEngine(snapshot: snap, budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        let fun = engine.suggestedBudgets().first { $0.id == "fun" }!
        // 303 over 56 days is about 164 a month.
        XCTAssertEqual(fun.monthlyAmount, 170)
    }

    func testDemoDataBuildsAUsableBudget() throws {
        let engine = BudgetEngine(snapshot: DemoData.snapshot(), budgets: BudgetCategory.defaults, monthlySavingsGoal: 0)
        let budgets = engine.suggestedBudgets()
        XCTAssertGreaterThan(budgets.first { $0.id == "rent" }!.monthlyAmount, 1500)
        XCTAssertGreaterThan(budgets.first { $0.id == "groceries" }!.monthlyAmount, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(engine.chatContext()))
    }
}
