import UIKit

/// The iOS run of the Mac's preview-parity matrix: the window, the stage
/// and the fixture the shared script (StudioHarness/PreviewParityHarness)
/// drives. The stage is the shipping `PreviewStageView`, sized to the Mac's
/// 720×405 pane at magnification 1 (iPad landscape), so a capture lands on
/// the Mac golden's pixel grid.
@MainActor
final class ParityLab {
    static var current: ParityLab?

    let container: FlippedContainer
    let compositor: PreviewCompositorView
    let fixtureDir: URL

    init(in host: UIView, fixtureDir: URL) {
        self.fixtureDir = fixtureDir
        let pane = PreviewParityHarness.paneSize
        container = FlippedContainer(frame: CGRect(origin: CGPoint(x: 24, y: 40), size: pane))
        compositor = PreviewCompositorView(frame: CGRect(origin: .zero, size: pane))
        container.addSubview(compositor)
        host.addSubview(container)
        ParityLab.current = self
    }

    /// A fresh copy of the Mac's `makeFixtureProject()` (no videoURL, like the
    /// Mac's mid-script projects).
    func freshFixtureProject() -> Project? {
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent(ParityFixtureFile.fileName)),
              let file = try? JSONDecoder().decode(ParityFixtureFile.self, from: data),
              let project = try? JSONDecoder().decode(Project.self, from: file.project) else { return nil }
        project.videoURL = nil
        return project
    }

    static func run(in host: UIView, fixtureDir: URL) async {
        print("LAB PARITY fixture=\(fixtureDir.path)")
        let lab = ParityLab(in: host, fixtureDir: fixtureDir)
        let code = await PreviewParityHarness.runInLab(lab)
        exit(code)
    }
}
