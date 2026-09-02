import AppKit

/// Editor window under the AppKit shell. The content is the existing SwiftUI
/// editor hosted unchanged — sceneBridgingOptions lets the hosted view keep
/// driving the window toolbar and title (EditorView owns both, including the
/// inspector, exactly as it did under the SwiftUI Window scene).
@MainActor
final class EditorWindowController: NSWindowController {
    private var exportSheetObservation: SurfaceObservation?
    private var presentedExportSheet: ExportSheetController?

    convenience init(appState: AppState) {
        // AppKit P6: the shell itself (top bar, stage, inspector split,
        // timeline container) is a native view-controller tree.
        let content: NSViewController = EditorWindowContentViewController(appState: appState)
        let hosting = content
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("editor")
        window.title = "Editor"
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        // The in-content top bar (EditorToolbarController) draws its own
        // title label — with the system title left visible the two rendered
        // on top of each other ("Untitled Recording" twice, overlapping).
        // window.title stays set for Mission Control / the Window menu.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Normal-Mac-window contract: resizable (default styleMask), a sane
        // floor, and title-bar double-click honoring the system pref. The
        // fullSizeContentView chrome puts app views under the (transparent)
        // title-bar region, so the browser/editor top chrome forwards
        // double-clicks via TitlebarDoubleClick.
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        // Restores the user's saved frame when one exists (overrides the
        // default size above).
        window.setFrameAutosaveName("capturecat.editor")
        // SwiftUI scene windows hand initial focus to the content view;
        // NSWindow(contentViewController:) leaves it nil, which starves the
        // editor's .focusable()/.onKeyPress chain — space-to-play and all
        // timeline hotkeys go dead without this.
        window.initialFirstResponder =
            (content as? EditorWindowContentViewController)?.focusTarget ?? hosting.view
        self.init(window: window)

        // Phase 3b: the export sheet is a native AppKit sheet. Present /
        // dismiss tracks appState.showExport so every existing trigger
        // (Export… button, deep links) keeps working unchanged.
        exportSheetObservation = SurfaceObservation { [weak self, weak appState] in
            guard let self, let appState else { return }
            let wantsSheet = appState.showExport && appState.currentProject != nil
            self.syncExportSheet(wantsSheet: wantsSheet, appState: appState)
        }
    }

    private func syncExportSheet(wantsSheet: Bool, appState: AppState) {
        guard let hosting = window?.contentViewController else { return }
        if wantsSheet, presentedExportSheet == nil, let project = appState.currentProject {
            let sheet = ExportSheetController(appState: appState, project: project)
            sheet.onDismiss = { [weak appState] in
                appState?.showExport = false
            }
            presentedExportSheet = sheet
            if let window { sheet.present(over: window) }
        } else if !wantsSheet, let sheet = presentedExportSheet {
            presentedExportSheet = nil
            sheet.dismissDialog()
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Re-assert focus every show — reopening the window must bring the
        // keyboard shortcuts back too, not just the pixels. Under the native
        // shell the keyboard surface is the hosted timeline (its `.focusable()`
        // / `.onKeyPress` chain), not the plain container view.
        guard let window else { return }
        let content = (window.contentViewController as? EditorWindowContentViewController)?.focusTarget
            ?? window.contentViewController?.view
        if let content {
            window.makeFirstResponder(content)
        }
    }
}
