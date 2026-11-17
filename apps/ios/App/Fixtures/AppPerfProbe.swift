#if DEBUG
import Darwin
import UIKit

/// `-perfProbe [-perfOpenProject]` (DEBUG builds only) — the companion app's
/// speed on a device, with the signed-in user's REAL library (timings only:
/// no names, ids or content are recorded). `apps/ios/scripts/ios-device-app-perf.sh`.
///
///   launch     process start → scene connected → library listed (items on
///              screen) → thumbnails settled (no change for 2 s)
///   thumbs     ThumbnailStore: disk-cache hits vs network loads and their
///              mean / max time
///   scroll     the library scrolled top → bottom → top on a display link
///              (hitches = a frame interval > 1.5 × the display's)
///   open       with -perfOpenProject: the newest cloud project through the
///              shipping `StudioEditorEntry.open` → editor → first video frame
///
/// Lines go to Documents/perf-app/result.txt (`APPPERF …`).
@MainActor
enum AppPerfProbe {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-perfProbe")
    private static var file: URL?

    static func log(_ line: String) {
        print(line)
        guard let file, let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: file) }
    }

    /// Seconds since this process started (kernel start time).
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - start
    }

    static func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

    static func start(in window: UIWindow) {
        guard isActive else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("perf-app", isDirectory: true)
        try? FileManager.default.removeItem(at: docs)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        file = docs.appendingPathComponent("result.txt")
        UIApplication.shared.isIdleTimerDisabled = true
        log("APPPERF launch → scene connected \(ms(sinceProcessStart()))")
        Task { @MainActor in
            await run(window: window)
            log("APPPERF-PROBE DONE")
        }
    }

    static func collectionView(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView, cv.bounds.height > 200 { return cv }
        for sub in view.subviews { if let found = collectionView(in: sub) { return found } }
        return nil
    }

    static func itemCount(_ cv: UICollectionView) -> Int {
        (0..<cv.numberOfSections).reduce(0) { $0 + cv.numberOfItems(inSection: $1) }
    }

    static func run(window: UIWindow) async {
        // ── library listed ──
        var cv: UICollectionView?
        let listDeadline = Date().addingTimeInterval(30)
        while Date() < listDeadline {
            if let found = collectionView(in: window), itemCount(found) > 0 { cv = found; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let cv else { log("APPPERF FAIL library never listed (signed out?)"); return }
        log("APPPERF launch → library listed \(ms(sinceProcessStart())) · \(itemCount(cv)) items · \(LibraryStore.shared.projects.count) projects")

        // ── thumbnails settle ──
        let thumbs = ThumbnailStore.shared
        var lastCount = -1, stableSince = Date()
        let thumbDeadline = Date().addingTimeInterval(60)
        while Date() < thumbDeadline {
            let n = thumbs.images.count
            if n != lastCount { lastCount = n; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) > 2, thumbs.probeIdle { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let settled = sinceProcessStart() - Date().timeIntervalSince(stableSince)
        log("APPPERF launch → thumbnails settled \(ms(settled)) · \(thumbs.images.count) shown, \(thumbs.failed.count) failed")
        logThumbStats("launch")

        // ── scroll ──
        await scroll(cv, label: "scroll down", to: max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom))
        await scroll(cv, label: "scroll up", to: -cv.adjustedContentInset.top)
        try? await Task.sleep(for: .seconds(2))
        log("APPPERF after scrolling · \(thumbs.images.count) thumbnails shown, \(thumbs.failed.count) failed")
        logThumbStats("after scroll")

        // ── open the newest project in the studio ──
        guard ProcessInfo.processInfo.arguments.contains("-perfOpenProject") else { return }
        guard #available(iOS 26, *) else { log("APPPERF open skipped (studio needs iOS 26)"); return }
        guard let project = LibraryStore.shared.projects.max(by: { $0.updatedAt < $1.updatedAt }),
              let presenter = window.rootViewController else { log("APPPERF open skipped (no project)"); return }
        let t0 = CACurrentMediaTime()
        StudioEditorEntry.open(projectID: project.projectId, from: presenter)
        var editor: EditorViewController?
        let openDeadline = Date().addingTimeInterval(180)
        while Date() < openDeadline {
            var top = presenter
            while let next = top.presentedViewController { top = next }
            if let e = top as? EditorViewController { editor = e; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let editor else { log("APPPERF FAIL editor never opened"); return }
        let tPresented = CACurrentMediaTime() - t0
        while Date() < openDeadline, !(editor.playback.isReady && editor.stage.core.displayedVideoFrame != nil) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let mb = Double(project.totalBytes) / 1_048_576
        log(String(format: "APPPERF open newest project (%.0f MB) → editor %@ → first video frame %@",
                   mb, ms(tPresented), ms(CACurrentMediaTime() - t0)))
        try? await Task.sleep(for: .seconds(1))
        editor.dismiss(animated: false)
    }

    static func logThumbStats(_ label: String) {
        let s = ThumbnailStore.shared.probeStats
        log("APPPERF thumbs (\(label)) · disk hits \(s.diskHits) (mean \(ms(s.diskHits > 0 ? s.diskTime / Double(s.diskHits) : 0))) · network loads \(s.loads) (mean \(ms(s.loads > 0 ? s.loadTime / Double(s.loads) : 0)), max \(ms(s.loadMax)))")
    }

    final class Pacer: NSObject {
        var intervals: [CFTimeInterval] = []
        var expected: CFTimeInterval = 1.0 / 60
        private var last: CFTimeInterval = 0
        var onTick: ((CADisplayLink) -> Void)?
        @objc func tick(_ l: CADisplayLink) {
            expected = l.targetTimestamp - l.timestamp
            if last > 0 { intervals.append(l.timestamp - last) }
            last = l.timestamp
            onTick?(l)
        }
    }

    /// Scrolls at a steady 4,000 pt/s (a brisk flick) on a display link.
    static func scroll(_ cv: UICollectionView, label: String, to target: CGFloat) async {
        let from = cv.contentOffset.y
        let distance = target - from
        guard abs(distance) > 1 else { log("APPPERF \(label) skipped (nothing to scroll)"); return }
        let duration = max(0.5, abs(distance) / 4000)
        let pacer = Pacer()
        let link = CADisplayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        var start: CFTimeInterval = 0
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            pacer.onTick = { l in
                if start == 0 { start = l.timestamp }
                let p = min(1, (l.targetTimestamp - start) / duration)
                cv.contentOffset.y = from + distance * p
                if p >= 1, !done { done = true; l.invalidate(); c.resume() }
            }
            link.add(to: .main, forMode: .common)
        }
        let hitches = pacer.intervals.filter { $0 > pacer.expected * 1.5 }.count
        let worst = pacer.intervals.max() ?? 0
        log(String(format: "APPPERF %@ %.0f pt in %.2f s · %.0f Hz · %d frames, %d hitches (worst %@)",
                   label, abs(distance), duration, 1 / pacer.expected, pacer.intervals.count, hitches, ms(worst)))
    }
}
#endif
