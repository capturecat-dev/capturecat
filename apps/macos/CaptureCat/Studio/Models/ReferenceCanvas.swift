import CoreGraphics
import Foundation

/// The reference canvas (Studio 2e; docs/ios-studio-plan.md, decision 3).
///
/// Every point-sized setting — padding, corners, shadow, cursor, text,
/// camera — is authored in canvas points, and the exporter scales them by
/// `outputSize / canvas`. Before 2e the canvas was whatever the editor
/// window happened to show (`Project.previewCanvasSize`, not persisted), so
/// one project exported four different ways on the Mac and headless/MCP
/// exports differently again (Phase 0 §3.4). A project now carries a
/// persisted reference BOX, and every renderer — the Mac editor at any
/// window size, the iOS stage, headless/MCP and the Mac exporter — lays it
/// out on the same canvas: the largest one of the output's aspect that fits
/// in the box. The editors draw that canvas and MAGNIFY it to their stage,
/// the Mac's own "preview zoom is pure magnification" rule.
///
/// This type is the single source of that canvas: the editor hosts and the
/// exporter call it, never their own copy of the math.
enum ReferenceCanvas {
    /// The box new projects get: the Mac's default editor card (a 1100×700
    /// window resolves to an 803×330 pt card — Phase 0 §3.4). At 16:9 its
    /// canvas is 586.7×330, the canvas most existing exports already used;
    /// at every other aspect it is the canvas the default window shows.
    static let newProjectBox = CGSize(width: 803, height: 330)

    /// The canvas for an output of `aspect` (width / height): the largest
    /// canvas of that aspect inside `box` — the editor's own letterbox.
    static func canvas(box: CGSize, aspect: CGFloat) -> CGSize {
        AspectRatio.letterboxRect(in: CGRect(origin: .zero, size: box), aspect: aspect).size
    }

    /// `box` when it can lay a project out (finite and positive), else nil —
    /// a hand-edited project.json then falls back to the pre-2e behaviour
    /// instead of dividing by zero.
    static func sanitized(_ box: CGSize?) -> CGSize? {
        guard let box, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        return box
    }

    /// The width / height aspect a project's canvas takes: the exported
    /// file's (`ExportSettings.resolvedOutputSize`, so `.auto` follows the
    /// source and a custom size keeps its own shape). The Mac editor
    /// letterboxes its stage to the same value.
    static func outputAspect(settings: ProjectSettings, sourceSize: CGSize) -> CGFloat? {
        let output = settings.exportSettings.resolvedOutputSize(
            for: settings.aspectRatio, sourceSize: sourceSize)
        guard output.width > 0, output.height > 0 else { return nil }
        return output.width / output.height
    }

    /// Harness-only defect injection (`--reference-canvas-test`): renderers
    /// ignore the reference, i.e. the pre-2e behaviour for every project.
    static var debugIgnoreReference = false
}

extension Project {
    /// The canvas this project lays out on for an output of `aspect`, or nil
    /// for a project from before 2e (no reference: the live editor canvas
    /// decides, as it always did).
    func referenceCanvas(aspect: CGFloat) -> CGSize? {
        guard !ReferenceCanvas.debugIgnoreReference, aspect > 0, aspect.isFinite,
              let box = ReferenceCanvas.sanitized(referenceCanvasSize) else { return nil }
        return ReferenceCanvas.canvas(box: box, aspect: aspect)
    }

    /// The canvas the exporter scales point-sized settings against for a
    /// file of `outputSize`: the reference canvas. A pre-2e project keeps the
    /// exact old rule — the live editor canvas, or for a headless export
    /// (no editor ever set one) the output itself, i.e. scale 1.
    func exportReferenceCanvas(outputSize: CGSize) -> CGSize {
        if outputSize.height > 0,
           let canvas = referenceCanvas(aspect: outputSize.width / outputSize.height) {
            return canvas
        }
        let previewSize = previewCanvasSize
        guard previewSize.width > 0, previewSize.height > 0 else { return outputSize }
        return previewSize
    }

    /// Stamps a brand-new project with the reference box. Called where a
    /// recording or capture BECOMES a project — never on decode, so every
    /// project saved before 2e keeps rendering exactly as it did.
    func adoptNewProjectReferenceCanvas() {
        referenceCanvasSize = ReferenceCanvas.newProjectBox
    }
}
