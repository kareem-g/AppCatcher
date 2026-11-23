import SwiftUI

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
                        Text("Read-only. No app can read or clear another app's files, so the only control per app is Settings › General › iPhone Storage (Offload or Delete).\(syncHint)")
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
    let item: InstalledAppsService.Item

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(item.totalBytes))
                Text(item.kind == .user ? "v\(item.version)" : item.kind.rawValue)
                    .font(.caption)
            }
        } label: {
            Label {
                Text(item.name).lineLimit(1)
                Text(item.bundleID).font(.caption.monospaced()).lineLimit(1)
            } icon: {
                // No icons are reachable without more private API: a plain monogram.
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
