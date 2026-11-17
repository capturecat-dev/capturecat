import UIKit

/// Auto Zoom (Studio 4e): zoom blocks generated from the cursor, clicks and
/// keystrokes the Mac recorded. The command is the Mac's own —
/// `AutoZoomApplier.applyAsEdit` (Studio/): the same generator, the same
/// screen-size and smoothing derivation, earlier AUTO blocks replaced while
/// the user's own blocks stay, and one undo step ("Auto Zoom").
///
///     StudioAutoZoom.present(from: editor, project: project, undoManager: undo)
///
/// Inert for takes without Mac capture data (iPhone-recorded and web takes
/// have no cursor.json — docs/ios-studio-plan.md, "Features that need Mac
/// capture data"): the sheet explains instead of offering Generate.
@MainActor
enum StudioAutoZoom {
    enum Availability: Equatable {
        case available
        /// No recorded cursor (an iPhone or web take).
        case needsMacCapture
    }

    static func availability(for project: Project) -> Availability {
        guard project.recordingSourceKind != .device,
              let cursor = project.cursorDataURL,
              FileManager.default.fileExists(atPath: cursor.path) else { return .needsMacCapture }
        return .available
    }

    @discardableResult
    static func present(
        from presenter: UIViewController,
        project: Project,
        undoManager: UndoManager?,
        onApplied: ((Int) -> Void)? = nil
    ) -> StudioAutoZoomController {
        let controller = StudioAutoZoomController(project: project, undoManager: undoManager)
        controller.onApplied = onApplied
        controller.present(from: presenter)
        return controller
    }
}

@MainActor
final class StudioAutoZoomController {
    let project: Project
    private weak var undoManager: UndoManager?
    var onApplied: ((Int) -> Void)?
    let availability: StudioAutoZoom.Availability
    /// The Mac Motion pane's "Zoom Level" (1.5–4×, 0.1 steps): the depth new
    /// auto blocks are made at (`settings.autoZoomLevel`).
    let levelSlider: CCSlider
    private(set) var alert: CCAlert?
    /// Blocks made by the last Generate (probe).
    private(set) var lastCreated = 0

    init(project: Project, undoManager: UndoManager?) {
        self.project = project
        self.undoManager = undoManager
        availability = StudioAutoZoom.availability(for: project)
        levelSlider = CCSlider(title: "Zoom Level", value: project.settings.autoZoomLevel, range: 1.5...4.0, step: 0.1,
                               format: { String(format: "%.1fx", $0) })
        levelSlider.accessibilityIdentifier = "studio.autozoom.level"
        levelSlider.onChange = { [weak self] value in self?.project.settings.autoZoomLevel = value }
    }

    func present(from presenter: UIViewController) {
        let alert: CCAlert
        switch availability {
        case .available:
            alert = StudioFeatureSheet.make(
                title: "Auto Zoom",
                message: "Zooms into your clicks, typing and pauses from the cursor the Mac recorded. Earlier auto zooms are replaced; zoom blocks you placed yourself stay.",
                symbol: "sparkles",
                content: [levelSlider])
            alert.addButton("Generate", role: .primary) { [weak self] in try self?.generate() }
            alert.addButton("Cancel", role: .cancel)
        case .needsMacCapture:
            alert = StudioFeatureSheet.make(
                title: "Auto Zoom",
                message: "Auto Zoom follows the cursor and clicks a Mac recording carries. This take has none — add zoom blocks on the timeline and aim them on the canvas instead.",
                symbol: "sparkles",
                content: [])
            alert.addButton("OK", role: .cancel)
        }
        self.alert = alert
        alert.present(from: presenter)
    }

    /// Generate — the shared command. Throws (shown inline) when nothing was
    /// worth zooming into; the project is untouched then.
    func generate() throws {
        guard availability == .available else { return }
        let created = AutoZoomApplier.applyAsEdit(to: project, undoManager: undoManager)
        lastCreated = created
        guard created > 0 else { throw StudioAutoZoomError.nothingToZoom }
        CCHaptics.success()
        onApplied?(created)
        CCAccessibility.announce("Auto Zoom added \(created) \(created == 1 ? "zoom" : "zooms")")
    }
}

enum StudioAutoZoomError: LocalizedError {
    case nothingToZoom
    var errorDescription: String? {
        "No clicks, typing or pauses worth zooming into were found."
    }
}
