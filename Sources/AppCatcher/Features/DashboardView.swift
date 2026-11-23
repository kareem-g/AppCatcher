import SwiftUI

/// Home screen: what is taking space, what AppCatcher can win back, and the
/// one tap that does it.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private var cache: CacheService { model.cache }
    private var snapshot: StorageSnapshot { cache.snapshot }

    var body: some View {
        NavigationStack {
            List {
                Section { summary }

                Section {
                    ForEach(breakdown, id: \.0) { label, bytes in
                        LabeledContent(label, value: ByteFormat.string(bytes))
                    }
                } header: {
                    Text("This App")
                } footer: {
                    Text("Scanned \(lastScanText). iOS keeps every app in its own sandbox, so AppCatcher can only clear its own files. For other apps, use Settings › General › iPhone Storage.")
                        .footnote()
                }

                Section("iPhone") {
                    LabeledContent("Available", value: ByteFormat.string(snapshot.deviceFree))
                    LabeledContent("Used", value: ByteFormat.string(snapshot.deviceUsed))
                    LabeledContent("Last backup", value: model.backups.latest.map { TimeFormat.ago($0.createdAt) } ?? "Never")
                }

                if !model.activity.events.isEmpty {
                    Section("Recent Activity") {
                        ForEach(model.activity.events.prefix(4)) { event in
                            LabeledContent {
                                Text(TimeFormat.ago(event.date))
                            } label: {
                                Text(event.title)
                                Text(event.detail).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.pro.isPro {
                        Button("Pro", systemImage: "crown") { model.showingPaywall = true }
                    }
                }
            }
            .refreshable { await model.rescan() }
            .task {
                if !cache.hasScanned { await model.rescan() }
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormat.string(cache.removable))
                    .font(.system(size: 44, weight: .bold))
                    .contentTransition(.numericText())
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            Gauge(value: Double(cache.removable), in: 0...Double(max(snapshot.containerTotal, cache.removable, 1))) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)

            Button(cleanTitle) { clean() }
                .buttonStyle(.borderedProminent)
                .disabled(cache.isBusy || quickBytes == 0)

            if !cache.isBusy && quickBytes < cache.removable {
                Text("Web data (\(ByteFormat.string(cache.removable - quickBytes))) is kept so you stay signed in. Clear it from Cleaner.")
                    .footnote()
            }
        }
        .padding(.vertical, 8)
        .animation(.default, value: cache.removable)
    }

    private var subtitle: String {
        if cache.isBusy { return "Working…" }
        if cache.removable == 0 && cache.hasScanned { return "Nothing to clear right now" }
        return "can be cleared, of \(ByteFormat.string(snapshot.containerTotal)) this app uses"
    }

    /// Web data only joins the one-tap clean when the user opted in; it can
    /// sign them out of embedded sessions. The button names exactly what it removes.
    private var quickGroups: [CacheGroup] {
        cache.groups.filter { $0.bytes > 0 && ($0.kind != .web || model.settings.autoCleanWebData) }
    }

    private var quickBytes: Int64 { quickGroups.reduce(0) { $0 + $1.bytes } }

    private var cleanTitle: String {
        if cache.isBusy { return "Working…" }
        if quickBytes == 0 { return "All Clear" }
        return "Clean Up \(ByteFormat.string(quickBytes))"
    }

    private func clean() {
        let kinds = Set(quickGroups.map(\.kind))
        Task {
            Haptics.scanComplete()
            _ = await model.runClean(kinds: kinds)
        }
    }

    private var breakdown: [(String, Int64)] {
        [
            ("Caches", cache.group(for: .caches)?.bytes ?? 0),
            ("Temporary files", cache.group(for: .temp)?.bytes ?? 0),
            ("Web & network", (cache.group(for: .web)?.bytes ?? 0) + (cache.group(for: .httpStorage)?.bytes ?? 0)),
            ("Documents", snapshot.documents),
            ("App data", max(snapshot.data - snapshot.documents, 0)),
        ]
    }

    private var lastScanText: String {
        guard let date = cache.lastScan else { return "never" }
        return TimeFormat.ago(date)
    }
}
