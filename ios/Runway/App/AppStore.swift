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

    init() {
        load()
    }

    var engine: BudgetEngine {
        BudgetEngine(snapshot: snapshot ?? DemoData.empty, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal)
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

    func finishOnboarding() {
        hasOnboarded = true
        save()
    }

    func resetEverything() {
        snapshot = nil
        budgets = BudgetCategory.defaults
        monthlySavingsGoal = 0
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
        var hasOnboarded: Bool
        var isDemo: Bool
        var chat: [ChatMessage]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "runway-state.json")
    }

    func save() {
        let state = Persisted(snapshot: isDemo ? nil : snapshot, budgets: budgets, monthlySavingsGoal: monthlySavingsGoal,
                              hasOnboarded: hasOnboarded, isDemo: isDemo, chat: Array(chat.suffix(100)))
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
        hasOnboarded = state.hasOnboarded
        chat = state.chat
    }
}

extension DemoData {
    static let empty = Snapshot(syncedAt: "", institutions: [], accounts: [], transactions: [], creditCards: [], recurring: [])
}
