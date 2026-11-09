import Charts
import SwiftUI

struct TrendsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let engine = store.engine
        let history = engine.spendingHistory(months: 6)
        let trends = engine.bucketTrends()
        let thisMonth = Day.monthKey(.now)

        List {
            Section {
                AgeOfMoneyCard(days: engine.ageOfMoney)
            }

            Section {
                Chart(history) { month in
                    BarMark(x: .value("Month", month.month, unit: .month),
                            y: .value("Spent", month.total))
                        .foregroundStyle(month.id == thisMonth ? Theme.accent : Theme.accent.opacity(0.35))
                        .cornerRadius(6)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(v.currency()) } }
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 8)
            } header: {
                Text("Spending by month")
            } footer: {
                Text("This month so far is the darker bar.")
            }

            if !trends.isEmpty {
                Section {
                    ForEach(trends) { TrendRow(trend: $0) }
                } header: {
                    Text("This month vs. usual")
                } footer: {
                    Text("Usual is the average of the three months before this one.")
                }
            }
        }
        .navigationTitle("Trends")
    }
}

struct AgeOfMoneyCard: View {
    var days: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Age of money").font(.subheadline).foregroundStyle(.secondary)
            if let days {
                Text(days == 1 ? "1 day" : "\(days) days")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(days >= 30
                     ? "You're spending money you earned over a month ago. That's a real cushion."
                     : "You're spending money about \(days) days after it comes in. Getting this past 30 days means you're living on last month's income.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not enough history yet").font(.headline)
                Text("Runway needs a few weeks of income and spending to work this out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct TrendRow: View {
    var trend: BudgetEngine.BucketTrend

    var body: some View {
        let delta = trend.thisMonth - trend.usual
        HStack(spacing: 12) {
            CategoryIcon(symbol: trend.category.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(trend.category.name).font(.subheadline.weight(.medium))
                Text("Usually \(trend.usual.currency())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(trend.thisMonth.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                if trend.usual > 0.5 && abs(delta) >= 1 {
                    Label((delta > 0 ? "" : "\u{2212}") + abs(delta).currency(),
                          systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(delta > 0 ? Theme.negative : Theme.positive)
                }
            }
        }
    }
}
