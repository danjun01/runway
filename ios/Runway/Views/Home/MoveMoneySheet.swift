import SwiftUI

/// Moves money between buckets (or to and from "left to assign") within a
/// month. Covering an overspent bucket is a move into it.
struct MoveMoneySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var month: Date
    var title: String
    @State private var from: String?
    @State private var to: String?
    @State private var amountText: String

    init(month: Date, from: String? = nil, to: String? = nil, amount: Double = 0, title: String = "Move money") {
        self.month = month
        self.title = title
        _from = State(initialValue: from)
        _to = State(initialValue: to)
        _amountText = State(initialValue: amount > 0 ? amount.plainAmount : "")
    }

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0 }

    var body: some View {
        let plan = store.engine.plan(for: month)
        let available = Dictionary(uniqueKeysWithValues: plan.buckets.map { ($0.id, $0.available) })
        let sourceLeft = from.map { available[$0] ?? 0 } ?? plan.leftToAssign

        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("$0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 140)
                    }
                }
                Section {
                    picker("From", selection: $from, plan: plan)
                    picker("To", selection: $to, plan: plan)
                } footer: {
                    if amount > 0 {
                        let after = sourceLeft - amount
                        Text(after >= 0
                             ? "\(name(from, plan)) keeps \(after.currency(cents: true))."
                             : "\(name(from, plan)) only has \(max(0, sourceLeft).currency(cents: true)), so it will be \((-after).currency(cents: true)) short.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        store.moveMoney(amount, from: from, to: to, in: month)
                        dismiss()
                    }
                    .disabled(amount <= 0 || from == to)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func picker(_ label: String, selection: Binding<String?>, plan: BudgetEngine.Plan) -> some View {
        Picker(label, selection: selection) {
            Text("Left to assign · \(plan.leftToAssign.currency())").tag(String?.none)
            ForEach(plan.buckets) { bucket in
                Text("\(bucket.category.name) · \(bucket.available.currency())").tag(Optional(bucket.id))
            }
        }
    }

    private func name(_ id: String?, _ plan: BudgetEngine.Plan) -> String {
        guard let id else { return "Left to assign" }
        return plan.buckets.first { $0.id == id }?.category.name ?? "That bucket"
    }
}

extension BudgetEngine.Plan {
    /// Where to take money from to cover `need`: left to assign if it has
    /// enough, otherwise the flexible bucket with the most available.
    func bestSource(toCover need: Double, excluding id: String) -> String? {
        if leftToAssign >= need { return nil }
        return buckets
            .filter { $0.id != id && !$0.category.isFixed && $0.available > 0.005 }
            .max { $0.available < $1.available }?
            .id
    }
}

extension Double {
    /// "120" or "42.50", for prefilling amount fields.
    var plainAmount: String {
        let cents = (self * 100).rounded() / 100
        return cents == cents.rounded() ? String(Int(cents)) : String(format: "%.2f", cents)
    }
}
