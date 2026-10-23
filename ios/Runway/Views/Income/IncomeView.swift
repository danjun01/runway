import SwiftUI

/// Recurring income: what's arrived this month, what's still expected, and the
/// sources it's projected from. Detected sources can be confirmed, edited, or
/// dismissed, and the user can add income Runway can't see.
struct IncomeView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: IncomeSource?
    @State private var adding = false

    var body: some View {
        let engine = store.engine
        let plan = engine.plan
        let sources = engine.incomeSources
        let counted = sources.filter(\.counts)
        let suggested = sources.filter { $0.status == .suggested }
        let ignored = sources.filter { $0.status == .ignored }

        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(plan.income.currency())
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    IncomeBar(arrived: plan.arrived, expected: plan.expected)
                    Text("\(plan.arrived.currency()) has arrived. \(plan.expected.currency()) is expected before the month ends.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                ForEach(plan.paychecks) { PaycheckRow(paycheck: $0) }
            } header: {
                Text("\(Date.now.formatted(.dateTime.month(.wide))) income")
            } footer: {
                Text("Expected paychecks are projected from your pay schedule. You can assign them to buckets now; they switch to arrived when the deposit shows up.")
            }

            Section {
                ForEach(counted) { source in
                    SourceRow(source: source, nextPayday: engine.nextPayday(of: source)) { editing = source }
                        .swipeActions {
                            Button("Not income") { store.setIncomeStatus(source, .ignored) }.tint(.gray)
                            if source.status == .detected {
                                Button("Confirm") { store.setIncomeStatus(source, .confirmed) }.tint(Theme.positive)
                            }
                        }
                }
                if counted.isEmpty {
                    Text("No regular income found yet. Plaid needs a couple of paychecks to spot a pattern, or you can add one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Add income", systemImage: "plus") { adding = true }
            } header: {
                Text("Recurring income")
            } footer: {
                Text("Tap a source to fix its amount or schedule. Swipe to confirm it or mark it as not income.")
            }

            if !suggested.isEmpty {
                Section {
                    ForEach(suggested) { source in
                        SourceRow(source: source, nextPayday: engine.nextPayday(of: source)) { editing = source }
                            .swipeActions {
                                Button("Not income") { store.setIncomeStatus(source, .ignored) }.tint(.gray)
                                Button("It's income") { store.setIncomeStatus(source, .confirmed) }.tint(Theme.positive)
                            }
                    }
                } header: {
                    Text("Is this income?")
                } footer: {
                    Text("Regular money coming in that might be a transfer. It isn't counted until you confirm it.")
                }
            }

            if !ignored.isEmpty {
                Section("Not income") {
                    ForEach(ignored) { source in
                        SourceRow(source: source, nextPayday: nil) { editing = source }
                            .swipeActions {
                                Button("Restore") {
                                    if source.isManual { store.setIncomeStatus(source, .confirmed) } else { store.forgetIncome(source) }
                                }
                                .tint(Theme.accent)
                            }
                    }
                }
            }
        }
        .navigationTitle("Income")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { IncomeEditor(source: $0, nextPayday: engine.nextPayday(of: $0)) }
        .sheet(isPresented: $adding) { IncomeEditor(source: nil, nextPayday: nil) }
    }
}

private struct PaycheckRow: View {
    var paycheck: Paycheck

    var body: some View {
        HStack(spacing: 12) {
            switch paycheck.state {
            case .arrived:
                CategoryIcon(symbol: "checkmark", color: Theme.positive)
            case .expected:
                CategoryIcon(symbol: "clock", color: .secondary)
            case .missed:
                CategoryIcon(symbol: "exclamationmark", color: Theme.warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(paycheck.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(paycheck.amount.currency(cents: true))
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(paycheck.state == .arrived ? Theme.positive : .secondary)
                .strikethrough(paycheck.state == .missed)
        }
    }

    private var caption: String {
        switch paycheck.state {
        case .arrived: "Arrived \(paycheck.date.shortDay)"
        case .expected: "Expected \(paycheck.date.shortDay)"
        case .missed: "Was due \(paycheck.date.shortDay), not seen yet"
        }
    }
}

private struct SourceRow: View {
    var source: IncomeSource
    var nextPayday: Date?
    var edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 12) {
                CategoryIcon(symbol: source.isManual ? "pencil" : "arrow.down.left", color: Theme.positive)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        if source.status == .confirmed {
                            Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.positive)
                        } else if source.status == .detected {
                            Text("Detected").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(source.amount.currency()).font(.subheadline.weight(.medium)).monospacedDigit()
                    Text("about \(source.monthlyEstimate.currency())/mo").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        let schedule = source.frequency.label
        guard let nextPayday else { return schedule }
        return "\(schedule) \u{00B7} next \(nextPayday.shortDay)"
    }
}

/// Confirm or correct a detected source, or add one by hand.
private struct IncomeEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var source: IncomeSource?
    var nextPayday: Date?

    @State private var name = ""
    @State private var amountText = ""
    @State private var frequency: PayFrequency = .biweekly
    @State private var next = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Paycheck", text: $name)
                    HStack {
                        Text("Each paycheck")
                        Spacer()
                        TextField("$0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    Picker("How often", selection: $frequency) {
                        ForEach(PayFrequency.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("Next payday", selection: $next, displayedComponents: .date)
                } footer: {
                    Text("Use what lands in your account after taxes. Runway projects future paychecks from this schedule.")
                }

                if let source, !source.isManual, source.status != .confirmed {
                    Section {
                        Button("Not income", role: .destructive) {
                            store.setIncomeStatus(source, .ignored)
                            dismiss()
                        }
                    }
                }
                if let source, source.isManual {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.forgetIncome(source)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(source == nil ? "Add income" : "Income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(source == nil || source?.status == .confirmed ? "Save" : "Confirm", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amount <= 0)
                }
            }
            .onAppear {
                guard let source else { return }
                name = source.name
                amountText = String(format: "%.2f", source.amount)
                frequency = source.frequency
                next = nextPayday ?? Day.parse(source.anchorDate)
            }
        }
    }

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0 }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var source {
            source.name = trimmed
            source.amount = amount
            source.frequency = frequency
            source.anchorDate = Day.string(next)
            source.status = .confirmed
            store.saveIncome(source)
        } else {
            store.saveIncome(.manual(name: trimmed, amount: amount, frequency: frequency, nextDate: next))
        }
        dismiss()
    }
}
