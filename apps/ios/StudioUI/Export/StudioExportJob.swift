import Foundation
import Observation
import UIKit

/// One export from the iOS editor (Studio 3d): the SAME pipeline the Mac's
/// sheet runs — the project's `ExportSettings` set on the project, then
/// `VideoExporter.export` (movie or GIF, chosen by the file's extension) or
/// `StillImageExporter.exportPNG` (PNG still). Pipeline depth is
/// `ExportTuning`'s (3b), decided inside the exporter.
///
/// The file is written into its own folder under the app's temporary
/// directory and handed to `ExportDelivery` from there. Cancel (or the system
/// expiring the background export) stops the exporter and removes every
/// partial file; a failed export removes its folder too. `discard()` removes
/// a finished export once the sheet is done with it.
@available(iOS 26, *)
@MainActor
@Observable
final class StudioExportJob {
    enum State: Equatable {
        case running
        case finished(URL)
        case failed(String)
        case cancelled
    }

    let kind: ExportSheetSpec.OutputKind
    let settings: ExportSettings
    /// The file the export writes.
    let destination: URL
    private(set) var state: State = .running
    /// 0…1, the exporter's own progress.
    private(set) var progress: Double = 0
    /// The thrown error, when the export failed (`ExportError.insufficientMemory`, …).
    @ObservationIgnored private(set) var error: Error?

    let exporter = VideoExporter()
    let background = StudioExportBackground()
    private let project: Project
    @ObservationIgnored private var observation: SurfaceObservation?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    /// Where exports are written (one folder per export).
    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCat Exports", isDirectory: true)
    }

    #if DEBUG
    /// Probe seams — INJECTED DEFECTS for `--export-sheet --inject …`.
    enum ProbeDefect { case none, cancelLeavesFile }
    static var probeDefect = ProbeDefect.none
    /// Probe seam: fail with this error instead of exporting (the error path).
    static var probeForcedError: Error?
    #endif

    init(project: Project, kind: ExportSheetSpec.OutputKind, settings: ExportSettings) {
        self.project = project
        self.kind = kind
        self.settings = settings
        let folder = Self.exportsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ext = ExportSheetSpec.fileType(kind: kind, format: settings.format).ext
        destination = folder.appendingPathComponent("\(Self.safeName(project.name)).\(ext)")
    }

    /// A file name from the project's name (no path separators, never empty).
    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "CaptureCat Export" : String(cleaned.prefix(80))
    }

    func start() {
        guard work == nil else { return }
        // As on the Mac: the sheet's choices become the project's export settings.
        project.settings.exportSettings = settings
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        background.begin(title: ExportSheetSpec.title(for: kind), subtitle: project.name) { [weak self] in
            self?.cancel()
        }
        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let value = self.exporter.progress
            if value != self.progress { self.progress = value }
            self.background.report(value)
        }
        let project = self.project
        let exporter = self.exporter
        let kind = self.kind
        let destination = self.destination
        work = Task { @MainActor [weak self] in
            do {
                #if DEBUG
                if let error = Self.probeForcedError { throw error }
                #endif
                if kind == .image {
                    try await StillImageExporter.exportPNG(project: project, to: destination, exporter: exporter)
                } else {
                    try await exporter.export(project: project, to: destination)
                }
                self?.finish(nil)
            } catch {
                self?.finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        observation?.cancel()
        observation = nil
        if cancelRequested || error is CancellationError {
            #if DEBUG
            if Self.probeDefect == .cancelLeavesFile { return }
            #endif
            removeFolder()
            state = .cancelled
            background.end(success: false)
        } else if let error {
            self.error = error
            removeFolder()
            state = .failed(error.localizedDescription)
            background.end(success: false)
        } else {
            progress = 1
            state = .finished(destination)
            background.end(success: true)
        }
    }

    /// Stops the export; partial output is removed and `state` becomes `.cancelled`.
    func cancel() {
        guard state == .running, !cancelRequested else { return }
        cancelRequested = true
        #if DEBUG
        if Self.probeDefect == .cancelLeavesFile {
            // INJECTED DEFECT: the sheet stops waiting but the exporter runs
            // on, writing its file.
            observation?.cancel()
            state = .cancelled
            background.end(success: false)
            return
        }
        #endif
        exporter.cancel()
    }

    /// The finished export is no longer needed (the sheet closed).
    func discard() {
        if state == .running { cancel() } else { removeFolder() }
    }

    private func removeFolder() {
        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }
}
