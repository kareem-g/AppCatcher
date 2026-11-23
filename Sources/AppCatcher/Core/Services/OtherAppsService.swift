import Foundation
import Observation
import WorseQuery

/// Cache cleaning for apps AppCatcher does not own.
///
/// iOS sandboxes every app, so the only way in is the `worse_query` container
/// query (Taj C / forcequit, GPLv3+): it convinces containermanagerd to issue
/// a kernel sandbox extension for an arbitrary container path. The bug works
/// on iOS 26.0–26.7.2 and 27.2; Apple patched it in 27.3, where this service
/// degrades to an honest "blocked" state instead of pretending.
///
/// Scope is deliberately narrow: only `Library/Caches` and `tmp` inside the
/// target container — both are regenerable by design. Documents, Preferences
/// and the rest of Library are never touched, so cleaning cannot lose user
/// data; the worst case is an app re-downloading its cache.
@MainActor
@Observable
final class OtherAppsService {
    struct Entry: Identifiable, Hashable {
        let containerPath: String
        let bundleID: String
        var name: String
        var cacheBytes: Int64

        var id: String { bundleID + "@" + containerPath }
    }

    enum Status: Equatable {
        case idle
        case scanning
        case ready
        case unavailable(String)
    }

    static let groupID = "group.com.appcatcher.app"

    private static let applicationRoot: String? = {
        // …/Data/Application/<UUID> → …/Data/Application. This is the same
        // root on device and in the simulator, so the scan logic is shared.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let parts = home.pathComponents
        guard let index = parts.lastIndex(of: "Data"),
              index > 0, index < parts.count - 1, parts[index + 1] == "Application"
        else { return nil }
        return URL(fileURLWithPath: parts[0...index].joined(separator: "/")).path
    }()

    private(set) var status: Status = .idle
    private(set) var entries: [Entry] = []
    private(set) var cleaning: Set<String> = []
    private(set) var scannedContainers = 0

    var diagnostic: String? {
        if case .unavailable(let text) = status { return text }
        return nil
    }

    // MARK: - Scan

    /// Enumerates sibling app containers, reads each container's bundle ID
    /// from its `com.apple.containermanager.identifier` xattr, and sums the
    /// regenerable bytes. The extension is only held while measuring; access
    /// ends before the list reaches the UI.
    func scan() async {
        guard let root = Self.applicationRoot else {
            status = .unavailable("Could not locate the Application container root.")
            return
        }
        status = .scanning
        entries = []

        let paths = await Task.detached(priority: .userInitiated) { [root] () -> [String] in
            let baseline = Self.baselineInode()
            guard baseline > 0 else { return [] }
            return pathleak(root, baseline) as? [String] ?? []
        }.value

        guard !paths.isEmpty else {
            status = .unavailable(
                "No containers visible from here. Either the kernel refuses the path enumeration (iOS 27.3+ patched it) or the sandbox blocked it."
            )
            return
        }

        var found: [Entry] = []
        var failures: [String] = []
        for path in paths {
            let handle = Self.consume(path)
            guard handle > 0 else {
                failures.append(Self.explain(handle))
                continue
            }
            defer { Self.release(handle) }

            let bundleID = Self.containerIdentifier(path)
            let bytes = Self.regenerableBytes(path)
            scannedContainers += 1
            if bundleID != nil && bytes > 0 {
                found.append(Entry(
                    containerPath: path,
                    bundleID: bundleID ?? path,
                    name: bundleID ?? path,
                    cacheBytes: bytes
                ))
            }
        }

        guard !found.isEmpty else {
            status = .unavailable(
                "Extensions were refused for every container (\(failures.first ?? "unknown reason")). On iOS 27.3+ the query is patched; elsewhere check the App Group entitlement."
            )
            return
        }

        found.sort { $0.cacheBytes > $1.cacheBytes }
        entries = found
        status = .ready
    }

    /// After a scan, swap raw bundle IDs for human names where the installed
    /// apps inventory (private API or synced list) can provide them.
    func resolveNames(_ lookup: [String: String]) {
        for index in entries.indices {
            if let name = lookup[entries[index].bundleID] {
                entries[index].name = name
            }
        }
    }

    // MARK: - Clean

    /// Clears `Library/Caches` and `tmp` inside one app's container and
    /// returns the bytes actually freed.
    @discardableResult
    func clean(_ entry: Entry) async -> Int64 {
        cleaning.insert(entry.id)
        defer { cleaning.remove(entry.id) }

        let freed = await Task.detached(priority: .userInitiated) { () -> Int64 in
            Self.cleanContainer(entry.containerPath)
        }.value
        if freed >= 0 {
            let index = entries.firstIndex { $0.id == entry.id }
            if let index { entries[index].cacheBytes = max(entries[index].cacheBytes - freed, 0) }
        }
        return freed
    }

