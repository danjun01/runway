import SwiftUI

struct CategoryDetailView: View {
    @Environment(AppStore.self) private var store
    var categoryId: String
    @State private var amountText = ""
    @FocusState private var editing: Bool

    var body: some View {
        let engine = store.engine
        let category = store.budgets.first { $0.id == categoryId } ?? BudgetCategory.defaults[0]
        let spent = engine.spent(in: categoryId)
        let transactions = engine.transactions(in: categoryId)

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

            Section("Monthly budget") {
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
            }

            Section(transactions.isEmpty ? "No transactions this month" : "This month") {
                ForEach(transactions) { TransactionRow(transaction: $0) }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { amountText = String(Int(category.monthlyAmount)) }
        .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
    }

    private func commit() {
        editing = false
        if let value = Double(amountText.replacingOccurrences(of: ",", with: "")) {
            store.setBudget(categoryId, amount: value)
        }
    }
}

struct TransactionRow: View {
    var transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            let category = BudgetCategory.categoryId(for: transaction)
                .flatMap { id in BudgetCategory.defaults.first { $0.id == id } }
            CategoryIcon(symbol: category?.symbol ?? (transaction.amount < 0 ? "arrow.down.left" : "arrow.left.arrow.right"),
                         color: transaction.amount < 0 ? Theme.positive : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(transaction.pending ? "Pending" : (category?.name ?? "Transfer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(transaction.amount < 0 ? "+" + (-transaction.amount).currency(cents: true) : transaction.amount.currency(cents: true))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(transaction.amount < 0 ? Theme.positive : .primary)
        }
    }
}
