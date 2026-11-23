import SwiftUI
import UIKit

/// Read-only inventory of what is installed on the device.
///
/// The data comes from private APIs (LSApplicationWorkspace, with a
/// MobileInstallation fallback), so this tab is for personally sideloaded
/// builds only and must be removed for any store submission.
struct AppsView: View {
    @Environment(AppModel.self) private var model

    private var service: InstalledAppsService { model.apps }

    var body: some View {
        NavigationStack {
            List {
                if service.unavailable {
                    unavailable
                } else {
                    Section {
                        LabeledContent("User apps", value: "\(service.userCount)")
                        LabeledContent("App data", value: ByteFormat.string(service.userBytes))
                        if !service.syncSource.isEmpty {
                            LabeledContent("Source", value: syncCaption)
                        }
                    }

                    Section {
                        ForEach(service.visible) { AppRow(item: $0) }
                    } header: {
                        Text(service.includeSystem ? "All Apps" : "User Apps")
                    } footer: {
                        Text("Read-only inventory. The context menu offers Clean Caches (iOS 26.0–26.7.2 / 27.2, via the container bug) and a link to iPhone Storage for everything else.\(syncHint)")
                            .footnote()
                    }
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .navigationTitle("Apps")
            .searchable(text: Bindable(service).searchText, prompt: Text("Name or bundle ID"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(service.includeSystem ? "Hide System" : "Show System") {
                        service.includeSystem.toggle()
                        Haptics.select()
                    }
                }
            }
            .task { await service.load() }
            .refreshable { _ = await service.syncRemote() }
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        ContentUnavailableView(
            "iOS Blocked the App List",
            systemImage: "eye.slash",
            description: Text("The app-list APIs need entitlements a normally signed app does not carry. The lines below show which layer failed.")
        )
        .listRowSeparator(.hidden)

        Section("Diagnostics") {
            ForEach(Array(service.diagnostics.rows.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
        }

        Section("Why") {
            Text("Since iOS 18, the installed-app list sits behind entitlements only Apple-signed profiles can carry. A personal development certificate cannot hold them, whatever a resigning tool injects.")
            Text("No signed-app API lists every app any more. The list only exists in Settings, in MDM, or on a computer the iPhone is paired with.")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var syncCaption: String {
        var base = service.syncSource == "device" ? "This iPhone" : "Your computer"
        if let date = service.syncedAt { base += " · \(TimeFormat.ago(date))" }
        return base
    }

    private var syncHint: String {
        service.syncSource == "device" ? "" : "\n\nPull to refresh while the iPhone is connected to the computer that generates the list."
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    @State private var pendingClean: OtherAppsService.Entry?
    let item: InstalledAppsService.Item

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(item.totalBytes))
                Text(item.kind == .user ? "v\(item.version)" : item.kind.rawValue)
                    .font(.caption)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.bundleID).font(.caption.monospaced()).lineLimit(1)
            }
        }
        .contextMenu {
            storageButton
            Button {
                Haptics.tap()
                Task { await cleanCaches(for: item) }
            } label: {
                Label("Clean Caches…", systemImage: "trash")
            }
        }
        .swipeActions {
            storageButton
        }
        .confirmationDialog(
            "Clear caches of \(item.name)?",
            isPresented: Binding(get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } }),
            titleVisibility: .visible
        ) {
            Button("Clear \(ByteFormat.string(pendingClean?.cacheBytes ?? 0))", role: .destructive) {
                if let target = pendingClean {
                    Task { _ = await model.cleanOtherApp(target) }
                }
            }
        } message: {
            Text("Only Caches and temp files are deleted; user data stays.")
        }
    }

    /// Per-app clean straight from the inventory: scan (once) for containers,
    /// match this bundle ID, and ask for confirmation before touching it.
    private func cleanCaches(for item: InstalledAppsService.Item) async {
        let other = model.otherApps
        if other.status == .idle || other.status == .scanning {
            await model.scanOtherApps()
        }
        guard let entry = model.otherApps.entries.first(where: { $0.bundleID == item.bundleID }) else {
            model.toast = "No container found for \(item.name)"
            return
        }
        guard entry.cacheBytes > 0 else {
            model.toast = "\(item.name) has no cached files"
            return
        }
        pendingClean = entry
    }

    private var storageButton: some View {
        Button {
            Haptics.tap()
            openIPhoneStorage()
        } label: {
            Label("Open iPhone Storage", systemImage: "internaldrive")
        }
    }

    /// The only real per-app lever iOS offers: Settings › General › iPhone
    /// Storage, where Offload/Delete live. iOS 15+ ignores the prefs URL
    /// scheme from most third-party apps, so every link is an attempt; when
    /// all of them fail the toast says exactly where to go instead of
    /// pretending the app opened it.
    private func openIPhoneStorage() {
        let links = [
            "App-Prefs:General&path=STORAGE_MGMT",
            "App-Prefs:root=General&path=STORAGE_MGMT",
            "prefs:root=General&path=STORAGE_MGMT",
            "App-Prefs:",
        ].compactMap(URL.init(string:))

        func attempt(_ index: Int) {
            guard index < links.count else {
                model.toast = "iOS blocks the link — Settings › General › iPhone Storage"
                return
            }
            UIApplication.shared.open(links[index], options: [:]) { opened in
                if opened {
                    model.toast = "Check iPhone Storage for \(item.name)"
                } else {
                    DispatchQueue.main.async { attempt(index + 1) }
                }
            }
        }
        attempt(0)
    }
}
