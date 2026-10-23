import SwiftUI

struct AskView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let suggestions = [
        "How much do I have to play with for the rest of the month?",
        "How should I pay my credit cards so I don't carry a balance?",
        "Can I afford a $300 weekend trip and still pay everything off?",
        "Where am I overspending compared to last month?",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.chat.isEmpty {
                            EmptyChat(suggestions: suggestions) { send($0) }
                        }
                        ForEach(store.chat) { message in
                            MessageBubble(message: message, isStreaming: store.isAnswering && message.id == store.chat.last?.id)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.chat.last?.content) {
                    if let id = store.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Ask Runway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.chat.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil") { store.clearChat() }
                            .disabled(store.isAnswering)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your money\u{2026}", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.isAnswering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        draft = ""
        Task { await store.ask(text) }
    }
}

private struct EmptyChat: View {
    var suggestions: [String]
    var pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("Ask anything about your money")
                .font(.title2.weight(.bold))
            Text("Runway sees your balances, cards, bills, and spending, and does the math for you.")
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    Text(suggestion)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 24)
    }
}

private struct MessageBubble: View {
    var message: ChatMessage
    var isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Group {
                if message.content.isEmpty && isStreaming {
                    TypingIndicator()
                } else {
                    Text(rendered)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(message.role == .user ? Color.white : (message.isError ? Theme.negative : Color.primary))
            .background(
                message.role == .user ? Theme.accent : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    /// Claude's replies use light markdown: bold, italics, and "- " lists.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.content, options: options)) ?? AttributedString(message.content)
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}
