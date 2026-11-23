import SwiftUI

/// Controls, numbers, and the honest explanation of what an iOS app is
/// allowed to delete.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PremiumView()
                    } label: {
                        LabeledContent("AppCatcher Pro", value: model.pro.isPro ? "Active" : "")
                    }
                }

                Section {
                    LockedToggle(title: "Automatic cleaning", isOn: $settings.autoCleanEnabled, isLocked: !model.pro.isPro) {
                        model.showingPaywall = true
                    }
                    if settings.autoCleanEnabled {
                        Picker("Frequency", selection: $settings.autoCleanInterval) {
                            ForEach(AppSettings.AutoCleanInterval.allCases) { interval in
                                Text(interval.label).tag(interval)
                            }
                        }
                    }
                    LockedToggle(title: "Include web data", isOn: $settings.autoCleanWebData, isLocked: !model.pro.isPro) {
                        model.showingPaywall = true
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(nextRunText).footnote()
                }

                Section {
                    Toggle("Back up caches too", isOn: $settings.includeCachesInBackups)
                    Toggle("Ask before restoring", isOn: $settings.confirmBeforeRestore)
                    LabeledContent("Archives", value: "\(model.backups.records.count)")
                    LabeledContent("Vault size", value: ByteFormat.string(model.backups.totalBytes))
                    LabeledContent("Guarded copies", value: ByteFormat.string(model.backups.restoreGuardBytes))
                    if model.backups.restoreGuardBytes > 0 {
                        Button("Delete Guarded Copies", role: .destructive) {
                            model.backups.clearRestoreGuards()
                            Haptics.tap()
                            model.toast = "Guarded copies deleted"
                        }
                    }
                } header: {
                    Text("Backups")
                } footer: {
                    Text("A guarded copy is what was in Documents right before a restore. Delete it once you are sure the restore was right.").footnote()
                }

                Section("General") {
                    LabeledContent("Lifetime reclaimed", value: ByteFormat.string(settings.lifetimeReclaimed))
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    Button("Clear Activity Log", role: .destructive) {
                        model.activity.clear()
                        Haptics.tap()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                    LabeledContent("Archive format", value: "ACBA v\(CatcherArchive.version)")
                    NavigationLink("Why Only This App's Files") { SandboxExplainer() }
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .onChange(of: settings.hapticsEnabled) { _, enabled in Haptics.isEnabled = enabled }
            .navigationTitle("Settings")
        }
    }

    private var nextRunText: String {
        guard model.settings.autoCleanEnabled else {
            return "iOS only wakes apps that hold a background entitlement. AppCatcher does not, so a scheduled clean runs the next time you open the app."
        }
        guard let next = model.settings.nextAutoCleanDate else { return "" }
        return "Next clean is due \(TimeFormat.ago(next)) and runs when you open the app."
    }
}

/// A switch that opens the paywall instead of flipping while Pro is locked.
private struct LockedToggle: View {
    let title: String
    @Binding var isOn: Bool
    let isLocked: Bool
    let onLockedTap: () -> Void

    var body: some View {
        if isLocked {
            Button {
                Haptics.warning()
                onLockedTap()
            } label: {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "lock.fill").imageScale(.small)
                    Text("Pro")
                }
                .foregroundStyle(.secondary)
            }
        } else {
            Toggle(title, isOn: $isOn)
        }
    }
}

private struct SandboxExplainer: View {
    var body: some View {
        List {
            Section("What iOS Allows") {
                Text("Every app lives in its own container. AppCatcher can measure and delete anything inside its own: caches, temporary files, URLSession storage, web data, logs, Documents and Application Support.")
                Text("It cannot see inside another app's container. That is the iOS sandbox, and no App Store app can get around it.")
            }
            Section("Where the Space Really Is") {
                tip("iPhone Storage", "Settings › General › iPhone Storage shows each app's size and offers Offload or Delete.")
                tip("Offload an app", "Removes the app but keeps its documents. Its caches go with it.")
                tip("Safari", "Settings › Apps › Safari › Clear History and Website Data.")
                tip("Restart", "iOS clears some system caches on its own when it boots.")
            }
        }
        .listStyle(.plain)
        .navigationTitle("The Sandbox")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
