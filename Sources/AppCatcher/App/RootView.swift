import SwiftUI

/// Tab shell, global toast, paywall and first-run screen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.route) {
            DashboardView()
                .tabItem { Label("Overview", systemImage: "internaldrive") }
                .tag(AppModel.Tab.dashboard)

            CleanerView()
                .tabItem { Label("Cleaner", systemImage: "trash") }
                .tag(AppModel.Tab.cleaner)

            BackupsView()
                .tabItem { Label("Backups", systemImage: "archivebox") }
                .tag(AppModel.Tab.backups)

            // The installed-app inventory rides on a private framework. This is
            // a personal, sideload-only build, so the tab is unconditional;
            // a store submission must delete AppsView and the service instead.
            AppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(AppModel.Tab.apps)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.cache.refreshVolume()
            Task { await model.autoCleanIfNeeded() }
        }
        .overlay(alignment: .top) { toast }
        .sheet(isPresented: $model.showingPaywall) {
            NavigationStack {
                PremiumView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { model.showingPaywall = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: firstRunBinding) { OnboardingView() }
    }

    private var firstRunBinding: Binding<Bool> {
        Binding(
            get: { !model.settings.hasCompletedOnboarding },
            set: { model.settings.hasCompletedOnboarding = !$0 }
        )
    }

    @ViewBuilder
    private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { model.toast = nil }
                }
                .allowsHitTesting(false)
        }
    }
}

/// One screen that sets expectations instead of selling a fantasy.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text("Welcome to AppCatcher")
                .font(.largeTitle.bold())
            feature("internaldrive", "See where it went",
                    "Caches, temporary files, web storage and logs, measured file by file before anything is deleted.")
            feature("archivebox", "Back up, then clean",
                    "Seal Documents and app data into one archive, optionally encrypted. Verify or restore it any time.")
            feature("lock.shield", "Honest about iOS",
                    "No app can delete another app's caches. AppCatcher cleans what it owns and points you to iPhone Storage for the rest.")
            Spacer()
            Button("Continue", action: finish)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        Haptics.tap()
        model.settings.hasCompletedOnboarding = true
        Task { await model.rescan() }
    }
}
