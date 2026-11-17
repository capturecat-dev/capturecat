import UIKit

/// A CaptureCat share link, in either of the two forms that open the in-app
/// viewer:
///
///   https://capturecat.so/share/<id>[?t=<seconds>]      (universal link; www too)
///   capturecat://share/<id>[?t=<seconds>]               (the app's own scheme)
///   capturecat://share?id=<id>[&t=<seconds>]
///
/// The id rule is the web's (apps/web/src/lib/share-meta.ts: `[A-Za-z0-9_-]{4,64}`).
/// `/share/<id>.md` is the share page's Markdown twin, never a viewer link —
/// and `apps/web/public/.well-known/apple-app-site-association` excludes it too.
struct ShareLink: Equatable {
    var videoID: String
    /// `?t=` — where playback starts (the web's share page honours the same).
    var startAt: Double?

    /// The hosts whose `/share/` paths are claimed (the AASA's `applinks`).
    static let webHosts: Set<String> = ["capturecat.so", "www.capturecat.so"]

    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{4,64}$", options: .regularExpression) != nil
    }

    /// nil = not a share link (a universal link for any other path opens in
    /// the browser; a custom-scheme URL for another route belongs elsewhere).
    static func parse(_ url: URL) -> ShareLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let t = items.first(where: { $0.name == "t" })?.value.flatMap(Double.init).map { max(0, $0) }
        switch components.scheme?.lowercased() {
        case "https":
            guard let host = components.host?.lowercased(), webHosts.contains(host) else { return nil }
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "share" else { return nil }
            let id = String(parts[1])
            guard isValidID(id) else { return nil }
            return ShareLink(videoID: id, startAt: t)
        case CaptureCatAPI.callbackScheme:
            guard components.host?.lowercased() == "share" else { return nil }
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            let id = parts.first.map(String.init) ?? items.first(where: { $0.name == "id" })?.value ?? ""
            guard parts.count <= 1, isValidID(id) else { return nil }
            return ShareLink(videoID: id, startAt: t)
        default:
            return nil
        }
    }

    /// The canonical web URL (copy link, open in browser).
    var webURL: URL { URL(string: "\(CaptureCatAPI.shareOrigin)/share/\(videoID)")! }
}

/// Where share links land: the viewer, presented full screen over whatever is
/// up (the library, the editor, the sign-in screen — a viewer needs no
/// account). A second link replaces the open viewer; the same link again just
/// seeks to its `?t=`.
@MainActor
enum ShareLinkRouter {
    enum Source: String {
        case universalLink = "universal-link"
        case customScheme = "custom-scheme"
    }

    /// Open `link` in `window`. `cold` = arrived with the scene's connection
    /// options (the app was launched by the link).
    static func open(_ link: ShareLink, in window: UIWindow?, source: Source, cold: Bool) {
        #if DEBUG
        probeRecord("\(source.rawValue) \(cold ? "cold" : "warm") \(link.videoID)\(link.startAt.map { " t=\($0)" } ?? "")")
        #endif
        guard let window, let root = window.rootViewController else { return }
        var top: UIViewController = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if let viewer = top as? ShareViewerViewController {
            if viewer.videoID == link.videoID {
                if let t = link.startAt { viewer.seek(to: t, play: true) }
                return
            }
            let presenter = viewer.presentingViewController ?? root
            viewer.dismiss(animated: false) {
                present(link, from: presenter)
            }
            return
        }
        present(link, from: top)
    }

    private static func present(_ link: ShareLink, from presenter: UIViewController) {
        let viewer = ShareViewerViewController(link: link)
        viewer.modalPresentationStyle = .fullScreen
        presenter.present(viewer, animated: !CCMotion.reduceMotion) {
            UIAccessibility.post(notification: .screenChanged, argument: viewer.view)
        }
    }

    /// A universal link the app was handed that is NOT a share (the AASA only
    /// claims share paths, so this is defensive): the browser.
    static func openInBrowser(_ url: URL) {
        #if DEBUG
        probeRecord("browser \(url.absoluteString)")
        if let probe = probeBrowser { probe(url); return }
        #endif
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// Every routed link, in order — read by scripts/ios-share-viewer.sh from
    /// the app container (Documents/share-viewer/routes.log), so a COLD launch
    /// by `simctl openurl` is observable with no harness inside the process.
    static var probeRoutes: [String] = []
    /// The gate catches "open in the browser" instead of leaving the app.
    static var probeBrowser: ((URL) -> Void)?

    static var probeLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("share-viewer", isDirectory: true).appendingPathComponent("routes.log")
    }

    private static func probeRecord(_ line: String) {
        probeRoutes.append(line)
        let url = probeLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
    #endif
}
