import AppKit

/// macOS Services-menu provider: "Capture Text in CaptureCat". Registered as
/// `NSApp.servicesProvider` by the app delegate; the matching NSServices
/// entry lives in Info.plist (NSMessage `captureTextService`, so the system
/// invokes `captureTextService(_:userData:error:)` with the selected text on
/// the pasteboard). Also backs the in-app "New Note from Clipboard" fallback.
@MainActor
final class TextCaptureService: NSObject {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Selector name must be NSMessage + ":userData:error:".
    @objc func captureTextService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        // At service-invocation time the source app is still frontmost — our
        // app is not activated for a Services call.
        let sourceApp = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0.localizedName }
        capture(text: text, sourceAppName: sourceApp, open: false)
    }

    /// Fallback path: File → New Note from Clipboard.
    func newNoteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        capture(text: text, sourceAppName: nil, open: true)
    }

    @discardableResult
    private func capture(text: String, sourceAppName: String?, open: Bool) -> Note? {
        guard let appState else { return nil }
        let note = Note(text: text, sourceAppName: sourceAppName)
        appState.noteStore.save(note)
        if open {
            NoteViewerWindowController.present(note: note, appState: appState)
        }
        return note
    }
}
