import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""

    var body: some View {
        let transactions = (store.snapshot?.transactions ?? []).filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
        }
        let days = Dictionary(grouping: transactions.prefix(400), by: \.date).sorted { $0.key > $1.key }

        NavigationStack {
            List {
                if search.isEmpty && !transactions.isEmpty {
                    Section {
                        SyncStatus()
                    } footer: {
                        Text("Long-press a transaction to move that merchant to a different bucket, now and from then on.")
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

/// When the data was last pulled from the bank and what's still pending, so a
/// number that differs from the bank's app has a visible reason.
struct SyncStatus: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let pending = (store.snapshot?.transactions ?? []).filter { $0.pending && $0.amount > 0 }
        VStack(alignment: .leading, spacing: 4) {
            if let synced = Self.parse(store.snapshot?.syncedAt) {
                Label {
                    Text("Synced \(synced, style: .relative) ago")
                } icon: {
                    Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                }
                .font(.subheadline.weight(.medium))
            }
            if !pending.isEmpty {
                Text("\(pending.count) pending \(pending.count == 1 ? "charge" : "charges") (\(pending.reduce(0) { $0 + $1.amount }.currency(cents: true))) already counted. Pending charges can change or drop off when they post, so your bank's app may show a different balance until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
