import Foundation
import Observation

/// App-wide state: the latest snapshot, the budget, and the chat. Persisted to
/// a JSON file so the app opens instantly with the last known numbers.
@Observable
@MainActor
final class AppStore {
    enum Tab: Hashable { case home, activity, ask, accounts }

    var snapshot: Snapshot?
    var budgets: [BudgetCategory] = BudgetCategory.defaults
    var monthlySavingsGoal: Double = 0
    /// Income sources the user confirmed, edited, ignored, or added.
    var incomeSources: [IncomeSource] = []
    /// Merchant key -> bucket id, set by moving a transaction to a bucket.
    var bucketRules: [String: String] = [:]
    /// Month ("yyyy-MM") -> bucket id -> amount, for months that differ from
    /// the repeating plan. Past months are written out in full when they close.
    var assignments: [String: [String: Double]] = [:]
    /// The budget's first month ("yyyy-MM"). Money rolls over from here on.
    var budgetStart: String?
    /// One-off bucket choices, by transaction id.
    var transactionBuckets: [String: String] = [:]
    /// Split transactions: transaction id -> bucket id -> amount.
    var splits: [String: [String: Double]] = [:]
    /// Transactions approved in the review inbox.
    var reviewed: Set<String> = []
    /// The month the Budget tab is showing.
    var viewMonth: Date = Day.startOfMonth(.now)
    var hasOnboarded = false
    var isDemo = false
    var chat: [ChatMessage] = []

    var selectedTab: Tab = .home
    var isRefreshing = false
    var isLinking = false
    var isAnswering = false
    var errorMessage: String?

    private let api = APIClient()
    private let plaid = PlaidLinkPresenter()

