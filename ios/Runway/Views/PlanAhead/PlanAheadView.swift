import SwiftUI

/// The Budget tab's entry point: the next big expense and the next tax payment.
struct PlanAheadCard: View {
    var planned: [BudgetEngine.PlannedStatus]
    var tax: BudgetEngine.TaxStatus?

    var body: some View {
        Card {
            HStack {
                Text("Plan ahead").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            let upcoming = planned.filter(\.isActive)
            if upcoming.isEmpty && tax == nil {
                Text("Set money aside for insurance, property tax, and other bills that don't come every month, and see the months ahead.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let next = upcoming.first {
                Label {
                    Text("**\(next.expense.name)** \(next.expense.amount.currency()) due \(next.nextDue.shortDay)")
                } icon: {
                    Image(systemName: "calendar").foregroundStyle(Theme.accent)
                }
                .font(.subheadline)
                let monthly = upcoming.reduce(0) { $0 + ($1.paidThisMonth ? 0 : $1.thisMonth) }
                Text("\(monthly.currency()) set aside this month across \(upcoming.count == 1 ? "1 planned expense" : "\(upcoming.count) planned expenses").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tax {
                Label {
                    Text("Estimated taxes about **\(tax.nextEstimate.currency())** due \(tax.nextDue.shortDay)")
                } icon: {
                    Image(systemName: "building.columns").foregroundStyle(Theme.accent)
                }
                .font(.subheadline)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Planned expenses, self-employment taxes, and a month-by-month forecast.
struct PlanAheadView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: PlannedExpense?
    @State private var adding: PlannedExpense?

    var body: some View {
        let engine = store.engine
        let planned = engine.plannedStatuses
        List {
            Section {
                ForEach(planned) { item in
                    PlannedRow(item: item) { editing = item.expense }
                }
                ForEach(engine.plannedExpenseSuggestions) { stream in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stream.displayName).font(.subheadline.weight(.medium))
                            Text("About \(max(stream.averageAmount, stream.lastAmount).currency()) a year, last on \(Day.parse(stream.lastDate).shortDay)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Plan for it") { adding = suggestion(from: stream) }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                }
                Button("Add planned expense", systemImage: "plus") {
                    adding = PlannedExpense.new(name: "", amount: 0,
                                                dueDate: Calendar.current.date(byAdding: .month, value: 6, to: .now)!,
                                                everyMonths: 6, saved: 0)
                }
            } header: {
                Text("Planned expenses")
            } footer: {
                Text("Each month sets aside an equal share of what's left before the due date, so the bill is covered when it comes. What's set aside stays in checking and is held back from Safe to spend.")
            }

            TaxSection()

            Section {
                if engine.countedIncome.isEmpty {
                    Label(engine.unreviewedIncome.isEmpty
                          ? "No income is counted yet. Add your pay on the Income screen to see what each month leaves."
                          : "Your paychecks aren't confirmed yet, so no income is counted below. Confirm them on the Income screen.",
                          systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(engine.forecast()) { ForecastRow(month: $0) }
            } header: {
                Text("Next 12 months")
            } footer: {
                Text("Income on your confirmed pay schedule, minus bills, your budget, and set-asides. Big expenses are paid from what was set aside, so they don't drain the month they land in.")
            }
        }
        .navigationTitle("Plan ahead")
        .sheet(item: $editing) { PlannedEditor(expense: $0, isNew: false) }
        .sheet(item: $adding) { PlannedEditor(expense: $0, isNew: true) }
    }

    private func suggestion(from stream: RecurringStream) -> PlannedExpense {
        var next = stream.predictedNextDate.map(Day.parse)
            ?? Calendar.current.date(byAdding: .year, value: 1, to: Day.parse(stream.lastDate))!
        while next < Calendar.current.startOfDay(for: .now) {
            next = Calendar.current.date(byAdding: .year, value: 1, to: next)!
        }
        return PlannedExpense.new(name: stream.displayName, amount: max(stream.averageAmount, stream.lastAmount).rounded(),
                                  dueDate: next, everyMonths: 12, saved: 0, streamId: stream.id)
    }
}

private struct PlannedRow: View {
    var item: BudgetEngine.PlannedStatus
    var edit: () -> Void

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.expense.name).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(item.expense.amount.currency()).font(.subheadline.weight(.medium)).monospacedDigit()
                }
                if item.isActive {
                    BudgetBar(spent: item.saved + item.thisMonth, budget: item.expense.amount)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Paid. Nothing more to set aside.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        if item.paidThisMonth {
            return "Paid this month. Next due \(item.nextDue.shortDay); setting aside starts next month."
        }
        return "Due \(item.nextDue.formatted(.dateTime.month(.abbreviated).day().year())) · \(item.thisMonth.currency()) this month · \(item.saved.currency()) set aside so far · \(item.expense.repeatText.lowercased())"
    }
}

private struct TaxSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let engine = store.engine
        let settings = store.taxSettings
        Section {
            Toggle("I pay my own taxes", isOn: Binding(
                get: { settings.enabled },
                set: { var s = settings; s.enabled = $0; store.setTaxSettings(s) }
            ))
            if settings.enabled {
                Stepper(value: Binding(
                    get: { settings.rate },
                    set: { var s = settings; s.rate = $0; store.setTaxSettings(s) }
                ), in: 0.05...0.5, step: 0.01) {
                    HStack {
                        Text("Set aside")
                        Spacer()
                        Text(settings.rate.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    }
                }
                let sources = engine.countedIncome
                if sources.isEmpty {
                    Text("Confirm your income on the Income screen first, then mark which has no taxes withheld.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(sources) { source in
                    Toggle(isOn: Binding(
                        get: { source.untaxed == true },
                        set: { var s = source; s.untaxed = $0; store.saveIncome(s) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text("No taxes withheld").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let tax = engine.taxStatus {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next estimated payment: about **\(tax.nextEstimate.currency())** due \(tax.nextDue.formatted(.dateTime.month(.wide).day().year()))")
                        Text("\(tax.reserved.currency()) is held back from Safe to spend for taxes you haven't paid yet. This year: \(tax.untaxedIncomeThisYear.currency()) untaxed income, \(tax.paidThisYear.currency()) in tax payments seen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text("Self-employment taxes")
        } footer: {
            Text("For freelance or 1099 income with no withholding. Runway holds back this share of each deposit and estimates the quarterly payments due Apr 15, Jun 15, Sep 15, and Jan 15. About 25–30% covers federal income and self-employment tax for many people; a tax professional can give you your number. Payments to the IRS or your state are subtracted once they show up.")
        }
    }
}

private struct ForecastRow: View {
    var month: BudgetEngine.ForecastMonth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                Spacer()
                Text(month.left >= 0 ? "\(month.left.currency()) left" : "\((-month.left).currency()) short")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(month.left >= 0 ? Theme.positive : Theme.negative)
            }
            Text(breakdown).font(.caption).foregroundStyle(.secondary)
            ForEach(month.due, id: \.self) { item in
                Label("\(item.name) \(item.amount.currency()) due \(item.date.shortDay), from set-asides",
                      systemImage: "calendar")
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var breakdown: String {
        var parts = ["\(month.income.currency()) in", "\(month.bills.currency()) bills", "\(month.spending.currency()) budget"]
        let setAside = month.savingsGoal + month.plannedSetAside + month.taxSetAside
        if setAside > 0.5 { parts.append("\(setAside.currency()) set aside") }
        return parts.joined(separator: " · ")
    }
}

/// Add or edit a planned expense.
private struct PlannedEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var expense: PlannedExpense
    var isNew: Bool

    @State private var name = ""
    @State private var amountText = ""
    @State private var due = Date.now
    @State private var every: Int = 6
    @State private var savedText = ""

    private static let repeats: [(label: String, months: Int)] = [
        ("One time", 0), ("Every 3 months", 3), ("Every 6 months", 6), ("Every year", 12),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Car insurance", text: $name)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("$0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    DatePicker("Next due", selection: $due, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                    Picker("Repeats", selection: $every) {
                        ForEach(Self.repeats, id: \.months) { Text($0.label).tag($0.months) }
                    }
                    HStack {
                        Text("Already set aside")
                        Spacer()
                        TextField("$0", text: $savedText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                } footer: {
                    if amount > 0 {
                        Text("About \(monthlyShare.currency()) a month until it's due.")
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.deletePlanned(expense.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Planned expense" : expense.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amount <= 0)
                }
            }
            .onAppear {
                name = expense.name
                amountText = expense.amount > 0 ? String(format: "%.0f", expense.amount) : ""
                due = Day.parse(expense.dueDate)
                every = expense.everyMonths ?? 0
                if isNew {
                    savedText = expense.savedAtStart > 0 ? String(format: "%.0f", expense.savedAtStart) : ""
                } else {
                    // Editing keeps what's been set aside so far.
                    let status = store.engine.status(of: expense)
                    due = status.nextDue
                    savedText = status.saved > 0 ? String(format: "%.0f", status.saved) : ""
                }
            }
        }
    }

    private func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var amount: Double { number(amountText) }

    private var monthlyShare: Double {
        let start = Day.startOfMonth(.now)
        let months = max(1, (Calendar.current.dateComponents([.month], from: start, to: Day.startOfMonth(due)).month ?? 0) + 1)
        return max(0, amount - number(savedText)) / Double(months)
    }

    private func save() {
        var updated = expense
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.amount = amount
        updated.dueDate = Day.string(due)
        updated.everyMonths = every == 0 ? nil : every
        updated.savedAtStart = max(0, number(savedText))
        updated.startMonth = Day.string(Day.startOfMonth(.now))
        store.savePlanned(updated)
        dismiss()
    }
}
