import AppKit

/// One-click MCP setup for every major agent client.
///
/// The app is SANDBOXED, so it cannot silently edit other apps' config files
/// (~/.claude.json, Claude Desktop's JSON, ~/.cursor/…) — and should not want
/// to. Each client gets the best mechanism its platform actually offers:
///
///   Cursor          cursor:// install deep link            — true one click
///   Claude Desktop  generated .mcpb bundle, opened for it  — true one click
///   Claude Code     `claude mcp add …` command             — copy to clipboard
///   Codex CLI       `codex mcp add …` command              — copy to clipboard
///   Windsurf / VS Code / anything else — standard JSON     — copy to clipboard
///
/// Every payload resolves the RUNNING app's binary via Bundle.main, so the
/// path is always correct wherever the app lives — nobody types it by hand.
enum AgentSetup {

    static var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat"
    }

    // MARK: - Copyable payloads

    static var claudeCodeCommand: String {
        "claude mcp add capturecat -- \"\(binaryPath)\" --mcp"
    }

    static var codexCommand: String {
        "codex mcp add capturecat -- \"\(binaryPath)\" --mcp"
    }

    /// The standard `mcpServers` JSON block — Windsurf, Claude Desktop manual
    /// setup, and most other clients accept exactly this shape.
    static var standardJSON: String {
        """
        {
          "mcpServers": {
            "capturecat": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    // MARK: - Cursor deep link

    /// cursor://anysphere.cursor-deeplink/mcp/install?name=…&config=base64(JSON)
    static var cursorDeepLink: URL? {
        let config = ["command": binaryPath, "args": ["--mcp"]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        var components = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")
        components?.queryItems = [
            URLQueryItem(name: "name", value: "capturecat"),
            URLQueryItem(name: "config", value: data.base64EncodedString()),
        ]
        return components?.url
    }

    // MARK: - VS Code deep link

    /// vscode:mcp/install?{url-encoded JSON} — VS Code 1.99+ opens its own
    /// install confirmation for the server.
    static var vsCodeDeepLink: URL? {
        let config: [String: Any] = [
            "name": "capturecat",
            "command": binaryPath,
            "args": ["--mcp"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8),
              let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "vscode:mcp/install?\(encoded)")
    }

    static var vsCodeInstalled: Bool {
        isInstalled(bundleID: "com.microsoft.VSCode")
    }

    // MARK: - Terminal one-click (Claude Code / Codex)

    /// Runs a setup command in Terminal via Apple Events — the one-click path
    /// for CLI-configured clients. The sandbox cannot write ~/.claude.json or
    /// ~/.codex/config.toml itself, and a child process would inherit our
    /// sandbox and fail identically — Terminal runs unsandboxed and the user
    /// SEES exactly what executed. Requires the apple-events entitlement and
    /// a one-time macOS consent prompt. Returns an error message on refusal.
    static func runInTerminal(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return nil
    }

    // MARK: - Claude Desktop (.mcpb bundle)

    /// Builds a .mcpb (MCP Bundle — zip with a manifest) into the container
    /// tmp and returns its URL. Opening it hands it to Claude Desktop's
    /// one-click installer. The bundled launcher prefers the path this app is
    /// running from and falls back to the standard install locations, so the
    /// bundle keeps working after the app moves.
    static func buildMCPB() throws -> URL {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-mcpb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let launcher = """
        #!/bin/sh
        # CaptureCat MCP launcher — finds the app and starts its MCP server.
        for BIN in \\
          "\(binaryPath)" \\
          "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat" \\
          "$HOME/Applications/CaptureCat.app/Contents/MacOS/CaptureCat"; do
          [ -x "$BIN" ] && exec "$BIN" --mcp
        done
        APP=$(mdfind 'kMDItemCFBundleIdentifier == "so.capturecat.CaptureCat"' 2>/dev/null | head -1)
        [ -n "$APP" ] && [ -x "$APP/Contents/MacOS/CaptureCat" ] && exec "$APP/Contents/MacOS/CaptureCat" --mcp
        echo "CaptureCat.app not found — install it from capturecat.so first" >&2
        exit 1
        """
        let launcherURL = staging.appendingPathComponent("capturecat-mcp.sh")
        try launcher.write(to: launcherURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

        // The cat, not a generic monogram: render the app's own icon into the
        // bundle so clients' extension lists show the real logo.
        if let icon = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") {
            let size = NSSize(width: 256, height: 256)
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: size))
            scaled.unlockFocus()
            if let tiff = scaled.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: staging.appendingPathComponent("icon.png"))
            }
        }

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let manifest: [String: Any] = [
            "manifest_version": "0.2",
            "name": "capturecat",
            "display_name": "CaptureCat",
            "icon": "icon.png",
            "version": version,
            "description": "Drive CaptureCat: record the screen, edit recordings (zooms, annotations, styles), see rendered frames, read transcripts, and export — the app's real engine, not a wrapper.",
            "author": ["name": "CaptureCat"],
            "server": [
                "type": "binary",
                "entry_point": "capturecat-mcp.sh",
                "mcp_config": [
                    "command": "${__dirname}/capturecat-mcp.sh",
                    "args": [],
                ],
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptureCat.mcpb")
        try? FileManager.default.removeItem(at: output)

        // A .mcpb IS a zip — ditto produces one without any extra tooling.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, output.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "AgentSetup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not package the MCP bundle."
            ])
        }
        return output
    }

    // MARK: - Client detection (LaunchServices — no file access needed)

    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var cursorInstalled: Bool {
        isInstalled(bundleID: "com.todesktop.230313mzl4w4u92")
    }

    static var claudeDesktopInstalled: Bool {
        isInstalled(bundleID: "com.anthropic.claudefordesktop")
    }
}
