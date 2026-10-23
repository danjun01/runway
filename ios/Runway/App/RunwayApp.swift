import SwiftUI

@main
struct RunwayApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
        }
        .backgroundTask(.appRefresh(DailySummary.refreshTaskId)) {
            await store.refreshInBackground()
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var store = store
        Group {
            if store.hasOnboarded {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut, value: store.hasOnboarded)
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && store.hasOnboarded {
                Task { await store.refresh() }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            HomeView()
                .tabItem { Label("Budget", systemImage: "chart.pie.fill") }
                .tag(AppStore.Tab.home)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(AppStore.Tab.activity)
            AskView()
                .tabItem { Label("Ask", systemImage: "sparkles") }
                .tag(AppStore.Tab.ask)
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns") }
                .tag(AppStore.Tab.accounts)
        }
    }
}
