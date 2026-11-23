import SwiftUI

/// The detailed list: every group, every folder inside it, and exactly what a
/// tap will remove.
struct CleanerView: View {
    @Environment(AppModel.self) private var model

    @State private var confirming = false

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
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .navigationTitle("Cleaner")
            .refreshable { await model.rescan() }
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
