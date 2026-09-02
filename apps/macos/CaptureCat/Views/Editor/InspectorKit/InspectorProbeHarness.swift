import AppKit

/// Debug probe for the AppKit inspector column.
///
///   CaptureCat --inspector-probe [annotate]
///
/// Builds the REAL hosting chain — `EditorInspectorViewController` inside a
/// split view, exactly how `EditorShellViewController` hosts it — rather than a
/// bare pre-sized window. A previous version of this probe used a standalone
/// window and masked an in-app layout collapse; the topology has to match.
///
/// Prints the resolved frames of the scroll view, document view, and every
/// pane, and saves a CARenderer capture beside the report. DEBUG tooling.
///
/// The old `pane-compare` mode rendered SwiftUI panes beside their AppKit twins
/// for the conversion parity check. It was removed with the SwiftUI panes —
/// there is nothing left to compare against.
@MainActor
enum InspectorProbeHarness {

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let project = Project(name: "probe")
        let selection = EditorShellSelection()

        // `--inspector-probe effects` — open the Effects tab (grouped effect
        // boxes render in their global, nothing-selected mode).
        if CommandLine.arguments.contains("effects") {
            selection.inspectorTab = .effects
        }

        // `--inspector-probe custom-placement` — seed a freeform card position
        // so the Background pane's Placement row must show "Custom", the
        // Reset button, and the card at the actual spot.
        if CommandLine.arguments.contains("custom-placement") {
            project.settings.videoCustomX = 0.82
            project.settings.videoCustomY = 0.25
        }

        // `--inspector-probe annotate` — seed a selected text annotation and
        // open the Annotate tab so the native pane's editor state renders.
        if CommandLine.arguments.contains("annotate") {
            var annotation = Annotation(type: .text, startTime: 0, endTime: 3)
            annotation.text = "Probe label"
            project.annotations = [annotation]
            selection.inspectorTab = .annotations
            selection.selectedAnnotationID = annotation.id
        }

        let inspector = EditorInspectorViewController(
            project: project,
            playback: EditorPlaybackController(appState: nil),
            selection: selection
        )

        // Stage stand-in + inspector in a split, mirroring the shell so the
        // column resolves its width against a real sibling.
        let stage = NSViewController()
        stage.view = NSView()
        stage.view.wantsLayer = true
        stage.view.layer?.backgroundColor = NSColor.black.cgColor

        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: stage))
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 340
        inspectorItem.maximumThickness = 480
        split.addSplitViewItem(inspectorItem)

        let window = NSWindow(contentViewController: split)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.orderFrontRegardless()

        // Two settles: constraint resolution then the observation re-arm.
        var reports = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated {
                reports += 1
                report(root: split.view)
                if reports >= 2 { exit(0) }
            }
        }
        app.run()
        exit(0)
    }

    private static func report(root: NSView) {
        guard let column = findView(ofType: InspectorColumnAppKit.self, in: root) else {
            print("PROBE no InspectorColumnAppKit in tree")
            return
        }
        print("PROBE column frame=\(column.frame)")
        if let scroll = findView(ofType: NSScrollView.self, in: column) {
            print("PROBE scroll frame=\(scroll.frame) contentSize=\(scroll.contentSize)")
            if let doc = scroll.documentView {
                print("PROBE documentView frame=\(doc.frame) tamic=\(doc.translatesAutoresizingMaskIntoConstraints)")
                for sub in doc.subviews {
                    print("PROBE pane \(type(of: sub)) frame=\(sub.frame) hidden=\(sub.isHidden)")
                }
            } else {
                print("PROBE documentView is nil")
            }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-inspector-probe.png")
        if let layer = root.layer,
           let img = CARendererSnapshot.render(layer: layer, size: root.bounds.size, scale: 1) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir)
            print("PROBE capture \(dir.path)")
        }
    }

    private static func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findView(ofType: type, in: sub) { return found }
        }
        return nil
    }
}
