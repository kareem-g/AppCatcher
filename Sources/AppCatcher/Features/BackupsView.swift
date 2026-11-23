import SwiftUI
import UniformTypeIdentifiers

/// Backups: seal the container into one verifiable file, keep history, restore
/// it later, move archives in and out with the Files app.
struct BackupsView: View {
    @Environment(AppModel.self) private var model

    @State private var showCreate = false
    @State private var showImport = false

    private var backups: BackupService { model.backups }

    var body: some View {
        NavigationStack {
            List {
                if backups.records.isEmpty {
                    ContentUnavailableView {
                        Label("No Backups", systemImage: "lock.doc")
                    } description: {
                        Text("Seal your documents and app data into one archive you can verify and restore.")
                    } actions: {
                        Button("New Backup") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(backups.records) { record in
                            NavigationLink {
                                BackupDetailView(record: record)
                            } label: {
                                BackupRow(record: record)
                            }
                        }
                    }

                    Section("Vault") {
                        LabeledContent("Archives", value: "\(backups.records.count)")
                        LabeledContent("On disk", value: ByteFormat.string(backups.totalBytes))
                        if let latest = backups.latest {
                            LabeledContent("Latest compression", value: String(format: "%.0f%%", latest.ratio * 100))
                        }
                    }
                }

                Section {
                    LabeledContent("Documents", value: "Always")
                    LabeledContent("App data", value: "Always")
                    LabeledContent("Caches", value: "Optional")
                    if !model.pro.isPro {
                        Button("Keep Every Version with Pro") { model.showingPaywall = true }
                            .foregroundStyle(.tint)
                    }
                } header: {
                    Text("What's Included")
                } footer: {
                    Text("Every file is compressed and checksummed. With a password, the archive is sealed with AES-256-GCM, so a copied .catcher file is useless without it.\(model.pro.isPro ? "" : " The free version keeps one archive at a time.")")
                        .footnote()
                }
            }
            .listStyle(.plain)
            .monospacedDigit()
            .navigationTitle("Backups")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Import", systemImage: "square.and.arrow.down") { showImport = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Backup", systemImage: "plus") { showCreate = true }
                        .disabled(backups.isBusy)
                }
            }
            .sheet(isPresented: $showCreate) { NewBackupSheet() }
            .fileImporter(
                isPresented: $showImport,
                allowedContentTypes: [.catcherArchive, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.importBackup(from: url) }
                case .failure(let error):
                    model.toast = "Could not open that file: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Row

private struct BackupRow: View {
    let record: BackupRecord

    var body: some View {
        LabeledContent {
            Text(ByteFormat.string(record.bytes))
        } label: {
            Label {
                Text(record.name)
                Text("\(TimeFormat.exact(record.createdAt)) · \(record.fileCount) file\(record.fileCount == 1 ? "" : "s")")
            } icon: {
                Image(systemName: record.isEncrypted ? "lock.doc" : "doc.zipper")
            }
        }
    }
}

// MARK: - Create sheet

struct NewBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var note = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var includeCaches = false
    @State private var mismatch = false

    var body: some View {
        NavigationStack {
            List {
                if model.backups.isBusy {
                    ProgressView("Compressing and sealing…", value: model.backups.progress)
                }

                Section {
                    TextField("Name", text: $name, prompt: Text(Date().shortStamp))
                        .textInputAutocapitalization(.never)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Include caches", isOn: $includeCaches)
                } header: {
                    Text("Archive")
                } footer: {
                    Text("Documents and app data are always included. Caches rebuild themselves, so they are usually dead weight.").footnote()
                }

                Section {
                    SecureField("Password", text: $password)
                    SecureField("Repeat password", text: $confirm)
                } header: {
                    Text(model.pro.isPro ? "Encryption" : "Encryption · Pro")
                } footer: {
                    if mismatch {
                        Text("The two passwords do not match.").font(.footnote).foregroundStyle(.red)
                    } else {
                        Text("Leave empty for a plain archive. A forgotten password cannot be recovered.").footnote()
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section("Summary") {
                    LabeledContent("Source size", value: ByteFormat.string(estimatedSource))
                    LabeledContent("Archives kept", value: model.pro.isPro ? "Unlimited" : "1")
                }
            }
            .listStyle(.plain)
            .disabled(model.backups.isBusy)
            .navigationTitle("New Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Seal", action: seal)
                        .disabled(model.backups.isBusy)
                }
            }
        }
    }

    private func seal() {
        guard password.isEmpty || password == confirm else {
            mismatch = true
            Haptics.warning()
            return
        }
        mismatch = false
        Task {
            let record = await model.createBackup(
                name: name,
                note: note,
                password: password.isEmpty ? nil : password,
                includeCaches: includeCaches
            )
            if record != nil { dismiss() }
        }
    }

    private var estimatedSource: Int64 {
        var total = DeepSize.of(Sandbox.documents) + DeepSize.of(Sandbox.appSupport)
        if includeCaches { total += DeepSize.of(Sandbox.caches) }
        return total
    }
}