    // MARK: - Primitives (static so they can run off the main actor)

    nonisolated static func explain(_ handle: Int64) -> String {
        switch handle {
        case -1: return "App Group container unavailable (entitlement not honoured by this signature)"
        case -2: return "containermanagerd functions not found (unsupported OS)"
        case -3: return "query could not be created"
        case -4: return "symlink could not be created"
        case -5: return "query rejected by containermanagerd"
        case -6: return "kernel refused to issue the extension"
        case -7: return "extension issued but the kernel still denies file access (iOS version may not be exploitable)"
        case -255: return "target path does not exist"
        default: return "unknown failure \(handle)"
        }
    }

    /// Thin wrapper over the PoC entry point, including its iOS 26 AppGroup
    /// flag quirk. Kept private to this file so no other feature can reach
    /// into other apps' containers.
    fileprivate nonisolated static func consume(_ path: String) -> Int64 {
        var handle: Int64
        if path.contains("/Containers/Shared/AppGroup"),
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
            handle = worse_query(path, groupID, true, false)
        } else {
            handle = worse_query(path, groupID, false, false)
        }
        return handle
    }

    fileprivate nonisolated static func release(_ handle: Int64) {
        worse_query_release(handle)
    }

    /// The PoC's trick: stat() a file we created to learn a fresh inode, then
    /// brute-force fsgetpath up to it. Slow, but reliable on every supported
    /// OS the PoC lists.
    private nonisolated static func baselineInode() -> UInt64 {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent(".baseline_\(UUID().uuidString)")
        guard (try? "baseline".write(to: url, atomically: true, encoding: .utf8)) != nil else { return 0 }
        defer { try? fm.removeItem(at: url) }
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return UInt64(st.st_ino)
    }

    /// Reads the bundle ID stashed on the container directory by iOS. Devices
    /// carry a dedicated xattr; simulators pack the identifier inside the
    /// richer `identity` blob, so both shapes are handled.
    private nonisolated static func containerIdentifier(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = getxattr(path, "com.apple.containermanager.identifier", &buffer, 511, 0, 0)
        if length > 0 {
            let direct = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !direct.isEmpty { return direct }
        }

        var blob = [CChar](repeating: 0, count: 4096)
        let blobLength = getxattr(path, "com.apple.containermanager.identity", &blob, 4095, 0, 0)
        guard blobLength > 0 else { return nil }
        for line in String(cString: blob).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("identifier:") {
                let id = trimmed.dropFirst("identifier:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { return id }
            }
        }
        return nil
    }

    /// Recursive size of the two regenerable roots inside a container.
    private nonisolated static func regenerableBytes(_ container: String) -> Int64 {
        cacheDirs(in: container).reduce(0) { $0 + directorySize($1) }
    }

    private nonisolated static func cacheDirs(in container: String) -> [URL] {
        let root = URL(fileURLWithPath: container)
        let fm = FileManager.default
        var dirs: [URL] = [root.appendingPathComponent("tmp", isDirectory: true)]
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            dirs.append(contentsOf: children)
        } else {
            dirs.append(caches)
        }
        return dirs.filter { fm.fileExists(atPath: $0.path) }
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes the contents (never the roots themselves) of `tmp` and
    /// `Library/Caches`, returning the bytes freed, or a negative worse_query
    /// code when the container could not be opened at all.
    private nonisolated static func cleanContainer(_ container: String) -> Int64 {
        let handle = consume(container)
        guard handle > 0 else { return handle }
        defer { release(handle) }

        let fm = FileManager.default
        let dirs = cacheDirs(in: container)
        // The extension was issued, but that is no guarantee the kernel lets
        // us through (older patch levels behave differently). If even the
        // listing fails, say so instead of reporting a silent zero.
        if let first = dirs.first,
           (try? fm.contentsOfDirectory(atPath: first.path)) == nil {
            return accessError
        }

        var freed: Int64 = 0
        for dir in dirs {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for child in children {
                let bytes = directorySize(child)
                do {
                    try fm.removeItem(at: child)
                    freed += bytes
                } catch {
                    // A busy or immutable file is skipped, not fatal.
                    continue
                }
            }
        }
        return freed
    }

    /// Returned when the extension was issued but file access still failed.
    nonisolated static let accessError: Int64 = -7
}
