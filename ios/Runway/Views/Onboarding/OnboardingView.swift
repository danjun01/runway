import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @State private var step: Step = .welcome

    enum Step { case welcome, connect, building, review }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            switch step {
            case .welcome: WelcomeStep { step = .connect }
            case .connect: ConnectStep { step = .building }
            case .building: BuildingStep { step = .review }
            case .review: ReviewStep { store.finishOnboarding() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

private struct WelcomeStep: View {
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Image(systemName: "airplane.departure")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 10) {
                Text("Know exactly what\nyou can spend.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Runway connects to your accounts, builds your budget for you, and answers money questions in plain English.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "link", title: "No manual entry", detail: "Transactions sync from your bank automatically.")
                Feature(symbol: "gauge.with.dots.needle.50percent", title: "Safe to spend", detail: "One number for the rest of the month, after bills and cards.")
                Feature(symbol: "creditcard", title: "Never carry a balance", detail: "Know what to pay on each card, and by when.")
                Feature(symbol: "sparkles", title: "Just ask", detail: "\u{201C}Can I afford a $300 weekend trip?\u{201D}")
            }
            Spacer()
            PrimaryButton(title: "Get started", action: next)
        }
        .padding(24)
    }
}

private struct Feature: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CategoryIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectStep: View {
    @Environment(AppStore.self) private var store
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "building.columns.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect your accounts")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Add your checking account and every credit card you use. Runway reads balances and transactions; it can't move money.")
                    .foregroundStyle(.secondary)
            }

            if !store.institutions.isEmpty {
                Card {
                    ForEach(store.institutions) { institution in
                        Label(institution.name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.positive)
                            .font(.body.weight(.medium))
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Secured by Plaid. Your bank login is never shared with Runway.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                if store.institutions.isEmpty {
                    PrimaryButton(title: "Connect a bank", isLoading: store.isLinking) {
                        Task { await store.linkAccount() }
                    }
                } else {
                    PrimaryButton(title: "Continue", action: next)
                    Button("Add another account") { Task { await store.linkAccount() } }
                        .font(.subheadline.weight(.semibold))
                        .disabled(store.isLinking)
                }
                Button("Explore with demo data") {
                    store.startDemo()
                    next()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(24)
    }
}

private struct BuildingStep: View {
    @Environment(AppStore.self) private var store
    var next: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large)
            Text("Reading your last few months\u{2026}")
                .font(.title3.weight(.semibold))
            Text("Sorting transactions and building a budget around how you actually spend.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            if !store.isDemo { await store.waitForTransactions() }
            store.applySuggestedBudget()
            try? await Task.sleep(for: .seconds(1))
            next()
        }
    }
}

private struct ReviewStep: View {
    @Environment(AppStore.self) private var store
    var done: () -> Void

    var body: some View {
        let engine = store.engine
        let safe = engine.safeToSpend
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Here's your plan")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .padding(.top, 24)
                    Text("Based on your recent spending. You can change any amount later.")
                        .foregroundStyle(.secondary)

                    Card {
                        Text("Safe to spend this month").font(.subheadline).foregroundStyle(.secondary)
                        Text(safe.amount.currency())
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(safe.amount >= 0 ? Color.primary : Theme.negative)
                        Text("About \(safe.perDay.currency()) a day for \(safe.daysLeft) days")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    SectionHeader(title: "Monthly budget", trailing: engine.totalBudgeted.currency())
                    Card {
                        ForEach(store.budgets.filter { $0.monthlyAmount > 0 }) { category in
                            HStack {
                                CategoryIcon(symbol: category.symbol)
                                Text(category.name)
                                Spacer()
                                Text(category.monthlyAmount.currency()).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            PrimaryButton(title: "Looks good", action: done)
                .padding(24)
        }
    }
}