// MARK: - Detail

struct BackupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let record: BackupRecord
    @State private var password = ""
    @State private var askBeforeRestore = false
    @State private var askBeforeDelete = false
    @State private var report: VerifyReport?

    var body: some View {
        List {
            Section {
                LabeledContent("Created", value: TimeFormat.exact(live.createdAt))
                if !live.note.isEmpty {
                    LabeledContent("Note", value: live.note)
                }
                LabeledContent("Files", value: "\(live.fileCount)")
                LabeledContent("Archive size", value: ByteFormat.string(live.bytes))
                LabeledContent("Original size", value: ByteFormat.string(live.originalBytes))
                LabeledContent("Compression", value: String(format: "%.0f%%", live.ratio * 100))
                LabeledContent("Encryption", value: live.isEncrypted ? "AES-256" : "None")
                LabeledContent("Caches", value: live.includesCaches ? "Included" : "Not included")
                LabeledContent("Integrity", value: integrityText)
                LabeledContent("Made by", value: "AppCatcher \(live.appVersion)")
            }

            if record.isEncrypted {
                Section("Password") {
                    SecureField("Archive password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Group {
                    Button("Restore", systemImage: "arrow.uturn.backward", action: beginRestore)
                        .disabled(model.backups.phase != .idle)
                    Button("Verify", systemImage: "checkmark.seal") {
                        Task { report = await model.verify(record, password: password.isEmpty ? nil : password) }
                    }
                    .disabled(model.backups.phase != .idle)
                    ShareLink(item: record.url, preview: SharePreview(record.name)) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .foregroundStyle(.tint)
            } footer: {
                if model.backups.phase != .idle {
                    ProgressView()
                } else {
                    Text("Restoring writes the archive back over your current documents. What was there is kept as a guarded copy, which you can delete in Settings.").footnote()
                }
            }

            Section {
                Button("Delete Archive", systemImage: "trash", role: .destructive) { askBeforeDelete = true }
            }
        }
        .listStyle(.plain)
        .monospacedDigit()
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Restore \(ByteFormat.string(record.originalBytes))?",
            isPresented: $askBeforeRestore,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive, action: runRestore)
        } message: {
            Text("Files in Documents with the same names are replaced. The previous contents are kept as a guarded copy.")
        }
        .confirmationDialog("Delete this archive?", isPresented: $askBeforeDelete, titleVisibility: .visible) {
            Button("Delete Archive", role: .destructive) {
                model.delete(record)
                dismiss()
            }
        } message: {
            Text("The .catcher file is removed from this iPhone. Copies you exported are not affected.")
        }
        .sheet(item: $report) { VerifyReportSheet(report: $0) }
    }

    /// The catalogue copy, so a successful verify shows up immediately.
    private var live: BackupRecord {
        model.backups.records.first { $0.id == record.id } ?? record
    }

    private var integrityText: String {
        guard let checked = live.verifiedAt else { return "Not checked" }
        return "Verified \(TimeFormat.ago(checked))"
    }

    private func beginRestore() {
        guard model.backups.phase == .idle else { return }
        if model.settings.confirmBeforeRestore {
            askBeforeRestore = true
        } else {
            runRestore()
        }
    }

    private func runRestore() {
        Task {
            await model.restore(record, password: password.isEmpty ? nil : password)
            dismiss()
        }
    }
}

// MARK: - Verify report

struct VerifyReportSheet: View {
    let report: VerifyReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(report.ok ? "Archive is intact" : "Archive is damaged",
                          systemImage: report.ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(report.ok ? .green : .red)
                    LabeledContent("Files checked", value: "\(report.header.fileCount)")
                    LabeledContent("Time", value: TimeFormat.duration(report.seconds))
                }
                if !report.ok {
                    Section("Failed Files") {
                        ForEach(report.failures.prefix(12), id: \.self) { path in
                            Text(path).font(.footnote.monospaced())
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Identifiable sheets

extension VerifyReport: Identifiable {
    var id: String { "\(header.label)-\(header.createdAt.timeIntervalSince1970)" }
}

extension UTType {
    /// The `.catcher` container. Declared as a dynamic type so the file
    /// importer can grey out everything else.
    static let catcherArchive = UTType(exportedAs: "appcatcher.archive")
}
