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
                    SafeToSpendCard(safe: engine.safeToSpend, engine: engine,
                                    unconfirmedPay: store.isDemo ? 0 : engine.unreviewedIncome.filter { $0.status == .detected }.count)

                    QuickAsk()

                    NavigationLink(value: Route.income) {
                        PlanCard(plan: plan, unreviewed: engine.unreviewedIncome.count)
                    }
                    .buttonStyle(.plain)

                    let upcoming = engine.upcomingBills
                    if !upcoming.isEmpty {
                        SectionHeader(title: "Coming up before month end",
                                      trailing: "\(upcoming.reduce(0) { $0 + $1.amount }.currency())")
                        Card {
                            let cardIds = Set(engine.creditAccounts.map(\.id))
                            ForEach(upcoming) { bill in UpcomingBillRow(bill: bill, onCard: cardIds.contains(bill.accountId)) }
                        }
                    }

                    let plans = engine.cardPlans
                    if !plans.isEmpty {
                        SectionHeader(title: "Credit cards", trailing: "Pay to avoid interest")
                        ForEach(plans) { CardPlanRow(plan: $0) }
                        Text("Card balances are already set aside in Safe to spend, and card purchases count in their buckets like debit. There's nothing to assign to a card; just pay what's shown.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
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

                    if store.snapshot != nil && !store.isDemo {
                        SyncStatus().padding(.horizontal, 4).padding(.top, 8)
                    }
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
    var engine: BudgetEngine
    /// Detected paychecks waiting for confirmation; they don't count yet.
    var unconfirmedPay = 0
    @State private var expanded = false
    @State private var showAfford = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safe to spend").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            Text(safe.amount.currency())
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(safe.amount > 0
                 ? "\(safe.perDay.currency()) a day for the next \(safe.daysLeft) days"
                 : unconfirmedPay > 0
                 ? "Your paychecks aren't counted yet. Review them below."
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

            if unconfirmedPay > 0 {
                Label(unconfirmedPay == 1
                      ? "Doesn't count a paycheck Runway found until you confirm it below."
                      : "Doesn't count \(unconfirmedPay) paychecks Runway found until you confirm them below.",
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let warning = timingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if expanded {
                VStack(spacing: 8) {
                    BreakdownRow(label: "Cash in checking", value: safe.cash)
                    if safe.expectedIncome > 0 {
                        BreakdownRow(label: "Paychecks still coming (projected)", value: safe.expectedIncome)
                    }
                    BreakdownRow(label: safe.pendingCardCharges > 0
                                 ? "Owed on cards, incl. \(safe.pendingCardCharges.currency()) pending"
                                 : "Owed on credit cards",
                                 value: -safe.creditCardBalances)
                    BreakdownRow(label: "Bills still to pay", value: -safe.billsRemaining)
                    if safe.savingsGoal > 0 {
                        BreakdownRow(label: "Savings goal", value: -safe.savingsGoal)
                    }
                    if safe.lowPoint.balance < safe.cash {
                        Divider().overlay(.white.opacity(0.4))
                        HStack {
                            Text("Lowest checking balance, \(safe.lowPoint.date.shortDay)")
                            Spacer()
                            Text(safe.lowPoint.balance.currency()).monospacedDigit()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showAfford {
                AffordCheck(engine: engine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Hide math" : "How is this calculated?", systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { showAfford.toggle() }
                } label: {
                    Text(showAfford ? "Done" : "Can I afford it?")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.top, 8)
    }

    /// Shown when a bill or card payment due before payday would pull checking
    /// below the month's number, or below zero. (Pay that simply hasn't arrived
    /// yet is covered by the note above.)
    private var timingWarning: String? {
        let low = safe.lowPoint
        guard let cause = low.cause else { return nil }
        let when = "on \(low.date.shortDay), when \(cause) is due"
        if low.balance < 0 {
            return "Checking is on track to go \((-low.balance).currency()) negative \(when). Move money in before then."
        }
        guard safe.isTimingLimited else { return nil }
        let untilPaycheck = low.nextPaycheck.map { " until your paycheck on \($0.shortDay)" } ?? ""
        return "Only \(safe.spendableNow.currency()) of this is free\(untilPaycheck). Checking dips to \(low.balance.currency()) \(when)."
    }
}

/// "Can I afford $X?", answered on the spot from the same numbers.
private struct AffordCheck: View {
    @Environment(AppStore.self) private var store
    var engine: BudgetEngine
    @State private var text = ""
    @FocusState private var focused: Bool

    private var cost: Double? {
        Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(.white.opacity(0.8))
                TextField("", text: $text, prompt: Text("Amount").foregroundStyle(.white.opacity(0.6)))
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .foregroundStyle(.white)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let cost {
                answer(for: cost)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func answer(for cost: Double) -> some View {
        switch engine.canAfford(cost) {
        case .yes(let left, let perDay):
            Label("Yes. You'd have \(left.currency()) left this month, about \(perDay.currency()) a day.",
                  systemImage: "checkmark.circle.fill")
        case .afterPaycheck(let payday, let now):
            Label("Yes, after your paycheck on \(payday.shortDay). Before then, only \(now.currency()) is free without checking going negative.",
                  systemImage: "clock.fill")
        case .no(let over):
            VStack(alignment: .leading, spacing: 8) {
                Label("Not this month. It's \(over.currency()) more than you can spend safely.", systemImage: "xmark.circle.fill")
                Button {
                    focused = false
                    store.selectedTab = .ask
                    Task { await store.ask("I want to spend \(cost.currency(cents: true)). How could I make that work?") }
                } label: {
                    Label("Ask Runway for a plan", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct UpcomingBillRow: View {
    @Environment(AppStore.self) private var store
    var bill: BudgetEngine.UpcomingBill
    var onCard: Bool

    var body: some View {
        let symbol = bill.bucketId.flatMap { id in store.budgets.first { $0.id == id }?.symbol } ?? "doc.text.fill"
        HStack(spacing: 12) {
            CategoryIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(onCard ? "\(bill.date.relativeDay), on a card" : bill.date.relativeDay)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(bill.amount.currency(cents: true)).font(.subheadline).monospacedDigit()
        }
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
            if plan.pendingCharges > 0 {
                Text("Plus \(plan.pendingCharges.currency(cents: true)) pending, already set aside.")
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
