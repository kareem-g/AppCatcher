import Foundation
import Observation
import UIKit

/// A read-only view of what is installed on the device.
///
/// iOS gives third-party apps no public API to enumerate other apps. The
/// private APIs that do this (`LSApplicationWorkspace`, `MobileInstallation`)
/// require special entitlements on modern iOS; from a plain signed app they
/// come back empty. This service tries every route it can and, when nothing
/// works, reports *exactly which layer failed* so the fix can be targeted —
/// in practice the fix is re-signing with
/// `com.apple.private.coreservices.canmaplsdatabase` + the MobileInstallation
/// entitlement, which iOS honours from a development certificate.
/// Where the installed-app inventory JSON lives. Every host string here is a
/// personal deployment value — replace with your own Tailscale MagicDNS name
/// and LAN address, or set them via UserDefaults keys below.
enum SyncConfig {
    static let tailnetHostKey = "appcatcher.sync.tailnetHost"
    static let lanHostKey = "appcatcher.sync.lanHost"

    /// Defaults are placeholders; the paired-computer sync shows the
    /// "unavailable" state until both are configured.
    static var tailnetHost: String {
        UserDefaults.standard.string(forKey: tailnetHostKey) ?? "example-host.ts.net"
    }
    static var lanHost: String {
        UserDefaults.standard.string(forKey: lanHostKey) ?? "192.168.0.10"
    }
}

@MainActor
@Observable
final class InstalledAppsService {
    struct Item: Identifiable, Hashable {
        let id: String
        let name: String
        let bundleID: String
        let version: String
        let kind: Kind
        let staticBytes: Int64
        let dynamicBytes: Int64

        enum Kind: String { case user = "User", system = "System", unknown = "Other" }

        var totalBytes: Int64 { staticBytes + dynamicBytes }
    }

    /// Why the last load produced nothing, one line per layer. Shown verbatim
    /// on the empty screen so a one-line report from the user pins the cause.
    struct Diagnostics {
        var iosVersion = ""
        var bridgeSelfTest = "unchecked"
        var workspace = "not attempted"
        var workspaceViaAllInstalled = "not attempted"
        var mobileInstall = "not attempted"
        var rows: [String] {
            ["iOS \(iosVersion)",
             "objc bridge: \(bridgeSelfTest)",
             "LSApplicationWorkspace: \(workspace)",
             "LSApplicationWorkspace allInstalled: \(workspaceViaAllInstalled)",
             "MobileInstallationLookup: \(mobileInstall)"]
        }
    }

    private(set) var items: [Item] = []
    private(set) var loaded = false
    private(set) var unavailable = false
    private(set) var diagnostics = Diagnostics()
    /// Where the current list came from: "device" (a working private API),
    /// "tailnet" / "lan" (synced from the paired computer), or "".
    private(set) var syncSource = ""
    private(set) var syncedAt: Date?

    var searchText = ""
    var includeSystem = false

    var visible: [Item] {
        let base = includeSystem ? items : items.filter { $0.kind != .system }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var userBytes: Int64 { items.filter { $0.kind == .user }.reduce(0) { $0 + $1.totalBytes } }
    var userCount: Int { items.filter { $0.kind == .user }.count }

    /// bundleID → display name, for services that only know bundle IDs
    /// (e.g. containers found by the worse_query scan).
    var nameByBundleID: [String: String] {
        Dictionary(items.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        diagnostics.iosVersion = UIDevice.current.systemVersion
        diagnostics.bridgeSelfTest = Msg.selfTest()

        let viaWorkspace: ([Item], String) = Self.enumerateViaWorkspace()
        diagnostics.workspace = viaWorkspace.1

        var viaAllInstalled: ([Item], String) = ([], "not attempted")
        if viaWorkspace.0.isEmpty {
            viaAllInstalled = Self.enumerateViaWorkspace(selector: "allInstalledApplications")
            diagnostics.workspaceViaAllInstalled = viaAllInstalled.1
        }

        let viaMobile: ([Item], String) = viaWorkspace.0.isEmpty && viaAllInstalled.0.isEmpty
            ? Self.enumerateViaMobileInstallation()
            : ([], "skipped")

        diagnostics.mobileInstall = viaMobile.1

        let found = viaWorkspace.0.isEmpty
            ? (viaAllInstalled.0.isEmpty ? viaMobile.0 : viaAllInstalled.0)
            : viaWorkspace.0

        if !found.isEmpty {
            items = Self.sorted(found)
            syncSource = "device"
            return
        }

        // iOS serves nothing to a signed app, so pull the list from the
        // paired computer instead (it generates inventory.json via USB).
        if await syncRemote() { return }
        unavailable = true
    }

    /// Fetches `inventory.json` from the paired machine. Tries the Tailscale
    /// URL first, then the LAN address.
    @discardableResult
    func syncRemote() async -> Bool {
        let candidates: [(source: String, url: URL)] = [
            ("tailnet", URL(string: "https://\(SyncConfig.tailnetHost)/appcatcher/inventory.json")!),
            ("lan", URL(string: "http://\(SyncConfig.lanHost):4713/inventory.json")!),
        ]
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.timeoutInterval = 6
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let entries = try JSONDecoder().decode([RemoteEntry].self, from: data)
                let mapped = entries.map {
                    Item(
                        id: $0.bundle,
                        name: $0.name,
                        bundleID: $0.bundle,
                        version: $0.version,
                        kind: .user,
                        staticBytes: $0.staticBytes,
                        dynamicBytes: $0.dynamicBytes
                    )
                }
                guard !mapped.isEmpty else { continue }
                items = Self.sorted(mapped)
                syncSource = candidate.source
                syncedAt = .now
                unavailable = false
                return true
            } catch {
                continue
            }
        }
        return false
    }

