import Observation
import UIKit

/// Background removal (Studio 4e): the camera's person cutout. The job is
/// the Mac's — `CameraSegmentation` + `CameraSegmenter` (Studio/): Vision
/// person segmentation on every camera frame, the shared producer
/// conditioning, written as `camera-mask.ccmask` beside the camera file —
/// and the cutout is drawn by the shared compositor (preview) and exporter,
/// so preview and export agree with each other and with the Mac.
///
///     StudioBackgroundRemoval.present(from: editor, project: project, undoManager: undo)
///
/// The sheet picks the camera's Background (None / Cutout / Pop-out card —
/// the Mac Camera pane's chips, one undo step each) and shows the mask job's
/// progress. The editor's stage gets the fresh mask through
/// `cameraMask(for:)` (EditorViewController's frame input).
@MainActor
enum StudioBackgroundRemoval {
    /// The one mask job for the app (one project at a time, like the Mac's).
    static let segmentation: CameraSegmentation = {
        let job = CameraSegmentation()
        job.projectLookup = { id in attached.first { $0.project?.id == id }?.project }
        job.isHostBusy = { isHostBusy() }
        return job
    }()

    /// Projects the job may run for (weak: a closed project drops out).
    private struct Weak { weak var project: Project? }
    private static var attached: [Weak] = []

    /// Host seam: true while an export owns the device (the job holds).
    static var isHostBusy: () -> Bool = { false }

    static func attach(_ project: Project) {
        attached.removeAll { $0.project == nil }
        if !attached.contains(where: { $0.project === project }) { attached.append(Weak(project: project)) }
    }

    /// The fresh person mask for `project`, queuing the job when a look
    /// needs one — call per render, as the Mac editor does (idempotent and
    /// cheap). Reading it registers the job's `revision`, so an observing
    /// render loop redraws when a mask lands. Nil draws looks as the bubble.
    static func cameraMask(for project: Project) -> CameraMaskTrack? {
        _ = segmentation.revision
        guard project.usesCameraLook, project.cameraVideoURL != nil else { return nil }
        attach(project)
        segmentation.ensureMask(for: project)
        return segmentation.usableMask(for: project)
    }

    @discardableResult
    static func present(from presenter: UIViewController, project: Project,
                        undoManager: UndoManager?) -> StudioBackgroundRemovalController {
        let controller = StudioBackgroundRemovalController(project: project, undoManager: undoManager)
        controller.present(from: presenter)
        return controller
    }

    /// The Camera pane's Background choices.
    static let looks: [CameraBubbleLook?] = [nil] + CameraBubbleLook.allCases

    /// Sets the whole-video look as one undo step and starts the mask job
    /// when the look needs it.
    static func setLook(_ look: CameraBubbleLook?, on project: Project, undoManager: UndoManager?) {
        let previous = project.settings.cameraLook
        guard previous != look else { return }
        project.settings.cameraLook = look
        undoManager?.registerUndo(withTarget: project) { project in
            setLook(previous, on: project, undoManager: undoManager)
        }
        undoManager?.setActionName(look.map { "Background: \($0.displayName)" } ?? "Background: None")
        _ = cameraMask(for: project)
    }
}

@MainActor
final class StudioBackgroundRemovalController {
    let project: Project
    private weak var undoManager: UndoManager?
    let chips: CCChipGroup
    let status = StudioFeatureProgressRow()
    private(set) var alert: CCAlert?
    private var observation: SurfaceObservation?
    /// Every status the sheet showed, in order (probe).
    private(set) var statusLog: [CameraSegmentation.Status] = []

    init(project: Project, undoManager: UndoManager?) {
        self.project = project
        self.undoManager = undoManager
        let selected = StudioBackgroundRemoval.looks.firstIndex(of: project.settings.cameraLook) ?? 0
        chips = CCChipGroup(items: StudioBackgroundRemoval.looks.map { $0?.displayName ?? "None" },
                            selected: [selected])
        chips.accessibilityIdentifier = "studio.background.looks"
        status.accessibilityIdentifier = "studio.background.status"
        chips.onChange = { [weak self] selection in
            guard let self, let index = selection.min() else { return }
            self.choose(StudioBackgroundRemoval.looks[index])
        }
    }

    var hasCamera: Bool { project.cameraVideoURL != nil }

    func present(from presenter: UIViewController) {
        let alert: CCAlert
        if hasCamera {
            alert = StudioFeatureSheet.make(
                title: "Remove Background",
                message: "Finds you in the camera on this device and removes what's behind you. Cutout stands you over the recording; Pop-out card puts you on a card you break out of.",
                symbol: "person.crop.rectangle",
                content: [chips, status])
            alert.addButton("Done", role: .cancel)
        } else {
            alert = StudioFeatureSheet.make(
                title: "Remove Background",
                message: "This recording has no camera to remove the background from.",
                symbol: "person.crop.rectangle", content: [])
            alert.addButton("OK", role: .cancel)
        }
        self.alert = alert
        alert.present(from: presenter) { [weak self] _ in self?.observation = nil }
        observation = SurfaceObservation { [weak self] in self?.apply() }
    }

    func choose(_ look: CameraBubbleLook?) {
        StudioBackgroundRemoval.setLook(look, on: project, undoManager: undoManager)
        if let index = StudioBackgroundRemoval.looks.firstIndex(of: look), chips.selectedIndex != index {
            chips.setSelection([index])
        }
    }

    /// The job's state for this project — read inside the observation loop,
    /// so progress ticks (and a mask landing) re-apply. Queues the job the
    /// way the Mac editor's render does.
    private func apply() {
        let job = StudioBackgroundRemoval.segmentation
        _ = job.revision
        _ = project.settings.cameraLook
        _ = StudioBackgroundRemoval.cameraMask(for: project)
        let state = job.status(for: project)
        if statusLog.last != state { statusLog.append(state) }
        guard let text = state.displayText else {
            status.isHidden = true
            return
        }
        status.isHidden = false
        status.update(text: text, value: state.barValue, showsBar: state.showsBar)
    }
}
