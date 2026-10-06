import Darwin
import Foundation
import WebKit

/// Measures what tabs cost and hands freed memory back to macOS.
@MainActor
enum MemoryManager {
    /// Physical footprint (what Activity Monitor calls "Memory") of a process we own, in bytes.
    nonisolated static func footprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    /// Searchy's own footprint.
    static var appFootprint: UInt64 { footprint(pid: getpid()) ?? 0 }

    /// The web process currently rendering `view`, if WebKit tells us.
    static func webProcessID(of view: WKWebView) -> pid_t? {
        let sel = NSSelectorFromString("_webProcessIdentifier")
        guard view.responds(to: sel), let n = view.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        let pid = n.int32Value
        return pid > 0 ? pid : nil
    }

    static func footprint(of view: WKWebView?) -> UInt64? {
        guard let view, let pid = webProcessID(of: view) else { return nil }
        return footprint(pid: pid)
    }

    /// Asks the allocator to return freed-but-retained pages to the system.
    static func relieve() { _ = malloc_zone_pressure_relief(nil, 0) }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// How much web-process memory background tabs may hold before the oldest are put to sleep.
    static var budgetBytes: UInt64 {
        let mb = Preferences.shared.memoryBudgetMB
        if mb > 0 { return UInt64(mb) * 1_048_576 }
        let automatic = physicalMemory / 8                       // 12.5% of RAM…
        return min(max(automatic, 1 << 30), 3 << 30)             // …between 1 and 3 GB
    }

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
