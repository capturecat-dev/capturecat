import Foundation

/// Out-of-band project.json writes — the path the GUI treats as an EXTERNAL
/// edit. Same contract as `CaptureCat --mcp`'s writer (MCPServer `writeData`):
///
///  1. the previous contents are copied to `project.json.bak`;
///  2. the new bytes go to a temp file beside it;
///  3. `replaceItemAt` swaps it in atomically — a reader (the GUI's
///     ProjectStore poll, the exporter, another MCP call) sees the old file
///     or the new one, never a torn write.
///
/// The GUI's ProjectStore polls project.json's mtime (1 s) and reloads a
/// project whose on-disk copy changed under a CLEAN in-memory copy, firing
/// `onExternalProjectChange` so an open editor swaps to the fresh project.
/// Cloud "Pull Web Edits" writes through here for exactly that reason: it is
/// the reload path MCP edits already take, so a pulled revision shows up in
/// the browser and in an open editor with no new plumbing.
///
/// MCPServer's `writeData` routes through here too — one contract.
nonisolated enum ProjectFileIO {
    static func writeProjectData(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let bak = file.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: file, to: bak)
        let tmp = file.deletingLastPathComponent()
            .appendingPathComponent(".project.json.tmp-\(getpid())")
        try data.write(to: tmp)
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file)
        }
    }
}
