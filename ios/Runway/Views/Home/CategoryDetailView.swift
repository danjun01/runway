import SwiftUI

struct CategoryDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var categoryId: String
    @State private var amountText = ""
    @State private var repeating = true
    @FocusState private var editing: Bool
    @State private var confirmDelete = false
    @State private var moving: MoveRequest?

    private struct MoveRequest: Identifiable {
        var from: String?
        var to: String?
        var amount: Double
        var title: String
        var id: String { title }
    }

    var body: some View {
        let engine = store.engine
        let month = store.viewMonth
        let monthName = month.formatted(.dateTime.month(.wide))
        let isPast = Day.monthKey(month) < engine.currentMonthKey
        let category = store.budgets.first { $0.id == categoryId } ?? BudgetCategory.defaults[0]
        let plan = engine.plan(for: month)
        let funding = plan.buckets.first { $0.id == categoryId }
        let transactions = engine.transactions(in: categoryId, month: month)

        List {
            if let funding {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            CategoryIcon(symbol: category.symbol, color: funding.isOverspent ? Theme.negative : Theme.accent)
                            Text(funding.isOverspent ? "Overspent in \(monthName)" : "Available in \(monthName)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(abs(funding.available).currency(cents: true))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(funding.isOverspent ? Theme.negative : Color.primary)
                        BudgetBar(spent: funding.spent, budget: funding.funded)
                        VStack(spacing: 6) {
                            if abs(funding.carried) > 0.005 {
                                AmountLine(label: "Rolled over", value: funding.carried)
                            }
                            AmountLine(label: "Assigned in \(monthName)", value: funding.assigned)
                            AmountLine(label: "Spent", value: -funding.spent)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 6)

                    if funding.isOverspent {
                        Button("Cover \((-funding.available).currency(cents: true))", systemImage: "arrow.down.circle.fill") {
                            moving = MoveRequest(from: plan.bestSource(toCover: -funding.available, excluding: categoryId),
                                                 to: categoryId, amount: -funding.available, title: "Cover \(category.name)")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    Button("Move money", systemImage: "arrow.left.arrow.right") {
                        moving = MoveRequest(from: categoryId, to: nil, amount: 0, title: "Move from \(category.name)")
                    }
                    .font(.subheadline.weight(.semibold))
                } footer: {
                    if funding.carried > 0.5 {
                        Text("Unspent money stays in this bucket from month to month.")
                    }
                }
            }

            Section {
                HStack {
                    Text("$").foregroundStyle(.secondary)
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($editing)
                        .onSubmit(commit)
                    if editing {
                        Button("Save", action: commit).font(.subheadline.weight(.semibold))
                    }
                }
                if !isPast {
                    Toggle("Same amount every month", isOn: $repeating)
                }
                if category.isCustom {
                    Toggle("It's a bill", isOn: Binding(
                        get: { category.isFixed },
                        set: { isBill in
                            var updated = category
                            updated.isFixed = isBill
                            store.updateBucket(updated)
                        }
                    ))
                }
            } header: {
                Text("Assigned in \(monthName)")
            } footer: {
                if let funding, funding.assigned > 0, !isPast {
                    Text(fundingText(funding))
                } else if !isPast && repeating {
                    Text("Your plan repeats on its own each month, so you don't have to assign it again.")
                }
            }

            Section {
                ForEach(transactions) { TransactionRow(transaction: $0) }
            } header: {
                Text(transactions.isEmpty ? "No transactions in \(monthName)" : monthName)
            } footer: {
                Text("Long-press a transaction to move that merchant to a different bucket.")
            }

            if category.isCustom {
                Section {
                    Button("Delete bucket", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncFields() }
        .onChange(of: funding?.assigned) { _, _ in if !editing { syncFields() } }
        .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
        .onChange(of: repeating) { _, _ in commit() }
        .sheet(item: $moving) { request in
            MoveMoneySheet(month: month, from: request.from, to: request.to, amount: request.amount, title: request.title)
        }
        .confirmationDialog("Delete \(category.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteBucket(categoryId)
                dismiss()
            }
        } message: {
            Text("Its transactions go back to their usual buckets.")
        }
    }

    private func syncFields() {
        let engine = store.engine
        amountText = engine.assigned(categoryId, in: store.viewMonth).plainAmount
        repeating = engine.assignments[Day.monthKey(store.viewMonth)]?[categoryId] == nil
    }

    private func fundingText(_ funding: BudgetEngine.BucketFunding) -> String {
        if funding.fromExpected < 0.5 {
            return "Fully backed by income that's already arrived."
        }
        let waiting = "\(funding.fromExpected.currency()) is waiting on pay that hasn't arrived yet"
        let when = funding.waitingOn.map { " (\($0.shortDay))" } ?? ""
        if funding.fromArrived < 0.5 {
            return "All of it is planned from projected income. " + waiting + when + "."
        }
        return "\(funding.fromArrived.currency()) is backed by income that's arrived; " + waiting + when + "."
    }

    private func commit() {
        editing = false
        guard let value = Double(amountText.replacingOccurrences(of: ",", with: "")) else { return }
        let month = store.viewMonth
        let isPast = Day.monthKey(month) < store.engine.currentMonthKey
        let current = store.engine.assigned(categoryId, in: month)
        let followsPlan = store.engine.assignments[Day.monthKey(month)]?[categoryId] == nil
        // Nothing changed: don't turn a repeating amount into a one-off.
        if abs(value - current) < 0.005 && repeating == followsPlan { return }
        store.setAssigned(categoryId, in: month, amount: max(0, value), repeating: repeating && !isPast)
    }
}

private struct AmountLine: View {
    var label: String
    var value: Double

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text((value >= 0 ? "" : "\u{2212}") + abs(value).currency(cents: true)).monospacedDigit()
        }
        .font(.subheadline)
    }
}

struct TransactionRow: View {
    @Environment(AppStore.self) private var store
    var transaction: Transaction

    var body: some View {
        let category = store.bucket(for: transaction)
        HStack(spacing: 12) {
            CategoryIcon(symbol: category?.symbol ?? (transaction.amount < 0 ? "arrow.down.left" : "arrow.left.arrow.right"),
                         color: transaction.amount < 0 ? Theme.positive : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(transaction.pending ? "Pending" : (category?.name ?? (transaction.category == "INCOME" ? "Income" : "Transfer")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(transaction.amount < 0 ? "+" + (-transaction.amount).currency(cents: true) : transaction.amount.currency(cents: true))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(transaction.amount < 0 ? Theme.positive : .primary)
        }
        .contextMenu {
            if transaction.category != "INCOME" && transaction.detailedCategory != "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" {
                Section("Move \(transaction.displayName) to") {
                    ForEach(store.budgets) { bucket in
                        Button {
                            store.move(transaction, to: bucket.id)
                        } label: {
                            if bucket.id == category?.id {
                                Label(bucket.name, systemImage: "checkmark")
                            } else {
                                Text(bucket.name)
                            }
                        }
                    }
                }
            }
        }
    }
}
