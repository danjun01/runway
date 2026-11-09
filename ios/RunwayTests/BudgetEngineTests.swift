import XCTest
@testable import Runway

final class BudgetEngineTests: XCTestCase {
    private let today = Day.parse("2026-10-20")

    private func txn(_ date: String, _ amount: Double, _ category: String, _ detailed: String? = nil,
                     account: String = "chk", name: String = "x") -> Transaction {
        Transaction(id: UUID().uuidString, accountId: account, date: date, name: name, merchant: nil, amount: amount,
                    category: category, detailedCategory: detailed, pending: false, logoUrl: nil)
    }

    private func account(_ id: String, type: String, subtype: String, balance: Double) -> Account {
        Account(id: id, itemId: "i", institution: "Bank", name: id, mask: nil, type: type, subtype: subtype,
                currentBalance: balance, availableBalance: balance, limit: nil, currency: "USD")
    }

    private func snapshot(transactions: [Transaction] = [], cards: [CreditCard] = [],
                          recurring: [RecurringStream] = [], cardBalance: Double = 700) -> Snapshot {
        Snapshot(syncedAt: "", institutions: [], accounts: [
            account("chk", type: "depository", subtype: "checking", balance: 2000),
            account("sav", type: "depository", subtype: "savings", balance: 9000),
            account("visa", type: "credit", subtype: "credit card", balance: cardBalance),
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

    // MARK: Income and plan

    private let payroll = RecurringStream(id: "p", accountId: "chk", direction: "inflow", description: "ACME PAYROLL PPD ID: 991",
                                          merchant: nil, averageAmount: 1000, lastAmount: 1000, frequency: "BIWEEKLY",
                                          lastDate: "2026-10-16", predictedNextDate: "2026-10-30", category: "INCOME", isActive: true)

    private var paidTwiceInOctober: [Transaction] {
        [txn("2026-10-02", -1000, "INCOME", "INCOME_WAGES", name: "ACME PAYROLL PPD ID: 991"),
         txn("2026-10-16", -1010, "INCOME", "INCOME_WAGES", name: "ACME PAYROLL PPD ID: 991")]
    }

    func testMerchantKeysIgnoreBankNoise() {
        XCTAssertEqual(MerchantKey.of("ACME CORP PAYROLL PPD ID: 123456"), "acme corp payroll")
        XCTAssertTrue(MerchantKey.matches(MerchantKey.of("Acme Corp"), MerchantKey.of("ACME CORP PAYROLL 10/15")))
        XCTAssertFalse(MerchantKey.matches(MerchantKey.of("Acme Corp"), MerchantKey.of("Globex Payroll")))
    }

    func testPaychecksAreArrivedOrExpected() {
        let engine = BudgetEngine(snapshot: snapshot(transactions: paidTwiceInOctober, recurring: [payroll]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        let checks = engine.paychecksThisMonth()
        XCTAssertEqual(checks.map(\.state), [.arrived, .arrived, .expected])
        XCTAssertEqual(checks.map { Day.string($0.date) }, ["2026-10-02", "2026-10-16", "2026-10-30"])
        XCTAssertEqual(engine.plan.arrived, 2010)
        XCTAssertEqual(engine.plan.expected, 1000)
        XCTAssertEqual(engine.safeToSpend.expectedIncome, 1000)
        XCTAssertEqual(engine.safeToSpend.inHand, engine.safeToSpend.amount - 1000)
    }

    func testMissingPaycheckIsFlaggedNotCounted() {
        // Only the Oct 2 deposit landed; Oct 16 is four days late by Oct 20.
        let engine = BudgetEngine(snapshot: snapshot(transactions: [paidTwiceInOctober[0]], recurring: [payroll]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(engine.paychecksThisMonth().map(\.state), [.arrived, .missed, .expected])
        XCTAssertEqual(engine.plan.income, 2000)
    }

    func testPlanBacksBillsWithArrivedMoneyFirst() throws {
        var budgets = BudgetCategory.defaults
        budgets[budgets.firstIndex { $0.id == "dining" }!].monthlyAmount = 800
        budgets[budgets.firstIndex { $0.id == "rent" }!].monthlyAmount = 1500
        let engine = BudgetEngine(snapshot: snapshot(transactions: paidTwiceInOctober, recurring: [payroll]),
                                  budgets: budgets, monthlySavingsGoal: 100, today: today)
        let plan = engine.plan
        let rent = try XCTUnwrap(plan.buckets.first { $0.id == "rent" })
        let dining = try XCTUnwrap(plan.buckets.first { $0.id == "dining" })
        XCTAssertEqual(rent.fromArrived, 1500)
        XCTAssertEqual(rent.fromExpected, 0)
        // 2,010 arrived - 100 savings - 1,500 rent leaves 410 for dining; 390 waits on Oct 30.
        XCTAssertEqual(dining.fromArrived, 410, accuracy: 0.001)
        XCTAssertEqual(dining.fromExpected, 390, accuracy: 0.001)
        XCTAssertEqual(dining.waitingOn.map(Day.string), "2026-10-30")
        XCTAssertEqual(plan.leftToAssign, 3010 - 100 - 2300, accuracy: 0.001)
        XCTAssertEqual(plan.assignedFromExpected, 390, accuracy: 0.001)
    }

    func testIgnoredIncomeIsNotCounted() {
        var source = BudgetEngine(snapshot: snapshot(recurring: [payroll]), budgets: [], monthlySavingsGoal: 0, today: today)
            .incomeSources[0]
        source.status = .ignored
        let engine = BudgetEngine(snapshot: snapshot(transactions: paidTwiceInOctober, recurring: [payroll]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today, savedIncome: [source])
        XCTAssertEqual(engine.incomeSources.count, 1)
        XCTAssertEqual(engine.safeToSpend.expectedIncome, 0)
        XCTAssertEqual(engine.plan.income, 0)
    }

    func testTransferStreamsAreSuggestedNotCounted() {
        var venmo = payroll
        venmo.id = "v"
        venmo.description = "VENMO"
        venmo.category = "TRANSFER_IN"
        let engine = BudgetEngine(snapshot: snapshot(recurring: [venmo]), budgets: [], monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(engine.incomeSources.map(\.status), [.suggested])
        XCTAssertEqual(engine.safeToSpend.expectedIncome, 0)
    }

    func testMonthlyIncomeIsDetectedFromHistory() throws {
        let deposits = ["2026-07-01", "2026-08-01", "2026-09-01", "2026-10-01"].map {
            txn($0, -3000, "INCOME", "INCOME_WAGES", name: "GLOBEX DIR DEP")
        }
        let engine = BudgetEngine(snapshot: snapshot(transactions: deposits), budgets: [], monthlySavingsGoal: 0, today: today)
        let source = try XCTUnwrap(engine.incomeSources.first)
        XCTAssertEqual(source.frequency, .monthly)
        XCTAssertEqual(source.amount, 3000)
        XCTAssertEqual(engine.nextPayday(of: source).map(Day.string), "2026-11-01")
        XCTAssertEqual(engine.plan.arrived, 3000)
        XCTAssertEqual(engine.plan.expected, 0)
    }

    func testSemiMonthlyPaydaysClampToMonthEnd() {
        let source = IncomeSource(id: "manual:x", name: "Pay", amount: 1, frequency: .semiMonthly, anchorDate: "2026-01-15",
                                  matchKey: "pay", status: .confirmed)
        let engine = BudgetEngine(snapshot: snapshot(), budgets: [], monthlySavingsGoal: 0, today: today)
        let feb = engine.paydays(of: source, from: Day.parse("2026-02-01"), through: Day.parse("2026-02-28"))
        XCTAssertEqual(feb.map(Day.string), ["2026-02-15", "2026-02-28"])
    }

    func testCardStatementCanWaitOnAPaycheck() throws {
        let card = CreditCard(accountId: "visa", lastStatementBalance: 2500, lastStatementDate: "2026-10-05",
                              nextPaymentDueDate: "2026-10-31", minimumPayment: 25, lastPaymentAmount: nil,
                              lastPaymentDate: nil, isOverdue: false, purchaseApr: 24.9)
        let engine = BudgetEngine(snapshot: snapshot(cards: [card], recurring: [payroll], cardBalance: 2600),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        let plan = try XCTUnwrap(engine.cardPlans.first)
        XCTAssertEqual(plan.funding, .paycheck(Day.parse("2026-10-30")))

        let noPay = BudgetEngine(snapshot: snapshot(cards: [card], cardBalance: 2600),
                                 budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(noPay.cardPlans.first?.funding, .short(500))
    }

    func testMovingAMerchantChangesItsBucket() {
        let snap = snapshot(transactions: [txn("2026-10-05", 40, "GENERAL_MERCHANDISE", name: "Petco #123")])
        var budgets = BudgetCategory.defaults
        let pets = BudgetCategory.custom(name: "Pets", isFixed: false, amount: 100)
        budgets.append(pets)
        let engine = BudgetEngine(snapshot: snap, budgets: budgets, monthlySavingsGoal: 0, today: today,
                                  bucketRules: [MerchantKey.of("Petco #123"): pets.id])
        XCTAssertEqual(engine.spent(in: pets.id), 40)
        XCTAssertEqual(engine.spent(in: "shopping"), 0)
    }

    // MARK: Rollover and moving money

    private func diningBudget(_ amount: Double = 300) -> [BudgetCategory] {
        var budgets = BudgetCategory.defaults
        budgets[budgets.firstIndex { $0.id == "dining" }!].monthlyAmount = amount
        return budgets
    }

    private func dining(_ date: String, _ amount: Double) -> Transaction {
        txn(date, amount, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT")
    }

    private var septemberPay: Transaction { txn("2026-09-01", -1000, "INCOME", "INCOME_WAGES", name: "GLOBEX") }

    func testUnspentMoneyAndUnassignedIncomeRollOver() throws {
        let snap = snapshot(transactions: [septemberPay, dining("2026-09-10", 200), dining("2026-10-05", 50)])
        let engine = BudgetEngine(snapshot: snap, budgets: diningBudget(), monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": ["dining": 300]], budgetStart: "2026-09")
        let plan = engine.plan
        let bucket = try XCTUnwrap(plan.buckets.first { $0.id == "dining" })
        XCTAssertEqual(bucket.carried, 100)
        XCTAssertEqual(bucket.assigned, 300)
        XCTAssertEqual(bucket.available, 350)
        // 1,000 came in during September and 300 of it was assigned.
        XCTAssertEqual(plan.carriedOver, 700)
        XCTAssertEqual(plan.leftToAssign, 400)
    }

    func testOverspendingComesOutOfNextMonth() throws {
        let snap = snapshot(transactions: [septemberPay, dining("2026-09-10", 350)])
        let engine = BudgetEngine(snapshot: snap, budgets: diningBudget(), monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": ["dining": 300]], budgetStart: "2026-09")
        let plan = engine.plan
        let bucket = try XCTUnwrap(plan.buckets.first { $0.id == "dining" })
        XCTAssertEqual(bucket.carried, 0) // the bucket starts fresh
        XCTAssertEqual(plan.overspentLastMonth, 50)
        XCTAssertEqual(plan.leftToAssign, 700 - 50 - 300)
    }

    func testOverspentBucketShowsUntilCovered() throws {
        let snap = snapshot(transactions: [dining("2026-10-05", 340)])
        let before = BudgetEngine(snapshot: snap, budgets: diningBudget(), monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(before.plan.overspent.map(\.id), ["dining"])
        XCTAssertEqual(before.plan.overspent.first?.available, -40)

        // Covering it moves 40 from Fun into Dining for October only.
        var budgets = diningBudget()
        budgets[budgets.firstIndex { $0.id == "fun" }!].monthlyAmount = 100
        let after = BudgetEngine(snapshot: snap, budgets: budgets, monthlySavingsGoal: 0, today: today,
                                 assignments: ["2026-10": ["dining": 340, "fun": 60]])
        XCTAssertTrue(after.plan.overspent.isEmpty)
        XCTAssertEqual(after.assigned("fun", in: Day.parse("2026-10-01")), 60)
        XCTAssertEqual(after.assigned("fun", in: Day.parse("2026-11-01")), 100) // the plan repeats next month
    }

    func testBucketsMissingFromAClosedMonthHadNothing() {
        var budgets = diningBudget()
        budgets.append(.custom(name: "Gifts", isFixed: false, amount: 50))
        let engine = BudgetEngine(snapshot: snapshot(), budgets: budgets, monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": ["dining": 300]], budgetStart: "2026-09")
        XCTAssertEqual(engine.assigned(budgets.last!.id, in: Day.parse("2026-09-01")), 0)
        XCTAssertEqual(engine.assigned(budgets.last!.id, in: Day.parse("2026-10-01")), 50)
    }

    func testFutureMonthsProjectEveryPaycheck() {
        let engine = BudgetEngine(snapshot: snapshot(transactions: paidTwiceInOctober, recurring: [payroll]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        let november = engine.plan(for: Day.parse("2026-11-01"))
        XCTAssertEqual(november.paychecks.map { Day.string($0.date) }, ["2026-11-13", "2026-11-27"])
        XCTAssertTrue(november.paychecks.allSatisfy { $0.state == .expected })
        // October's 3,010 (two arrived, one expected) rolls into November unassigned.
        XCTAssertEqual(november.carriedOver, 3010, accuracy: 0.001)
    }

    func testSavedUpBillMoneyIsReservedFromSafeToSpend() {
        var budgets = BudgetCategory.defaults
        let insurance = BudgetCategory.custom(name: "Car insurance", isFixed: true, amount: 100)
        budgets.append(insurance)
        let engine = BudgetEngine(snapshot: snapshot(), budgets: budgets, monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": [insurance.id: 100]], budgetStart: "2026-09")
        XCTAssertEqual(engine.billsRemaining, 200) // 100 saved in September + 100 this month
    }

    // MARK: Review inbox, one-off changes, and splits

    func testOneOffChangeDoesNotMoveTheMerchant() {
        let a = txn("2026-10-05", 40, "GENERAL_MERCHANDISE", name: "Target")
        let b = txn("2026-10-06", 60, "GENERAL_MERCHANDISE", name: "Target")
        let engine = BudgetEngine(snapshot: snapshot(transactions: [a, b]), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today, transactionBuckets: [a.id: "groceries"])
        XCTAssertEqual(engine.spent(in: "groceries"), 40)
        XCTAssertEqual(engine.spent(in: "shopping"), 60)
    }

    func testOneOffChangeCanMakeATransferSpending() {
        let venmo = txn("2026-10-05", 80, "TRANSFER_OUT", name: "Venmo")
        let engine = BudgetEngine(snapshot: snapshot(transactions: [venmo]), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today, transactionBuckets: [venmo.id: "fun"])
        XCTAssertEqual(engine.spent(in: "fun"), 80)
    }

    func testSplitSpreadsATransactionAcrossBuckets() {
        let costco = txn("2026-10-05", 200, "GENERAL_MERCHANDISE", name: "Costco")
        let engine = BudgetEngine(snapshot: snapshot(transactions: [costco]), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today, splits: [costco.id: ["groceries": 150]])
        // The 50 the split doesn't place stays in the usual bucket.
        XCTAssertEqual(engine.spent(in: "groceries"), 150)
        XCTAssertEqual(engine.spent(in: "shopping"), 50)
        XCTAssertTrue(engine.isSplit(costco))
        XCTAssertEqual(engine.transactions(in: "groceries").map(\.id), [costco.id])
        XCTAssertEqual(engine.transactions(in: "shopping").map(\.id), [costco.id])
    }

    func testReviewInboxHoldsRecentUnapprovedSpending() {
        let old = txn("2026-09-01", 10, "ENTERTAINMENT")
        let approved = txn("2026-10-10", 20, "ENTERTAINMENT")
        let fresh = txn("2026-10-18", 30, "ENTERTAINMENT")
        let pay = txn("2026-10-16", -1000, "INCOME", "INCOME_WAGES")
        var pending = txn("2026-10-19", 5, "ENTERTAINMENT")
        pending.pending = true
        let engine = BudgetEngine(snapshot: snapshot(transactions: [old, approved, fresh, pay, pending]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today,
                                  reviewed: [approved.id])
        XCTAssertEqual(engine.toReview.map(\.id), [fresh.id])
    }

    // MARK: Targets

    private func budgets(with target: BucketTarget, assigned: Double = 0) -> (budgets: [BudgetCategory], id: String) {
        var budgets = BudgetCategory.defaults
        var bucket = BudgetCategory.custom(name: "Car insurance", isFixed: true, amount: assigned)
        bucket.target = target
        budgets.append(bucket)
        return (budgets, bucket.id)
    }

    func testSaveByTargetSpreadsWhatsMissing() throws {
        let setup = budgets(with: BucketTarget(kind: .saveBy, amount: 1200, by: "2027-03"))
        let engine = BudgetEngine(snapshot: snapshot(), budgets: setup.budgets, monthlySavingsGoal: 0, today: today)
        let bucket = try XCTUnwrap(engine.plan.buckets.first { $0.id == setup.id })
        // October through March is six months.
        XCTAssertEqual(bucket.targetThisMonth, 200)
        XCTAssertEqual(bucket.targetRemaining, 200)
        XCTAssertEqual(engine.plan.targetsRemaining, 200)
    }

    func testSaveByTargetCountsMoneyAlreadySaved() throws {
        let setup = budgets(with: BucketTarget(kind: .saveBy, amount: 1200, by: "2027-03"), assigned: 100)
        let engine = BudgetEngine(snapshot: snapshot(), budgets: setup.budgets, monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": [setup.id: 300]], budgetStart: "2026-09")
        let bucket = try XCTUnwrap(engine.plan.buckets.first { $0.id == setup.id })
        XCTAssertEqual(bucket.targetThisMonth, 150) // (1,200 - 300) / 6
        XCTAssertEqual(bucket.targetRemaining, 50) // 100 is already assigned
    }

    func testRefillTargetTopsUpWhatsLeft() throws {
        let setup = budgets(with: BucketTarget(kind: .refill, amount: 400), assigned: 300)
        let engine = BudgetEngine(snapshot: snapshot(), budgets: setup.budgets, monthlySavingsGoal: 0, today: today,
                                  assignments: ["2026-09": [setup.id: 100]], budgetStart: "2026-09")
        let bucket = try XCTUnwrap(engine.plan.buckets.first { $0.id == setup.id })
        XCTAssertEqual(bucket.targetThisMonth, 300)
        XCTAssertEqual(bucket.targetRemaining, 0)
    }

    func testPastDueTargetAsksForNothing() throws {
        let setup = budgets(with: BucketTarget(kind: .saveBy, amount: 500, by: "2026-09"))
        let engine = BudgetEngine(snapshot: snapshot(), budgets: setup.budgets, monthlySavingsGoal: 0, today: today)
        XCTAssertEqual(engine.plan.buckets.first { $0.id == setup.id }?.targetRemaining, 0)
    }

    // MARK: Insights

    func testAgeOfMoneyUsesOldestMoneyFirst() throws {
        // Checkpoint math: checking ends at 2,000. Pay of 1,000 on Sep 1 and
        // ten 10 dollar purchases on Sep 21-30, so opening money = 2,000 + 100 - 1,000 = 1,100
        // dated Sep 1 (first transaction) is spent first.
        var txns = [txn("2026-09-01", -1000, "INCOME", "INCOME_WAGES", name: "GLOBEX")]
        for day in 21...30 { txns.append(txn("2026-09-\(day)", 10, "ENTERTAINMENT")) }
        let engine = BudgetEngine(snapshot: snapshot(transactions: txns), budgets: BudgetCategory.defaults,
                                  monthlySavingsGoal: 0, today: today)
        // Every purchase is paid from money that arrived Sep 1: ages 20...29, average 24.5.
        XCTAssertEqual(try XCTUnwrap(engine.ageOfMoney), 25)
    }

    func testAgeOfMoneyNeedsTenPurchases() {
        let engine = BudgetEngine(snapshot: snapshot(transactions: [txn("2026-10-01", 10, "ENTERTAINMENT")]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        XCTAssertNil(engine.ageOfMoney)
    }

    func testReconcileFindsMoneyTransactionsDontExplain() {
        let checking = account("chk", type: "depository", subtype: "checking", balance: 1000)
        let old = txn("2026-10-01", 50, "ENTERTAINMENT")
        let checkpoint = Reconcile.checkpoint(for: checking, transactions: [old])
        XCTAssertEqual(checkpoint.balance, 1000)

        var later = checking
        later.currentBalance = 880
        let coffee = txn("2026-10-02", 20, "FOOD_AND_DRINK")
        // 1,000 - 20 should be 980; the bank says 880, so 100 is unexplained.
        XCTAssertEqual(Reconcile.drift(since: checkpoint, account: later, transactions: [old, coffee]), -100)
        later.currentBalance = 980
        XCTAssertEqual(Reconcile.drift(since: checkpoint, account: later, transactions: [old, coffee]), 0)
    }

    func testReconcileTreatsCardChargesAsMoreOwed() {
        let card = account("visa", type: "credit", subtype: "credit card", balance: 500)
        let checkpoint = Reconcile.checkpoint(for: card, transactions: [])
        var later = card
        later.currentBalance = 560
        let charge = txn("2026-10-02", 60, "GENERAL_MERCHANDISE", account: "visa")
        XCTAssertEqual(Reconcile.drift(since: checkpoint, account: later, transactions: [charge]), 0)
    }

    func testSpendingHistoryEndsThisMonth() {
        let engine = BudgetEngine(snapshot: snapshot(transactions: [dining("2026-09-10", 40), dining("2026-10-05", 25)]),
                                  budgets: BudgetCategory.defaults, monthlySavingsGoal: 0, today: today)
        let history = engine.spendingHistory(months: 3)
        XCTAssertEqual(history.map(\.id), ["2026-08", "2026-09", "2026-10"])
        XCTAssertEqual(history.map(\.total), [0, 40, 25])
        let trend = engine.bucketTrends().first { $0.id == "dining" }
        XCTAssertEqual(trend?.thisMonth, 25)
        XCTAssertEqual(trend?.usual, 40) // only September had spending
    }
}
