import SwiftUI

/// The detailed list: every group, every folder inside it, and exactly what a
/// tap will remove.
struct CleanerView: View {
    @Environment(AppModel.self) private var model

    @State private var confirming = false
    @State private var pendingClean: OtherAppsService.Entry?

    private var cache: CacheService { model.cache }

    var body: some View {
        NavigationStack {
            List {
                if cache.groups.isEmpty {
                    ContentUnavailableView {
                        Label(cache.hasScanned ? "Nothing to Clear" : "Not Scanned Yet",
                              systemImage: cache.hasScanned ? "checkmark.circle" : "magnifyingglass")
                    } description: {
                        Text(cache.hasScanned
                             ? "This app is already lean. New files appear as soon as you use it again."
                             : "AppCatcher looks for caches, temporary files and web storage.")
                    } actions: {
                        Button("Scan") { Task { await model.rescan() } }
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(cache.groups) { group in
                        Section {
                            row(group)
                        } footer: {
                            if group.kind.isSensitive {
                                Text("Clearing this can sign you out of web pages opened inside AppCatcher.").footnote()
                            }
                        }
                    }

                    otherAppsSection
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .navigationTitle("Cleaner")
            .refreshable { await model.rescan() }
            .task { if model.otherApps.status == .idle { await model.scanOtherApps() } }
            .confirmationDialog(
                "Clear caches of \(pendingClean?.name ?? "this app")?",
                isPresented: Binding(get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } }),
                titleVisibility: .visible
            ) {
                Button("Clear \(ByteFormat.string(pendingClean?.cacheBytes ?? 0))", role: .destructive) {
                    if let target = pendingClean {
                        Task { _ = await model.cleanOtherApp(target) }
                    }
                }
            } message: {
                Text("Only Caches and temp files are deleted; user data stays. The app may rebuild its cache on next launch.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(cache.isAllSelected ? "Deselect All" : "Select All") {
                        Haptics.select()
                        cache.selection = cache.isAllSelected ? [] : Set(cache.groups.map(\.kind))
                    }
                    .disabled(cache.groups.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(cache.selection.isEmpty ? "Clear" : "Clear \(ByteFormat.string(cache.selectedBytes))") { confirming = true }
                        .disabled(cache.selection.isEmpty || cache.isBusy)
                        .confirmationDialog(
                            "Clear \(ByteFormat.string(cache.selectedBytes))?",
                            isPresented: $confirming,
                            titleVisibility: .visible
                        ) {
                            Button("Clear", role: .destructive) {
                                let kinds = cache.selection
                                Task { await model.runClean(kinds: kinds) }
                            }
                        } message: {
                            Text("Caches rebuild themselves. Web data can sign you out of pages opened inside the app.")
                        }
                }
            }
        }
    }

    // MARK: Other apps

    @ViewBuilder
    private var otherAppsSection: some View {
        let other = model.otherApps
        switch other.status {
        case .idle:
            Section("Other Apps") {
                Button("Scan Other Apps") { Task { await model.scanOtherApps() } }
                Text("Uses a published container-manager bug to reach other apps' regenerable caches. Works on iOS 26.0–26.7.2 and 27.2; Apple patched it in 27.3.")
                    .footnote()
            }

        case .scanning:
            Section("Other Apps") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Enumerating app containers…").foregroundStyle(.secondary)
                }
            }

        case .unavailable(let why):
            Section("Other Apps") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blocked by iOS").font(.headline)
                    Text(why).foregroundStyle(.secondary).footnote()
                }
            }

        case .ready:
            Section {
                ForEach(other.entries) { entry in
                    otherRow(entry)
                }
            } header: {
                Text("Other Apps")
            } footer: {
                Text("Via the worse_query container bug (Taj C / forcequit, GPLv3+). Only Caches and temp files are deleted — never Documents, Preferences or the app itself. Patched by Apple in 27.3.")
                    .footnote()
            }
        }
    }

    private func otherRow(_ entry: OtherAppsService.Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(entry.bundleID).font(.caption.monospaced()).lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.otherApps.cleaning.contains(entry.id) {
                ProgressView()
            } else {
                Button("Clean") { pendingClean = entry }
                    .buttonStyle(.bordered)
                    .disabled(entry.cacheBytes == 0)
            }
        }
    }

    private func row(_ group: CacheGroup) -> some View {
        let isOn = Binding(
            get: { cache.selection.contains(group.kind) },
            set: { on in
                if on { cache.selection.insert(group.kind) } else { cache.selection.remove(group.kind) }
            }
        )
        return Group {
            Toggle(isOn: isOn) {
                LabeledContent {
                    Text(ByteFormat.string(group.bytes))
                } label: {
                    Text(group.kind.title)
                    Text(group.kind.blurb)
                }
            }

            DisclosureGroup("\(group.itemCount) folder\(group.itemCount == 1 ? "" : "s")") {
                ForEach(group.items.prefix(12)) { item in
                    LabeledContent {
                        Text(ByteFormat.string(item.bytes))
                    } label: {
                        Label(item.title, systemImage: item.isProtected ? "lock" : "folder")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                }
                if group.items.count > 12 {
                    Text("\(group.items.count - 12) more").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

extension CacheService {
    var isAllSelected: Bool {
        !groups.isEmpty && groups.allSatisfy { selection.contains($0.kind) }
    }
}
