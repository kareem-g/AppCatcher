import SwiftUI

/// Byte and date rendering used across the app.
///
/// The hero readout needs the value and the unit as separate strings so the
/// unit can be set smaller than the number, which is what keeps a 4.2 GB
/// figure from dominating the screen.
enum ByteFormat {
    private static let units = ["bytes", "KB", "MB", "GB", "TB"]

    static func parts(_ raw: Int64) -> (value: String, unit: String) {
        let bytes = max(raw, 0)
        if bytes < 1024 { return (String(bytes), bytes == 1 ? "byte" : "bytes") }

        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let rendered = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return (rendered, units[index])
    }

    static func string(_ raw: Int64) -> String {
        let p = parts(raw)
        return p.value == "0" ? "0 \(p.unit)" : "\(p.value) \(p.unit)"
    }

    /// "4.2" for a gauge label that already prints its unit elsewhere.
    static func value(_ raw: Int64) -> String { parts(raw).value }
    static func unit(_ raw: Int64) -> String { parts(raw).unit }

    static func percent(_ used: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }
}

extension View {
    /// Section footers and helper text: small and secondary, like Settings.
    func footnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}

enum TimeFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "just now" under a minute; otherwise "5 min. ago". Never "in 0 sec.".
    static func ago(_ date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }
    static func exact(_ date: Date) -> String { clock.string(from: date) }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm %.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// Turns a bundle-id-ish file name into something a person can read.
enum NamePrettifier {
    static func clean(_ raw: String) -> String {
        var name = raw
        if let dot = name.lastIndex(of: ".") {
            let ext = name[name.index(after: dot)...].lowercased()
            // Strip short, machine-ish extensions; keep archive types.
            if ext.count <= 6 && ext != "catcher" {
                name = String(name[..<dot])
            }
        }
        name = name.replacingOccurrences(of: "-Caches", with: "")
        name = name.replacingOccurrences(of: ".WebKit", with: "")
        name = name.replacingOccurrences(of: "com.apple.", with: "")
        name = name.replacingOccurrences(of: "_", with: " ")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed.capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
