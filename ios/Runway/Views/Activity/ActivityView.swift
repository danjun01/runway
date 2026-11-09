import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""

    var body: some View {
        let transactions = (store.snapshot?.transactions ?? []).filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
        }
        let days = Dictionary(grouping: transactions.prefix(400), by: \.date).sorted { $0.key > $1.key }

        let toReview = store.engine.toReview

        NavigationStack {
            List {
                if search.isEmpty && !toReview.isEmpty {
                    Section {
                        ForEach(toReview.prefix(40)) { ReviewRow(transaction: $0) }
                    } header: {
                        HStack {
                            Text("To review · \(toReview.count)")
                            Spacer()
                            Button("Approve all") { withAnimation { store.approveAll() } }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    } footer: {
                        Text("Runway already sorted these. Tap the check if the bucket is right, or tap the transaction to change or split it.")
                    }
                }
                ForEach(days, id: \.key) { entry in
                    Section(Day.parse(entry.key).relativeDay) {
                        ForEach(entry.value) { TransactionRow(transaction: $0) }
                    }
                }
            }
            .overlay {
                if transactions.isEmpty {
                    ContentUnavailableView("No transactions", systemImage: "list.bullet.rectangle",
                                           description: Text(search.isEmpty ? "Pull to refresh once your bank finishes syncing." : "Nothing matches \u{201C}\(search)\u{201D}."))
                }
            }
            .searchable(text: $search, prompt: "Search merchants")
            .refreshable { await store.refresh() }
            .navigationTitle("Activity")
        }
    }
}

/// A transaction waiting for a quick yes, with its suggested bucket.
private struct ReviewRow: View {
    @Environment(AppStore.self) private var store
    var transaction: Transaction

    var body: some View {
        HStack(spacing: 10) {
            TransactionRow(transaction: transaction)
            Button {
                withAnimation { store.approve(transaction) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.positive)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Approve")
        }
    }
}