    nonisolated private static func sorted(_ found: [Item]) -> [Item] {
        found.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .user }
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Mirrors what `scripts/usb.sh apps` emits: one entry per installed app.
    private struct RemoteEntry: Decodable {
        let bundle: String
        let name: String
        let version: String
        let staticBytes: Int64
        let dynamicBytes: Int64

        enum CodingKeys: String, CodingKey {
            case bundle, name, version
            case staticBytes = "static"
            case dynamicBytes = "dynamic"
        }
    }

    // MARK: - Private API bridge

    /// Minimal `objc_msgSend` trampoline, plus a self-test so a dead bridge is
    /// never reported as "iOS returned no apps".
    private enum Msg {
        typealias Send = @convention(c) (AnyObject, Selector) -> AnyObject?

        private static let impl: Send? = {
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            guard let symbol = dlsym(rtldDefault, "objc_msgSend") else { return nil }
            return unsafeBitCast(symbol, to: Send.self)
        }()

        static func sendObject(_ target: AnyObject, _ selector: Selector) -> AnyObject? {
            impl?(target, selector)
        }

        /// Sends a zero-argument selector to a plain object to prove the
        /// trampoline talks to the ObjC runtime at all. `description` always
        /// returns a string, so a nil result means the bridge is broken.
        static func selfTest() -> String {
            guard let impl else { return "dlsym failed" }
            let object = NSObject()
            let result = impl(object, NSSelectorFromString("description"))
            return result == nil ? "returned nil" : "ok"
        }
    }

    /// One `<method>` on LSApplicationWorkspace. Reports back like
    /// "class=nil | no-workspace | no-method | count=0 | 27 apps" so the UI
    /// can say which layer failed.
    nonisolated private static func enumerateViaWorkspace(selector: String = "allApplications") -> ([Item], String) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return ([], "class=nil")
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = Msg.sendObject(workspaceClass as AnyObject, defaultSelector) as? NSObject else {
            return ([], "defaultWorkspace failed")
        }

        let allSelector = NSSelectorFromString(selector)
        guard workspace.responds(to: allSelector) else {
            return ([], "no \(selector) method")
        }
        guard let result = Msg.sendObject(workspace, allSelector) else {
            return ([], "\(selector) returned nil")
        }

        var proxies: [NSObject] = []
        if let array = result as? NSArray {
            proxies = array.compactMap { $0 as? NSObject }
        } else if let array = result as? [NSObject] {
            proxies = array
        }
        guard !proxies.isEmpty else { return ([], "\(selector) empty array") }

        var out: [Item] = []
        out.reserveCapacity(proxies.count)
        for proxy in proxies {
            guard let bundleID = string(proxy, "applicationIdentifier"), !bundleID.isEmpty else { continue }
            let name = string(proxy, "localizedName") ?? string(proxy, "itemName") ?? bundleID
            out.append(Item(
                id: bundleID,
                name: name,
                bundleID: bundleID,
                version: string(proxy, "bundleVersion") ?? "—",
                kind: kind(for: string(proxy, "applicationType") ?? ""),
                staticBytes: number(proxy, "staticDiskUsage") ?? 0,
                dynamicBytes: number(proxy, "dynamicDiskUsage") ?? 0
            ))
        }
        return (out, "\(out.count) apps")
    }

    /// Direct call into `MobileInstallationLookup` from the private framework.
    nonisolated private static func enumerateViaMobileInstallation() -> ([Item], String) {
        guard let lookup = MobileInstall.lookup else {
            return ([], "symbol=nil")
        }
        let options: NSDictionary = ["ApplicationType": "User"]
        guard let cfResult = lookup(options as CFDictionary) else {
            return ([], "returned nil")
        }
        let result = cfResult as NSDictionary
        guard CFDictionaryGetCount(cfResult) > 0 else { return ([], "empty dict") }

        var out: [Item] = []
        for (key, raw) in result {
            guard let bundleID = key as? String, !bundleID.isEmpty,
                  let info = raw as? NSDictionary else { continue }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleID
            out.append(Item(
                id: bundleID,
                name: name,
                bundleID: bundleID,
                version: (info["CFBundleShortVersionString"] as? String) ?? "—",
                kind: kind(for: info["ApplicationType"] as? String ?? ""),
                staticBytes: (info["StaticDiskUsage"] as? NSNumber)?.int64Value ?? 0,
                dynamicBytes: (info["DynamicDiskUsage"] as? NSNumber)?.int64Value ?? 0
            ))
        }
        return (out, "\(out.count) apps")
    }

    nonisolated private static func kind(for type: String) -> Item.Kind {
        switch type.lowercased() {
        case "user": return .user
        case "system": return .system
        default: return .unknown
        }
    }

    nonisolated private static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    nonisolated private static func number(_ object: NSObject, _ key: String) -> Int64? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.int64Value
    }

    /// Direct symbol access to `MobileInstallationLookup` from the private
    /// MobileInstallation framework, resolved lazily.
    private enum MobileInstall {
        typealias LookupFn = @convention(c) (CFDictionary?) -> CFDictionary?

        static let lookup: LookupFn? = {
            let framework = "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"
            let handle = dlopen(framework, RTLD_NOW)
            guard let symbol = dlsym(handle, "MobileInstallationLookup") else { return nil }
            return unsafeBitCast(symbol, to: LookupFn.self)
        }()
    }
}