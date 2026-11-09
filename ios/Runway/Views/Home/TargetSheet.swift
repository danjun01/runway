import SwiftUI

struct TargetSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var categoryId: String
    var hadTarget: Bool
    @State private var kind: BucketTarget.Kind
    @State private var amountText: String
    @State private var by: Date

    init(categoryId: String, target: BucketTarget?) {
        self.categoryId = categoryId
        hadTarget = target != nil
        _kind = State(initialValue: target?.kind ?? .saveBy)
        _amountText = State(initialValue: target.map { $0.amount.plainAmount } ?? "")
        _by = State(initialValue: target?.by.map(Day.month) ?? Day.addMonths(6, to: .now))
    }

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(BucketTarget.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Section {
                    HStack {
                        Text(kind == .saveBy ? "Amount" : "Each month")
                        Spacer()
                        TextField("$0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    if kind == .saveBy {
                        DatePicker("By", selection: $by, in: Day.startOfMonth(.now)..., displayedComponents: .date)
                    }
                } footer: {
                    Text(kind == .saveBy
                         ? "Runway spreads what's still missing over the months left, so you set aside a little each month."
                         : "Runway tops the bucket up to this each month, counting what's left over from last month.")
                }

                if hadTarget {
                    Section {
                        Button("Remove target", role: .destructive) {
                            store.setTarget(categoryId, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setTarget(categoryId, BucketTarget(kind: kind, amount: amount,
                                                                 by: kind == .saveBy ? Day.monthKey(by) : nil))
                        dismiss()
                    }
                    .disabled(amount <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
