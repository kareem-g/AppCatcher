import Foundation

// MARK: - Cache model

/// The kinds of removable data AppCatcher understands. Order matters: it is
/// also the order rows appear in the cleaner.
enum CacheKind: String, CaseIterable, Identifiable, Codable {
    case caches
    case temp
    case web
    case httpStorage
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "App caches"
        case .temp: return "Temporary files"
        case .web: return "Web & WebView data"
        case .httpStorage: return "Network storage"
        case .logs: return "Diagnostic logs"
        }
    }

    var blurb: String {
        switch self {
        case .caches: return "Regenerated on next launch. Nothing here is yours."
        case .temp: return "Scratch space left behind by downloads and exports."
        case .web: return "Cached pages, icons and service workers from in-app browsers."
        case .httpStorage: return "URLSession cookie and cache blobs on disk."
        case .logs: return "Crash and diagnostic traces collected since install."
        }
    }

    var symbol: String {
        switch self {
        case .caches: return "square.stack.3d.up.slash"
        case .temp: return "doc.zipper"
        case .web: return "globe"
        case .httpStorage: return "cable.coaxial"
        case .logs: return "doc.text.magnifyingglass"
        }
    }

    /// Whether clearing this group can log the user out or drop offline data.
    var isSensitive: Bool {
        switch self {
        case .web, .httpStorage: return true
        default: return false
        }
    }
}

/// One removable directory (or file) inside a kind.
struct CacheItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let kind: CacheKind
    let bytes: Int64
    let fileCount: Int
    let modified: Date?
    let isProtected: Bool

    init(url: URL, kind: CacheKind) {
        self.url = url
        self.kind = kind
        self.title = NamePrettifier.clean(url.lastPathComponent)
        let probe = DiskProbe.scan(url)
        self.bytes = probe.bytes
        self.fileCount = probe.files
        self.modified = DiskProbe.modified(url)
        self.isProtected = Sandbox.protectedNames.contains(url.lastPathComponent)
    }
}

/// A kind plus everything found under it.
struct CacheGroup: Identifiable, Hashable {
    var id: CacheKind { kind }
    let kind: CacheKind
    let items: [CacheItem]

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var itemCount: Int { items.count }
    var isEmpty: Bool { items.isEmpty || bytes == 0 }

    static let empty = CacheGroup(kind: .caches, items: [])
}

/// Snapshot of the container and the volume it lives on.
struct StorageSnapshot {
    var deviceTotal: Int64 = 0
    var deviceFree: Int64 = 0
    var containerTotal: Int64 = 0
    var removable: Int64 = 0
    var documents: Int64 = 0
    var data: Int64 = 0
    var lastClean: Date?
    var lastScan: Date?
    var lifetimeReclaimed: Int64 = 0

    var deviceUsed: Int64 { max(deviceTotal - deviceFree, 0) }
    var containerShare: Double { ByteFormat.percent(containerTotal, of: deviceTotal) }

    static let empty = StorageSnapshot()
}

// MARK: - Backups

/// A sealed `.catcher` archive as AppCatcher remembers it.
struct BackupRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var fileName: String
    var bytes: Int64
    var originalBytes: Int64
    var fileCount: Int
    var isEncrypted: Bool
    var includesCaches: Bool
    var note: String
    var appVersion: String
    var durationSeconds: Double
    /// Set when the archive has been checked since it was made.
    var verifiedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        fileName: String,
        bytes: Int64,
        originalBytes: Int64,
        fileCount: Int,
        isEncrypted: Bool,
        includesCaches: Bool,
        note: String = "",
        appVersion: String = AppInfo.version,
        durationSeconds: Double = 0,
        verifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.fileName = fileName
        self.bytes = bytes
        self.originalBytes = originalBytes
        self.fileCount = fileCount
        self.isEncrypted = isEncrypted
        self.includesCaches = includesCaches
        self.note = note
        self.appVersion = appVersion
        self.durationSeconds = durationSeconds
        self.verifiedAt = verifiedAt
    }

    var url: URL { Sandbox.backups.appendingPathComponent(fileName) }
    var ratio: Double { originalBytes > 0 ? Double(bytes) / Double(originalBytes) : 1 }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}

// MARK: - Activity

enum ActivityKind: String, Codable {
    case cleaned
    case backedUp
    case restored
    case verified
    case unlocked
    case imported
}

struct ActivityEvent: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var kind: ActivityKind
    var title: String
    var detail: String
    var bytes: Int64 = 0
}
