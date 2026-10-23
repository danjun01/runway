import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let engine = store.engine
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SafeToSpendCard(safe: engine.safeToSpend)

                    QuickAsk()

                    let plans = engine.cardPlans
                    if !plans.isEmpty {
                        SectionHeader(title: "Credit cards", trailing: "Pay to avoid interest")
                        ForEach(plans) { CardPlanRow(plan: $0) }
                    }

                    let bills = store.budgets.filter { $0.isFixed && ($0.monthlyAmount > 0 || engine.spent(in: $0.id) > 0) }
                    if !bills.isEmpty {
                        SectionHeader(title: "Bills", trailing: "\(engine.billsRemaining.currency()) left to pay")
                        Card {
                            ForEach(bills) { CategoryRow(category: $0, spent: engine.spent(in: $0.id)) }
                        }
                    }

                    let flexible = store.budgets.filter { !$0.isFixed && ($0.monthlyAmount > 0 || engine.spent(in: $0.id) > 0) }
                    SectionHeader(title: "Spending", trailing: Date.now.formatted(.dateTime.month(.wide)))
                    Card {
                        ForEach(flexible) { CategoryRow(category: $0, spent: engine.spent(in: $0.id)) }
                        if flexible.isEmpty {
                            Text("No spending yet this month.").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Budget")
            .navigationDestination(for: BudgetCategory.self) { CategoryDetailView(categoryId: $0.id) }
            .refreshable { await store.refresh() }
            .toolbar {
                if store.isDemo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("Demo").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.warning.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
    }
}

private struct SafeToSpendCard: View {
    var safe: BudgetEngine.SafeToSpend
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safe to spend").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            Text(safe.amount.currency())
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(safe.amount > 0
                 ? "\(safe.perDay.currency()) a day for the next \(safe.daysLeft) days"
                 : "You're over by \((-safe.amount).currency()). Ask Runway for a plan.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))

            if expanded {
                VStack(spacing: 8) {
                    BreakdownRow(label: "Cash in checking", value: safe.cash)
                    if safe.expectedIncome > 0 {
                        BreakdownRow(label: "Paychecks before month end", value: safe.expectedIncome)
                    }
                    BreakdownRow(label: "Owed on credit cards", value: -safe.creditCardBalances)
                    BreakdownRow(label: "Bills still to pay", value: -safe.billsRemaining)
                    if safe.savingsGoal > 0 {
                        BreakdownRow(label: "Savings goal", value: -safe.savingsGoal)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Label(expanded ? "Hide math" : "How is this calculated?", systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.top, 8)
    }
}

private struct BreakdownRow: View {
    var label: String
    var value: Double

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text((value >= 0 ? "+" : "\u{2212}") + abs(value).currency()).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.white)
    }
}

private struct QuickAsk: View {
    @Environment(AppStore.self) private var store
    private let prompts = [
        "How much can I spend this weekend?",
        "What should I pay on my cards?",
        "Can I afford a $300 trip?",
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        store.selectedTab = .ask
                        Task { await store.ask(prompt) }
                    } label: {
                        Label(prompt, systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

private struct CardPlanRow: View {
    var plan: BudgetEngine.CardPlan

    var body: some View {
        Card {
            HStack {
                CategoryIcon(symbol: "creditcard.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.account.displayName).font(.body.weight(.semibold))
                    Text(plan.account.institution).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(plan.currentBalance.currency(cents: true)).font(.body.weight(.semibold)).monospacedDigit()
                    Text("balance").font(.caption).foregroundStyle(.secondary)
                }
            }
            if plan.payToAvoidInterest > 0 {
                HStack(spacing: 6) {
                    Image(systemName: plan.isOverdue ? "exclamationmark.triangle.fill" : "calendar")
                        .foregroundStyle(plan.isOverdue ? Theme.negative : Theme.accent)
                    if let due = plan.dueDate {
                        Text("Pay **\(plan.payToAvoidInterest.currency(cents: true))** by \(due.shortDay)")
                    } else {
                        Text("Pay **\(plan.payToAvoidInterest.currency(cents: true))** to clear the statement")
                    }
                }
                .font(.subheadline)
            } else {
                Label("Statement paid. Nice.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Theme.positive)
            }
            if plan.newSpending > 0 {
                Text("\(plan.newSpending.currency(cents: true)) in new charges goes on the next statement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CategoryRow: View {
    var category: BudgetCategory
    var spent: Double

    var body: some View {
        NavigationLink(value: category) {
            HStack(spacing: 12) {
                CategoryIcon(symbol: category.symbol)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(category.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(remainingText).font(.subheadline).monospacedDigit()
                            .foregroundStyle(spent > category.monthlyAmount && category.monthlyAmount > 0 ? Theme.negative : .secondary)
                    }
                    BudgetBar(spent: spent, budget: category.monthlyAmount)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var remainingText: String {
        guard category.monthlyAmount > 0 else { return "\(spent.currency()) spent" }
        let left = category.monthlyAmount - spent
        return left >= 0 ? "\(left.currency()) left" : "\((-left).currency()) over"
    }
}
