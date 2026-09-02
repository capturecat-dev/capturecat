import Foundation
import Sparkle

/// Points Sparkle at the appcast for the architecture this copy is running as.
///
/// # Why this exists
///
/// Releases ship as two separate single-architecture DMGs (`CaptureCat-arm64.dmg`
/// and `CaptureCat-x86_64.dmg`), but a Sparkle appcast `<item>` carries ONE
/// `<enclosure>` and Sparkle has no architecture predicate to choose between
/// them. The release script used to publish a single `appcast.xml` whose only
/// enclosure was the **arm64** DMG — so every Intel Mac that auto-updated
/// downloaded an Apple-Silicon-only build and ended up with an app that would
/// not launch. Intel users could install manually and then be broken by the
/// first successful update check.
///
/// So the feed is selected per architecture instead, and the publisher writes
/// one appcast per DMG. `Info.plist`'s `SUFeedURL` stays as the fallback for
/// anything that asks before this delegate is consulted.
///
/// # Compile-time architecture is the right answer here
///
/// Releases are single-architecture, so `#if arch(...)` names exactly the slice
/// this binary IS — which is the slice its updates must keep matching. Probing
/// `sysctl.proc_translated` would additionally reveal that an x86_64 build is
/// running under Rosetta on Apple Silicon, but that does not change the answer:
/// it should stay on the x86_64 feed rather than silently switch architecture
/// during a background update.
enum UpdateFeed {
    static let base = "https://api.capturecat.so/api/releases"

    /// `arm64` or `x86_64` — the slice this process is executing as, which is
    /// the slice its updates must keep matching.
    ///
    /// Note an x86_64 build running under Rosetta on Apple Silicon deliberately
    /// stays on the x86_64 feed. Switching it to arm64 would be a faster app but
    /// also a silent architecture change during a background update; that should
    /// be an explicit choice, not a side effect of checking for updates.
    static var runningArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var feedURLString: String {
        "\(base)/appcast/\(runningArchitecture)"
    }
}

/// Beta-channel opt-in. Sparkle 2's official pre-release mechanism: appcast
/// items tagged `<sparkle:channel>beta</sparkle:channel>` are invisible to
/// everyone except updaters that declare the channel in `allowedChannels` —
/// one feed serves both audiences, and switching the toggle off simply makes
/// the next stable release the next update (no reinstall needed).
enum UpdateChannel {
    static let defaultsKey = "receiveBetaUpdates"
    static var receiveBeta: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Supplies the architecture-specific feed. Kept tiny and separate from
/// `CaptureCatAppDelegate` so the URL logic is testable without an app launch.
final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeed.feedURLString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.receiveBeta ? ["beta"] : []
    }
}
