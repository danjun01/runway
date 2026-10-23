import Foundation

/// A realistic few months of finances, generated relative to today, so the app
/// can be explored without a backend or a Plaid account.
enum DemoData {
    static func snapshot(today: Date = .now) -> Snapshot {
        var rng = SeededGenerator(seed: 42)
        let cal = Day.calendar
        let start = cal.date(byAdding: .day, value: -150, to: cal.startOfDay(for: today))!
        let item = "demo-item"

        let accounts: [Account] = [
            .init(id: "chk", itemId: item, institution: "Chase", name: "Total Checking", mask: "4821",
                  type: "depository", subtype: "checking", currentBalance: 3412.18, availableBalance: 3236.40,
                  limit: nil, currency: "USD"),
            .init(id: "sav", itemId: item, institution: "Chase", name: "Savings", mask: "1150",
                  type: "depository", subtype: "savings", currentBalance: 8540.00, availableBalance: 8540.00,
                  limit: nil, currency: "USD"),
            .init(id: "sapphire", itemId: item, institution: "Chase", name: "Sapphire Preferred", mask: "9934",
                  type: "credit", subtype: "credit card", currentBalance: 1642.57, availableBalance: 8357.43,
                  limit: 10000, currency: "USD"),
            .init(id: "discover", itemId: item, institution: "Discover", name: "Discover it", mask: "0071",
                  type: "credit", subtype: "credit card", currentBalance: 486.12, availableBalance: 4513.88,
                  limit: 5000, currency: "USD"),
        ]

        var txns: [Transaction] = []
        func add(_ day: Date, _ name: String, _ amount: Double, _ primary: String, _ detailed: String,
                 account: String = "sapphire") {
            guard day <= today else { return }
            txns.append(.init(id: "t\(txns.count)", accountId: account, date: Day.string(day), name: name,
                              merchant: name, amount: (amount * 100).rounded() / 100, category: primary,
                              detailedCategory: detailed, pending: cal.isDate(day, inSameDayAs: today), logoUrl: nil))
        }

        // Biweekly paycheck on Fridays, anchored so one lands later this month.
        var payday = cal.date(byAdding: .day, value: 6, to: cal.startOfDay(for: today))!
        while payday > start { payday = cal.date(byAdding: .day, value: -14, to: payday)! }
        var lastPayday = payday
        while payday <= today {
            add(payday, "Acme Corp Payroll", -2150, "INCOME", "INCOME_WAGES", account: "chk")
            lastPayday = payday
            payday = cal.date(byAdding: .day, value: 14, to: payday)!
        }

        var day = start
        while day <= today {
            let dom = cal.component(.day, from: day)
            let weekday = cal.component(.weekday, from: day)
            if dom == 1 { add(day, "Parkview Apartments", 1650, "RENT_AND_UTILITIES", "RENT_AND_UTILITIES_RENT", account: "chk") }
            if dom == 5 { add(day, "Austin Energy", Double.random(in: 85...140, using: &rng), "RENT_AND_UTILITIES", "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY") }
            if dom == 8 { add(day, "Spectrum", 70, "RENT_AND_UTILITIES", "RENT_AND_UTILITIES_INTERNET_AND_CABLE") }
            if dom == 12 { add(day, "Netflix", 15.49, "ENTERTAINMENT", "ENTERTAINMENT_TV_AND_MOVIES") }
            if dom == 14 { add(day, "Spotify", 11.99, "ENTERTAINMENT", "ENTERTAINMENT_MUSIC_AND_AUDIO") }
            if dom == 15 { add(day, "Geico", 128, "GENERAL_SERVICES", "GENERAL_SERVICES_INSURANCE", account: "discover") }
            if dom == 20 { add(day, "T-Mobile", 65, "RENT_AND_UTILITIES", "RENT_AND_UTILITIES_TELEPHONE", account: "discover") }
            if dom == 3 { add(day, "Equinox", 45, "PERSONAL_CARE", "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", account: "discover") }
            if weekday == 1 || weekday == 4 {
                add(day, ["H-E-B", "Trader Joe's", "Whole Foods"].randomElement(using: &rng)!,
                    Double.random(in: 45...135, using: &rng), "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES")
            }
            if Double.random(in: 0...1, using: &rng) < 0.45 {
                add(day, ["Chipotle", "Sweetgreen", "Starbucks", "Torchy's Tacos", "Uchi", "Pinthouse"].randomElement(using: &rng)!,
                    Double.random(in: 6...68, using: &rng), "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT")
            }
            if weekday == 7 { add(day, "Shell", Double.random(in: 38...55, using: &rng), "TRANSPORTATION", "TRANSPORTATION_GAS", account: "discover") }
            if Double.random(in: 0...1, using: &rng) < 0.12 {
                add(day, "Uber", Double.random(in: 12...34, using: &rng), "TRANSPORTATION", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES")
            }
            if Double.random(in: 0...1, using: &rng) < 0.14 {
                add(day, ["Amazon", "Target", "Uniqlo", "Apple"].randomElement(using: &rng)!,
                    Double.random(in: 14...160, using: &rng), "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES")
            }
            if Double.random(in: 0...1, using: &rng) < 0.06 {
                add(day, ["AMC Theatres", "Alamo Drafthouse", "Ticketmaster", "Topgolf"].randomElement(using: &rng)!,
                    Double.random(in: 18...120, using: &rng), "ENTERTAINMENT", "ENTERTAINMENT_SPORTING_EVENTS_AMUSEMENT_PARKS_AND_CONCERTS")
            }
            if dom == 22 { add(day, "Chase Card Payment", 1380, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT", account: "chk") }
            if dom == 24 { add(day, "Transfer to Savings", 300, "TRANSFER_OUT", "TRANSFER_OUT_SAVINGS", account: "chk") }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        let statementDate = cal.date(byAdding: .day, value: -12, to: today)!
        let creditCards: [CreditCard] = [
            .init(accountId: "sapphire", lastStatementBalance: 1184.22, lastStatementDate: Day.string(statementDate),
                  nextPaymentDueDate: Day.string(cal.date(byAdding: .day, value: 9, to: today)!),
                  minimumPayment: 35, lastPaymentAmount: 1380,
                  lastPaymentDate: Day.string(cal.date(byAdding: .day, value: -20, to: today)!),
                  isOverdue: false, purchaseApr: 24.99),
            .init(accountId: "discover", lastStatementBalance: 412.80,
                  lastStatementDate: Day.string(cal.date(byAdding: .day, value: -6, to: today)!),
                  nextPaymentDueDate: Day.string(cal.date(byAdding: .day, value: 19, to: today)!),
                  minimumPayment: 35, lastPaymentAmount: 390,
                  lastPaymentDate: Day.string(cal.date(byAdding: .day, value: -26, to: today)!),
                  isOverdue: false, purchaseApr: 27.24),
        ]

        let recurring: [RecurringStream] = [
            .init(id: "pay", accountId: "chk", direction: "inflow", description: "ACME CORP PAYROLL", merchant: "Acme Corp",
                  averageAmount: 2150, lastAmount: 2150, frequency: "BIWEEKLY", lastDate: Day.string(lastPayday),
                  predictedNextDate: Day.string(cal.date(byAdding: .day, value: 14, to: lastPayday)!),
                  category: "INCOME", isActive: true),
            .init(id: "rent", accountId: "chk", direction: "outflow", description: "PARKVIEW APTS", merchant: "Parkview Apartments",
                  averageAmount: 1650, lastAmount: 1650, frequency: "MONTHLY", lastDate: Day.string(Day.startOfMonth(today)),
                  predictedNextDate: Day.string(cal.date(byAdding: .month, value: 1, to: Day.startOfMonth(today))!),
                  category: "RENT_AND_UTILITIES", isActive: true),
        ]

        return Snapshot(
            syncedAt: ISO8601DateFormatter().string(from: today),
            institutions: [.init(itemId: item, name: "Chase"), .init(itemId: "demo-discover", name: "Discover")],
            accounts: accounts,
            transactions: txns.sorted { $0.date > $1.date },
            creditCards: creditCards,
            recurring: recurring
        )
    }
}

/// SplitMix64, so demo data is the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension DemoData {
    /// A canned conversation for screenshots of the Ask tab. Real answers come
    /// from Claude through the backend.
    static let sampleChat: [ChatMessage] = [
        ChatMessage(role: .user, content: "How much do I have to play with for the rest of the month?"),
        ChatMessage(role: .assistant, content: """
        You can spend about **$3,235** through the end of the month, roughly $359 a day.

        - $3,236 in checking + $2,150 paycheck on the 29th
        - minus $2,129 owed across your Sapphire and Discover cards
        - minus $22 in bills you haven't paid yet

        That already sets aside every dollar on your cards, so spending within it won't leave a balance behind. Dining is the category running hottest this month.
        """),
        ChatMessage(role: .user, content: "How should I pay my cards so I don't carry a balance?"),
        ChatMessage(role: .assistant, content: """
        Pay these two and you're interest-free:

        - **Sapphire: $1,184.22 by Nov 1** (24.99% APR, due first)
        - **Discover: $412.80 by Nov 11**

        Your checking covers both today. The $458 of new Sapphire charges goes on next month's statement, and it's already set aside in your safe-to-spend number.
        """),
    ]
}
