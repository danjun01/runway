import SwiftUI

struct CategoryDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var categoryId: String
    @State private var amountText = ""
    @FocusState private var editing: Bool
    @State private var confirmDelete = false

    var body: some View {
        let engine = store.engine
        let category = store.budgets.first { $0.id == categoryId } ?? BudgetCategory.defaults[0]
        let spent = engine.spent(in: categoryId)
        let transactions = engine.transactions(in: categoryId)
        let funding = engine.funding(for: categoryId)

        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CategoryIcon(symbol: category.symbol)
                        Text(category.isFixed ? "Bill" : "Flexible spending")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\(spent.currency()) of \(category.monthlyAmount.currency())")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    BudgetBar(spent: spent, budget: category.monthlyAmount)
                }
                .padding(.vertical, 6)
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
                Text("Assigned each month")
            } footer: {
                if let funding, funding.assigned > 0 {
                    Text(fundingText(funding))
                }
            }

            Section {
                ForEach(transactions) { TransactionRow(transaction: $0) }
            } header: {
                Text(transactions.isEmpty ? "No transactions this month" : "This month")
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
        .onAppear { amountText = String(Int(category.monthlyAmount)) }
        .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
        .confirmationDialog("Delete \(category.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteBucket(categoryId)
                dismiss()
            }
        } message: {
            Text("Its transactions go back to their usual buckets.")
        }
    }

    private func fundingText(_ funding: BudgetEngine.BucketFunding) -> String {
        if funding.fromExpected < 0.5 {
            return "Fully backed by income that's already arrived this month."
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
        if let value = Double(amountText.replacingOccurrences(of: ",", with: "")) {
            store.setBudget(categoryId, amount: value)
        }
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
                let label = category?.name ?? (transaction.category == "INCOME" ? "Income"
                    : transaction.detailedCategory == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" ? "Card payment" : "Transfer")
                Text(transaction.pending ? "Pending · \(label)" : label)
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
