import SwiftUI

/// Change one transaction's bucket, optionally for the whole merchant, or
/// split it across buckets.
struct TransactionEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var transaction: Transaction
    @State private var bucketId: String
    @State private var forMerchant = false
    @State private var splitting: Bool
    @State private var parts: [Part]

    struct Part: Identifiable {
        var id = UUID()
        var bucketId: String
        var amountText: String
        var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0 }
    }

    init(transaction: Transaction, bucketId: String, allocations: [(bucketId: String, amount: Double)]) {
        self.transaction = transaction
        _bucketId = State(initialValue: bucketId)
        _splitting = State(initialValue: allocations.count > 1)
        let start = allocations.isEmpty ? [(bucketId: bucketId, amount: transaction.amount)] : allocations
        _parts = State(initialValue: start.map { Part(bucketId: $0.bucketId, amountText: $0.amount.plainAmount) })
    }

    private var remaining: Double { transaction.amount - parts.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.displayName).font(.headline)
                            Text(transaction.day.formatted(.dateTime.weekday(.wide).month().day()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(transaction.amount.currency(cents: true)).font(.headline).monospacedDigit()
                    }
                }

                if !splitting {
                    Section {
                        Picker("Bucket", selection: $bucketId) { bucketOptions }
                            .pickerStyle(.navigationLink)
                        Toggle("Everything from \(transaction.displayName)", isOn: $forMerchant)
                    } footer: {
                        Text(forMerchant
                             ? "Past and future transactions from \(transaction.displayName) go here too."
                             : "Only this transaction changes.")
                    }
                }

                Section {
                    Toggle("Split across buckets", isOn: $splitting.animation())
                }

                if splitting {
                    Section {
                        ForEach($parts) { $part in
                            HStack {
                                Picker("Bucket", selection: $part.bucketId) { bucketOptions }
                                    .labelsHidden()
                                Spacer()
                                TextField("$0", text: $part.amountText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 100)
                            }
                        }
                        .onDelete { parts.remove(atOffsets: $0) }
                        Button("Add a bucket", systemImage: "plus") {
                            let unused = store.budgets.first { b in !parts.contains { $0.bucketId == b.id } }?.id ?? bucketId
                            parts.append(Part(bucketId: unused, amountText: remaining > 0.005 ? remaining.plainAmount : ""))
                        }
                    } footer: {
                        if abs(remaining) > 0.005 {
                            Text(remaining > 0
                                 ? "\(remaining.currency(cents: true)) still to place."
                                 : "That's \((-remaining).currency(cents: true)) more than the transaction.")
                                .foregroundStyle(Theme.negative)
                        } else {
                            Text("All of it is placed.")
                        }
                    }
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if splitting {
                            var byBucket: [String: Double] = [:]
                            for part in parts { byBucket[part.bucketId, default: 0] += part.amount }
                            store.split(transaction, into: byBucket)
                        } else {
                            store.categorize(transaction, as: bucketId, forMerchant: forMerchant)
                        }
                        dismiss()
                    }
                    .disabled(splitting && abs(remaining) > 0.005)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var bucketOptions: some View {
        ForEach(store.budgets) { bucket in
            Label(bucket.name, systemImage: bucket.symbol).tag(bucket.id)
        }
    }
}
