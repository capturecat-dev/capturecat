import Foundation
#if os(iOS)
import os
#endif

/// What export tuning (`ExportTuning`, Studio 3b) needs to know about the
/// device it runs on.
enum PlatformExportResources {
    /// True on the Mac, which keeps its long-standing export pipeline depth.
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Memory this process can still allocate before the system terminates
    /// it (`os_proc_available_memory()`, iOS). nil on the Mac, which has no
    /// per-process limit of that kind.
    static func availableMemory() -> UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }
}
