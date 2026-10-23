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
