import Foundation
import Observation

/// The single object the whole UI observes. It owns the services, sequences
/// their work, and turns results into history entries and toasts so no view
/// has to invent its own side effects.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let cache: CacheService
    let backups: BackupService
    let activity: ActivityLog
    let pro: ProService
    let apps: InstalledAppsService
    let otherApps = OtherAppsService()

    var toast: String?
    var showingPaywall = false
    var route: Tab = .dashboard

    enum Tab: Hashable {
        case dashboard, cleaner, backups, apps, settings
    }

    init() {
        settings = AppSettings()
        cache = CacheService()
        backups = BackupService()
        activity = ActivityLog()
        pro = ProService()
        apps = InstalledAppsService()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        Haptics.isEnabled = settings.hapticsEnabled
        await cache.scan()
        backups.reload()
        await autoCleanIfNeeded()
    }

    /// Runs the schedule the user configured. Labelled in the UI as
    /// "when you open AppCatcher", because that is what iOS allows.
    func autoCleanIfNeeded() async {
        guard settings.autoCleanIsDue else { return }
        var kinds: Set<CacheKind> = [.caches, .temp, .logs]
        if settings.autoCleanWebData { kinds.insert(.web) }
        let reclaimed = await runClean(kinds: kinds, automatic: true)
        settings.markAutoClean()
        if reclaimed > 0 {
            toast = "Scheduled clean freed \(ByteFormat.string(reclaimed))"
        }
    }

    // MARK: - Cleaning

    @discardableResult
    func runClean(kinds: Set<CacheKind>, automatic: Bool = false) async -> Int64 {
        guard !kinds.isEmpty else { return 0 }
        let reclaimed = await cache.clean(kinds: kinds)
        guard reclaimed > 0 else {
            if !automatic { toast = "Nothing left to clear" }
            await cache.scan()
            return 0
        }

        settings.addReclaimed(reclaimed)
        cache.applyHistory(lifetimeReclaimed: settings.lifetimeReclaimed, lastClean: settings.lastCleanAt)
        activity.record(
            .cleaned,
            automatic ? "Scheduled clean" : "Cleared \(ByteFormat.string(reclaimed))",
            detail: kinds.map(\.title).joined(separator: ", "),
            bytes: reclaimed
        )
        if !automatic {
            Haptics.cleaned()
            toast = "\(ByteFormat.string(reclaimed)) reclaimed"
        }
        return reclaimed
    }

    func rescan() async {
        await cache.scan()
        cache.applyHistory(lifetimeReclaimed: settings.lifetimeReclaimed, lastClean: settings.lastCleanAt)
    }

    // MARK: - Other apps (worse_query; iOS 26–27.2 only)

    func scanOtherApps() async {
        await otherApps.scan()
        otherApps.resolveNames(apps.nameByBundleID)
    }

    @discardableResult
    func cleanOtherApp(_ entry: OtherAppsService.Entry) async -> Int64 {
        let freed = await otherApps.clean(entry)
        if freed > 0 {
            settings.addReclaimed(freed)
            activity.record(
                .cleaned,
                "Cleared \(ByteFormat.string(freed)) in \(entry.name)",
                detail: "Caches + temp files of another app",
                bytes: freed
            )
            Haptics.cleaned()
            toast = "\(ByteFormat.string(freed)) freed from \(entry.name)"
        } else if freed == 0 {
            toast = "Nothing to clear in \(entry.name)"
        } else {
            Haptics.failed()
            toast = "iOS refused access — \(OtherAppsService.explain(freed))"
        }
        await scanOtherApps()
        return freed
    }

    // MARK: - Backups

    @discardableResult
    func createBackup(name: String, note: String, password: String?, includeCaches: Bool) async -> BackupRecord? {
        do {
            let record = try await backups.create(
                name: name,
                note: note,
                password: password,
                includeCaches: includeCaches,
                isPro: pro.isPro
            )
            settings.includeCachesInBackups = includeCaches
            activity.record(
                .backedUp,
                "Backed up \(ByteFormat.string(record.originalBytes))",
                detail: "\(record.fileCount) files → \(ByteFormat.string(record.bytes)) sealed",
                bytes: record.originalBytes
            )
            Haptics.saved()
            toast = "Backup ready · \(ByteFormat.string(record.bytes))"
            return record
        } catch let error as CatcherError {
            handle(error)
        } catch {
            fail(error)
        }
        return nil
    }

    func restore(_ record: BackupRecord, password: String?) async {
        do {
            let outcome = try await backups.restore(record, password: password)
            activity.record(
                .restored,
                "Restored “\(record.name)”",
                detail: "\(outcome.files) files written back",
                bytes: outcome.bytes
            )
            await rescan()
            Haptics.saved()
            toast = "Restored \(outcome.files) files"
        } catch let error as CatcherError {
            handle(error)
        } catch {
            fail(error)
        }
    }

    func verify(_ record: BackupRecord, password: String?) async -> VerifyReport? {
        do {
            let report = try await backups.verify(record, password: password)
            if report.ok {
                activity.record(.verified, "Verified “\(record.name)”", detail: "\(record.fileCount) files intact")
                Haptics.saved()
            } else {
                activity.record(.verified, "Verification failed", detail: report.failures.joined(separator: ", "))
                Haptics.failed()
            }
            return report
        } catch let error as CatcherError {
            handle(error)
        } catch {
            fail(error)
        }
        return nil
    }

    func importBackup(from url: URL) {
        do {
            let record = try backups.importArchive(from: url, isPro: pro.isPro)
            activity.record(
                .imported,
                "Imported “\(record.name)”",
                detail: ByteFormat.string(record.bytes),
                bytes: record.bytes
            )
            Haptics.saved()
            toast = "Backup imported"
        } catch let error as CatcherError {
            handle(error)
        } catch {
            fail(error)
        }
    }

    func delete(_ record: BackupRecord) {
        backups.delete(record)
        Haptics.tap()
        toast = "Backup deleted"
    }

    // MARK: - Errors

    /// A `proOnly` error is not a bug, it is a paywall moment.
    private func handle(_ error: CatcherError) {
        switch error {
        case .proOnly:
            Haptics.warning()
            showingPaywall = true
        case .wrongPassword:
            Haptics.failed()
            toast = "Wrong password"
        default:
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        Haptics.failed()
        toast = error.localizedDescription
    }
}
