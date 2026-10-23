import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var addingBucket = false
    @State private var path = NavigationPath()

    private enum Route: Hashable { case income }

    var body: some View {
        let engine = store.engine
        let plan = engine.plan
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SafeToSpendCard(safe: engine.safeToSpend)

                    QuickAsk()

                    NavigationLink(value: Route.income) {
                        PlanCard(plan: plan, unreviewed: engine.unreviewedIncome.count)
                    }
                    .buttonStyle(.plain)

                    let plans = engine.cardPlans
                    if !plans.isEmpty {
                        SectionHeader(title: "Credit cards", trailing: "Pay to avoid interest")
                        ForEach(plans) { CardPlanRow(plan: $0) }
                    }

                    let bills = plan.buckets.filter { $0.category.isFixed && ($0.assigned > 0 || $0.spent > 0) }
                    if !bills.isEmpty {
                        SectionHeader(title: "Bills", trailing: "\(engine.billsRemaining.currency()) left to pay")
                        Card {
                            ForEach(bills) { CategoryRow(funding: $0) }
                        }
                    }

                    let flexible = plan.buckets.filter { !$0.category.isFixed && ($0.assigned > 0 || $0.spent > 0) }
                    SectionHeader(title: "Spending", trailing: Date.now.formatted(.dateTime.month(.wide)))
                    Card {
                        ForEach(flexible) { CategoryRow(funding: $0) }
                        if flexible.isEmpty {
                            Text("No spending yet this month.").foregroundStyle(.secondary)
                        }
                    }

                    let empty = plan.buckets.filter { $0.assigned == 0 && $0.spent == 0 }
                    HStack {
                        Button("New bucket", systemImage: "plus.circle.fill") { addingBucket = true }
                        Spacer()
                        if !empty.isEmpty {
                            Menu {
                                Section("Assign money to") {
                                    ForEach(empty) { bucket in
                                        Button(bucket.category.name, systemImage: bucket.category.symbol) { path.append(bucket.category) }
                                    }
                                }
                            } label: {
                                Text("\(empty.count) empty buckets").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Budget")
            .navigationDestination(for: BudgetCategory.self) { CategoryDetailView(categoryId: $0.id) }
            .navigationDestination(for: Route.self) { _ in IncomeView() }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $addingBucket) { NewBucketSheet() }
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
            if safe.expectedIncome > 0 {
                Label(safe.inHand >= 0
                      ? "Counts \(safe.expectedIncome.currency()) of pay that hasn't arrived yet. \(safe.inHand.currency()) is money you already have."
                      : "Counts \(safe.expectedIncome.currency()) of pay that hasn't arrived yet. Until it does, you're \((-safe.inHand).currency()) short.",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }

            if expanded {
                VStack(spacing: 8) {
                    BreakdownRow(label: "Cash in checking", value: safe.cash)
                    if safe.expectedIncome > 0 {
                        BreakdownRow(label: "Paychecks still coming (projected)", value: safe.expectedIncome)
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
            switch plan.funding {
            case .paycheck(let date):
                Label("Covered once your \(date.shortDay) paycheck lands", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            case .short(let amount):
                Label("\(amount.currency(cents: true)) short, even counting paychecks before the due date", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.negative)
            case .cashOnHand, .nothingDue:
                EmptyView()
            }
            if plan.newSpending > 0 {
                Text("\(plan.newSpending.currency(cents: true)) in new charges goes on the next statement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CategoryRow: View {
    var funding: BudgetEngine.BucketFunding

    private var category: BudgetCategory { funding.category }
    private var spent: Double { funding.spent }

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
                    if funding.fromExpected > 0.5, let date = funding.waitingOn {
                        Label("\(funding.fromExpected.currency()) waits on \(date.shortDay) pay", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

/// This month's income (arrived vs. projected) and how much is left to assign.
private struct PlanCard: View {
    var plan: BudgetEngine.Plan
    var unreviewed: Int

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Date.now.formatted(.dateTime.month(.wide))) income").font(.headline)
                Spacer()
                Text(plan.income.currency()).font(.headline).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            IncomeBar(arrived: plan.arrived, expected: plan.expected)
            HStack(spacing: 14) {
                Legend(color: Theme.positive, text: "\(plan.arrived.currency()) arrived")
                Legend(color: Theme.positive.opacity(0.35), text: "\(plan.expected.currency()) expected")
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.leftToAssign >= 0 ? "Left to assign" : "Over-assigned")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(abs(plan.leftToAssign).currency())
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(plan.leftToAssign >= 0 ? Color.primary : Theme.negative)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Assigned").font(.caption).foregroundStyle(.secondary)
                    Text((plan.assigned + plan.savingsGoal).currency()).font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            if plan.assignedFromExpected > 0.5 {
                Text("\(plan.assignedFromExpected.currency()) of what you've assigned is waiting on pay that hasn't arrived yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if unreviewed > 0 {
                Label(unreviewed == 1 ? "Review 1 detected income source" : "Review \(unreviewed) detected income sources",
                      systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Solid for income that's in the account, faded for income that's projected.
struct IncomeBar: View {
    var arrived: Double
    var expected: Double

    var body: some View {
        GeometryReader { geo in
            let total = max(1, arrived + expected)
            HStack(spacing: 2) {
                if arrived > 0 {
                    Capsule().fill(Theme.positive).frame(width: max(6, geo.size.width * arrived / total))
                }
                if expected > 0 {
                    Capsule().fill(Theme.positive.opacity(0.35))
                }
                if arrived + expected <= 0 {
                    Capsule().fill(Color(.tertiarySystemFill))
                }
            }
        }
        .frame(height: 8)
    }
}

private struct Legend: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct NewBucketSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amountText = ""
    @State private var isBill = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, like Gifts or Car repairs", text: $name)
                HStack {
                    Text("Assign each month")
                    Spacer()
                    TextField("$0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
                Section {
                    Toggle("It's a bill", isOn: $isBill)
                } footer: {
                    Text("Unpaid bills are set aside from safe to spend until they're paid. To fill this bucket, long-press a transaction in Activity and move it here.")
                }
            }
            .navigationTitle("New bucket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
                        store.addBucket(.custom(name: name.trimmingCharacters(in: .whitespaces), isFixed: isBill, amount: max(0, amount)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