    /// Launched with `-uiPreview` (used by the screenshot job): demo data,
    /// nothing read from or written to disk. `-tab ask|activity|accounts`
    /// opens a tab and `-onboarding` shows onboarding instead.
    let isPreview: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        isPreview = args.contains("-uiPreview")
        guard isPreview else {
            load()
            return
        }
        startDemo()
        budgets = engine.suggestedBudgets()
        closePastMonths()
        hasOnboarded = !args.contains("-onboarding")
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
            selectedTab = ["activity": .activity, "ask": .ask, "accounts": .accounts][args[i + 1]] ?? .home
        }
        if selectedTab == .ask { chat = DemoData.sampleChat }
    }

    var engine: BudgetEngine {
        BudgetEngine(snapshot: snapshot ?? DemoData.empty, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal,
                     savedIncome: incomeSources, bucketRules: bucketRules, assignments: assignments, budgetStart: budgetStart,
                     transactionBuckets: transactionBuckets, splits: splits, reviewed: reviewed)
    }

    var institutions: [Institution] { snapshot?.institutions ?? [] }

    // MARK: Linking and syncing

    /// Runs Plaid Link, then pulls fresh data. Returns true if an account was linked.
    @discardableResult
    func linkAccount() async -> Bool {
        isLinking = true
        defer { isLinking = false }
        do {
            let token = try await api.linkToken()
            guard let linked = try await plaid.present(linkToken: token) else { return false }
            try await api.exchange(publicToken: linked.publicToken, institutionName: linked.institutionName)
            if isDemo {
                isDemo = false
                snapshot = nil
            }
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refresh() async {
        closePastMonths()
        guard !isDemo else {
            snapshot = DemoData.snapshot()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await api.snapshot()
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Right after linking, Plaid can take a little while to pull history.
    /// Poll until transactions show up, for up to about 30 seconds.
    func waitForTransactions() async {
        for _ in 0..<10 {
            await refresh()
            if let snapshot, !snapshot.transactions.isEmpty { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func unlink(_ institution: Institution) async {
        do {
            try await api.unlink(itemId: institution.itemId)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDemo() {
        isDemo = true
        snapshot = DemoData.snapshot()
        // Start the demo budget last month so rollover has something to show.
        budgetStart = Day.monthKey(Day.addMonths(-1, to: .now))
        // Leave the last few days in the review inbox.
        let cutoff = Day.string(Day.calendar.date(byAdding: .day, value: -4, to: .now)!)
        reviewed = Set(snapshot!.transactions.filter { $0.date < cutoff }.map(\.id))
    }

    // MARK: Budget

    func applySuggestedBudget() {
        closePastMonths()
        budgets = engine.suggestedBudgets()
        save()
    }

    /// Sets a bucket's repeating monthly amount, starting this month.
    func setBudget(_ id: String, amount: Double) {
        guard let index = budgets.firstIndex(where: { $0.id == id }) else { return }
        closePastMonths()
        budgets[index].monthlyAmount = max(0, amount)
        assignments[Day.monthKey(.now)]?[id] = nil
        save()
    }

    /// Assigns an amount to a bucket in one month. With `repeating`, it
    /// becomes the bucket's amount for every month from this one on.
    func setAssigned(_ id: String, in month: Date, amount: Double, repeating: Bool) {
        let key = Day.monthKey(month)
        closePastMonths()
        if repeating, key == Day.monthKey(.now) {
            setBudget(id, amount: amount)
            return
        }
        if repeating, key > Day.monthKey(.now), let index = budgets.firstIndex(where: { $0.id == id }) {
            // Months between now and then keep what they had.
            var m = Day.addMonths(0, to: .now)
            while Day.monthKey(m) < key {
                let mk = Day.monthKey(m)
                if assignments[mk]?[id] == nil { assignments[mk, default: [:]][id] = budgets[index].monthlyAmount }
                m = Day.addMonths(1, to: m)
            }
            budgets[index].monthlyAmount = max(0, amount)
            assignments[key]?[id] = nil
            save()
            return
        }
        assignments[key, default: [:]][id] = amount
        save()
    }

    func setTarget(_ id: String, _ target: BucketTarget?) {
        guard let index = budgets.firstIndex(where: { $0.id == id }) else { return }
        budgets[index].target = target
        save()
    }

    /// Assigns what every target still needs this month, bills first, until
    /// left to assign runs out. Returns how much it assigned.
    @discardableResult
    func fundTargets(in month: Date) -> Double {
        closePastMonths()
        let plan = engine.plan(for: month)
        var money = max(0, plan.leftToAssign)
        var total = 0.0
        let key = Day.monthKey(month)
        for bucket in plan.buckets where bucket.targetRemaining > 0.005 && money > 0.005 {
            let add = min(bucket.targetRemaining, money)
            assignments[key, default: [:]][bucket.id] = bucket.assigned + add
            money -= add
            total += add
        }
        save()
        return total
    }

    /// Moves money between buckets in a month. A nil bucket means "left to
    /// assign": moving from it assigns new money, moving to it un-assigns.
    func moveMoney(_ amount: Double, from: String?, to: String?, in month: Date) {
        guard amount > 0, from != to else { return }
        closePastMonths()
        let engine = self.engine
        let key = Day.monthKey(month)
        if let from {
            assignments[key, default: [:]][from] = engine.assigned(from, in: month) - amount
        }
        if let to {
            assignments[key, default: [:]][to] = engine.assigned(to, in: month) + amount
        }
        save()
    }

    func addBucket(_ category: BudgetCategory) {
        closePastMonths()
        budgets.append(category)
        save()
    }

    func updateBucket(_ category: BudgetCategory) {
        guard let index = budgets.firstIndex(where: { $0.id == category.id }) else { return }
        budgets[index] = category
        save()
    }

    func deleteBucket(_ id: String) {
        budgets.removeAll { $0.id == id }
        bucketRules = bucketRules.filter { $0.value != id }
        for key in assignments.keys { assignments[key]?[id] = nil }
        save()
    }

    /// Writes out every bucket's amount for each month that has ended, so
    /// later changes to the repeating plan don't rewrite history (and the
    /// rollover it produced).
    func closePastMonths() {
        let current = Day.monthKey(.now)
        guard let start = budgetStart else {
            if hasOnboarded || isPreview { budgetStart = current }
            return
        }
        var m = Day.month(start)
        var key = Day.monthKey(m)
        while key < current {
            for category in budgets where assignments[key]?[category.id] == nil {
                assignments[key, default: [:]][category.id] = category.monthlyAmount
            }
            m = Day.addMonths(1, to: m)
            key = Day.monthKey(m)
        }
    }

    /// Sends this merchant's transactions, past and future, to a bucket.
    func move(_ transaction: Transaction, to bucketId: String) {
        let key = MerchantKey.of(transaction.displayName)
        guard !key.isEmpty else { return }
        if BudgetCategory.categoryId(for: transaction) == bucketId {
            bucketRules[key] = nil
        } else {
            bucketRules[key] = bucketId
        }
        transactionBuckets[transaction.id] = nil
        save()
    }

    func bucket(for transaction: Transaction) -> BudgetCategory? {
        engine.bucketId(for: transaction).flatMap { id in budgets.first { $0.id == id } }
    }

    // MARK: Review

    /// Puts one transaction in a bucket. With `forMerchant`, every
    /// transaction from that merchant goes there too, now and later.
    /// Changing a transaction counts as reviewing it.
    func categorize(_ transaction: Transaction, as bucketId: String, forMerchant: Bool) {
        splits[transaction.id] = nil
        if forMerchant {
            move(transaction, to: bucketId)
        } else {
            let usual = BudgetCategory.bucketId(for: transaction, rules: bucketRules, budgets: budgets)
            transactionBuckets[transaction.id] = usual == bucketId ? nil : bucketId
        }
        reviewed.insert(transaction.id)
        save()
    }

    /// Splits a transaction over buckets. An empty split removes it.
    func split(_ transaction: Transaction, into parts: [String: Double]) {
        let parts = parts.filter { abs($0.value) > 0.005 }
        splits[transaction.id] = parts.count > 1 ? parts : nil
        if parts.count == 1, let only = parts.keys.first {
            transactionBuckets[transaction.id] = only
        }
        reviewed.insert(transaction.id)
        save()
    }

    func approve(_ transaction: Transaction) {
        reviewed.insert(transaction.id)
        save()
    }

    func approveAll() {
        reviewed.formUnion(engine.toReview.map(\.id))
        save()
    }

    // MARK: Income

    /// Saves a user's edit to an income source (detected or manual).
    func saveIncome(_ source: IncomeSource) {
        if let index = incomeSources.firstIndex(where: { $0.id == source.id }) {
            incomeSources[index] = source
        } else {
            incomeSources.append(source)
        }
        save()
    }

    func setIncomeStatus(_ source: IncomeSource, _ status: IncomeSource.Status) {
        var source = source
        source.status = status
        saveIncome(source)
    }

    /// Manual sources are removed; detected ones go back to being auto-detected.
    func forgetIncome(_ source: IncomeSource) {
        incomeSources.removeAll { $0.id == source.id }
        save()
    }

    func finishOnboarding() {
        hasOnboarded = true
        if budgetStart == nil { budgetStart = Day.monthKey(.now) }
        // The inbox is for what comes in from now on.
        if !isDemo, let snapshot { reviewed.formUnion(snapshot.transactions.map(\.id)) }
        closePastMonths()
        save()
    }

    func resetEverything() {
        snapshot = nil
        budgets = BudgetCategory.defaults
        monthlySavingsGoal = 0
        incomeSources = []
        bucketRules = [:]
        assignments = [:]
        budgetStart = nil
        transactionBuckets = [:]
        splits = [:]
        reviewed = []
        viewMonth = Day.startOfMonth(.now)
        hasOnboarded = false
        isDemo = false
        chat = []
        selectedTab = .home
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: Chat

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        chat.append(ChatMessage(role: .user, content: trimmed))
        let history = chat
        chat.append(ChatMessage(role: .assistant, content: ""))
        let replyIndex = chat.count - 1
        isAnswering = true
        defer {
            isAnswering = false
            save()
        }
        do {
            for try await chunk in api.chat(messages: history, context: engine.chatContext()) {
                chat[replyIndex].content += chunk
            }
        } catch {
            chat[replyIndex].isError = true
            if chat[replyIndex].content.isEmpty {
                chat[replyIndex].content = error.localizedDescription
            }
        }
    }

    func clearChat() {
        chat = []
        save()
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var snapshot: Snapshot?
        var budgets: [BudgetCategory]
        var monthlySavingsGoal: Double
        // Optional so state saved by earlier versions still loads.
        var incomeSources: [IncomeSource]?
        var bucketRules: [String: String]?
        var assignments: [String: [String: Double]]?
        var budgetStart: String?
        var transactionBuckets: [String: String]?
        var splits: [String: [String: Double]]?
        var reviewed: [String]?
        var hasOnboarded: Bool
        var isDemo: Bool
        var chat: [ChatMessage]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "runway-state.json")
    }

    /// Review marks only matter for recent transactions; drop the rest so the file stays small.
    private var prunedReviewed: [String] {
        guard let snapshot else { return Array(reviewed) }
        let recent = Set(snapshot.transactions.map(\.id))
        return reviewed.filter(recent.contains)
    }

    func save() {
        guard !isPreview else { return }
        let state = Persisted(snapshot: isDemo ? nil : snapshot, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal,
                              incomeSources: incomeSources, bucketRules: bucketRules,
                              assignments: assignments, budgetStart: budgetStart,
                              transactionBuckets: transactionBuckets, splits: splits, reviewed: prunedReviewed, hasOnboarded: hasOnboarded, isDemo: isDemo, chat: Array(chat.suffix(100)))
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("Couldn't save state: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let state = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        isDemo = state.isDemo
        snapshot = state.isDemo ? DemoData.snapshot() : state.snapshot
        budgets = state.budgets
        monthlySavingsGoal = state.monthlySavingsGoal
        incomeSources = state.incomeSources ?? []
        bucketRules = state.bucketRules ?? [:]
        assignments = state.assignments ?? [:]
        budgetStart = state.budgetStart
        transactionBuckets = state.transactionBuckets ?? [:]
        splits = state.splits ?? [:]
        reviewed = Set(state.reviewed ?? [])
        // First open with the review inbox: start it empty instead of
        // asking about everything already in the history.
        if state.reviewed == nil, let snapshot = state.snapshot { reviewed = Set(snapshot.transactions.map(\.id)) }
        hasOnboarded = state.hasOnboarded
        chat = state.chat
        // Existing budgets start rolling over from the month this version first opens.
        closePastMonths()
    }
}

extension DemoData {
    static let empty = Snapshot(syncedAt: "", institutions: [], accounts: [], transactions: [], creditCards: [], recurring: [])
}
