import SwiftUI

struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @State private var serverURL = UserDefaults.standard.string(forKey: APIClient.serverURLDefaultsKey) ?? ""
    @State private var savingsText = ""
    @State private var confirmReset = false

    var body: some View {
        let accounts = store.snapshot?.accounts ?? []
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await store.linkAccount() }
                    } label: {
                        Label(store.isDemo ? "Connect your real bank" : "Add an account", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(store.isLinking)
                }

                group("Cash", accounts.filter(\.isSpendableCash))
                group("Savings", accounts.filter(\.isSavings))
                group("Credit cards", accounts.filter(\.isCredit))
                group("Other", accounts.filter { !$0.isSpendableCash && !$0.isSavings && !$0.isCredit })

                if !store.isDemo && !store.institutions.isEmpty {
                    Section("Connections") {
                        ForEach(store.institutions) { institution in
                            Text(institution.name)
                                .swipeActions {
                                    Button("Unlink", role: .destructive) { Task { await store.unlink(institution) } }
                                }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Save each month")
                        Spacer()
                        TextField("$0", text: $savingsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .onSubmit(saveGoal)
                    }
                } header: {
                    Text("Savings goal")
                } footer: {
                    Text("Set aside before anything counts as safe to spend.")
                }

                Section {
                    TextField("http://localhost:8787", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit {
                            UserDefaults.standard.set(serverURL.trimmingCharacters(in: .whitespaces), forKey: APIClient.serverURLDefaultsKey)
                        }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Leave blank to use the URL from the build. On a physical iPhone, use your Mac's address (for example http://your-mac.local:8787).")
                }

                Section {
                    Button("Start over", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Accounts")
            .refreshable { await store.refresh() }
            .onAppear { savingsText = store.monthlySavingsGoal > 0 ? String(Int(store.monthlySavingsGoal)) : "" }
            .onDisappear(perform: saveGoal)
            .confirmationDialog("Start over?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Erase local data and restart", role: .destructive) { store.resetEverything() }
            } message: {
                Text("Your linked banks stay on the server; you can unlink them first under Connections.")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section(title) {
                ForEach(accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName).font(.body.weight(.medium))
                            Text(account.institution).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(account.balance.currency(cents: true)).monospacedDigit()
                            if account.isCredit, let limit = account.limit {
                                Text("of \(limit.currency()) limit").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveGoal() {
        store.monthlySavingsGoal = Double(savingsText) ?? 0
        store.save()
    }
}
