import SwiftUI

enum Theme {
    static let accent = Color("AccentColor")
    static let positive = Color(red: 0.13, green: 0.63, blue: 0.42)
    static let warning = Color(red: 0.95, green: 0.6, blue: 0.1)
    static let negative = Color(red: 0.9, green: 0.27, blue: 0.27)
    static let corner: CGFloat = 20
}

extension Double {
    /// $1,234 (no cents when whole dollars read better).
    func currency(cents: Bool = false) -> String {
        formatted(.currency(code: "USD").precision(.fractionLength(cents ? 2 : 0)))
    }
}

extension Date {
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day()) }

    var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        return formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// The rounded white panel used throughout the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

struct PrimaryButton: View {
    var title: String
    var isLoading = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(.white) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
        }
        .disabled(isLoading)
    }
}

struct CategoryIcon: View {
    var symbol: String
    var color: Color = Theme.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Thin capsule progress bar that turns amber near the limit and red past it.
struct BudgetBar: View {
    var spent: Double
    var budget: Double

    private var fraction: Double { budget > 0 ? spent / budget : (spent > 0 ? 1 : 0) }
    private var color: Color {
        fraction > 1 ? Theme.negative : fraction > 0.85 ? Theme.warning : Theme.positive
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}
