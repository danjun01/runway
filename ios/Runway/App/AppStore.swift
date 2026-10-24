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
    var plannedExpenses: [PlannedExpense] = []
    var taxSettings = TaxSettings()
    var dailySummaryEnabled = false
    /// Minutes after midnight for the daily summary.
    var dailySummaryMinutes = 9 * 60
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
        hasOnboarded = !args.contains("-onboarding")
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
            selectedTab = ["activity": .activity, "ask": .ask, "accounts": .accounts][args[i + 1]] ?? .home
        }
        if selectedTab == .ask { chat = DemoData.sampleChat }
    }

    var engine: BudgetEngine {
        BudgetEngine(snapshot: snapshot ?? DemoData.empty, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal,
                     savedIncome: incomeSources, bucketRules: bucketRules, countsDetectedIncome: isDemo,
                     plannedExpenses: plannedExpenses, taxSettings: taxSettings)
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
        guard !isDemo else {
            snapshot = DemoData.snapshot()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await api.snapshot()
            save()
            await updateDailySummary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Background app refresh: pull new data quietly so tomorrow's summary is current.
    func refreshInBackground() async {
        guard hasOnboarded, !isDemo, let fresh = try? await api.snapshot() else { return }
        snapshot = fresh
        save()
        await updateDailySummary()
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
    }

    // MARK: Budget

    func applySuggestedBudget() {
        budgets = engine.suggestedBudgets()
        save()
    }

    func setBudget(_ id: String, amount: Double) {
        guard let index = budgets.firstIndex(where: { $0.id == id }) else { return }
        budgets[index].monthlyAmount = max(0, amount)
        save()
    }

    func addBucket(_ category: BudgetCategory) {
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
        save()
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
        save()
    }

    func bucket(for transaction: Transaction) -> BudgetCategory? {
        BudgetCategory.bucketId(for: transaction, rules: bucketRules, budgets: budgets)
            .flatMap { id in budgets.first { $0.id == id } }
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

    // MARK: Planning ahead

    func savePlanned(_ expense: PlannedExpense) {
        if let index = plannedExpenses.firstIndex(where: { $0.id == expense.id }) {
            plannedExpenses[index] = expense
        } else {
            plannedExpenses.append(expense)
        }
        save()
    }

    func deletePlanned(_ id: String) {
        plannedExpenses.removeAll { $0.id == id }
        save()
    }

    func setTaxSettings(_ settings: TaxSettings) {
        taxSettings = settings
        save()
    }

    // MARK: Daily summary

    /// Turns the morning notification on (asking for permission) or off.
    func setDailySummary(enabled: Bool) async {
        if enabled {
            guard await DailySummary.requestPermission() else {
                dailySummaryEnabled = false
                errorMessage = "Notifications are off for Runway. Turn them on in Settings to get a daily summary."
                return
            }
        }
        dailySummaryEnabled = enabled
        save()
        await updateDailySummary()
    }

    func setDailySummaryTime(minutes: Int) async {
        dailySummaryMinutes = minutes
        save()
        await updateDailySummary()
    }

    /// Reschedules the next summary with the latest numbers.
    func updateDailySummary() async {
        guard dailySummaryEnabled, hasOnboarded, !isPreview else {
            DailySummary.cancel()
            return
        }
        await DailySummary.schedule(engine: engine, minutes: dailySummaryMinutes)
    }

    func finishOnboarding() {
        hasOnboarded = true
        save()
    }

    func resetEverything() {
        snapshot = nil
        budgets = BudgetCategory.defaults
        monthlySavingsGoal = 0
        incomeSources = []
        bucketRules = [:]
        plannedExpenses = []
        taxSettings = TaxSettings()
        dailySummaryEnabled = false
        DailySummary.cancel()
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
        var plannedExpenses: [PlannedExpense]?
        var taxSettings: TaxSettings?
        var dailySummaryEnabled: Bool?
        var dailySummaryMinutes: Int?
        var hasOnboarded: Bool
        var isDemo: Bool
        var chat: [ChatMessage]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "runway-state.json")
    }

    func save() {
        guard !isPreview else { return }
        let state = Persisted(snapshot: isDemo ? nil : snapshot, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal,
                              incomeSources: incomeSources, bucketRules: bucketRules,
                              plannedExpenses: plannedExpenses, taxSettings: taxSettings,
                              dailySummaryEnabled: dailySummaryEnabled, dailySummaryMinutes: dailySummaryMinutes, hasOnboarded: hasOnboarded, isDemo: isDemo, chat: Array(chat.suffix(100)))
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
        plannedExpenses = state.plannedExpenses ?? []
        taxSettings = state.taxSettings ?? TaxSettings()
        dailySummaryEnabled = state.dailySummaryEnabled ?? false
        dailySummaryMinutes = state.dailySummaryMinutes ?? 9 * 60
        hasOnboarded = state.hasOnboarded
        chat = state.chat
    }
}

extension DemoData {
    static let empty = Snapshot(syncedAt: "", institutions: [], accounts: [], transactions: [], creditCards: [], recurring: [])
}
