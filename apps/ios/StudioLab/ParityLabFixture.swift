import ImageIO
import UIKit

/// The Mac-dumped preview-parity fixture (ParityFixtureFile), decoded for the
/// iOS run. Images come from the Mac's own PNGs at the Mac's point sizes
/// (frame 1:1, poster 2x), so every input is the Mac's.
@MainActor
struct ParityLabFixture {
    let project: Project
    let currentTime: TimeInterval
    let cursorEvents: [CursorEvent]
    let coordinateSize: CGSize
    let videoSize: CGSize
    let cameraAspect: CGFloat
    let canvas: CGSize
    let videoPoster: UIImage
    let cameraPoster: UIImage

    static func load(from dir: URL) throws -> ParityLabFixture {
        let data = try Data(contentsOf: dir.appendingPathComponent(ParityFixtureFile.fileName))
        let file = try JSONDecoder().decode(ParityFixtureFile.self, from: data)
        let project = try JSONDecoder().decode(Project.self, from: file.project)
        // The watermark resolves next to videoURL (Project.watermarkImageURL).
        project.videoURL = dir.appendingPathComponent("video.mov")
        return ParityLabFixture(
            project: project,
            currentTime: file.currentTime,
            cursorEvents: file.cursorEvents,
            coordinateSize: file.coordinateSize,
            videoSize: file.videoSize,
            cameraAspect: file.cameraAspect,
            canvas: file.canvas,
            videoPoster: UIImage(cgImage: try png(dir.appendingPathComponent(ParityFixtureFile.videoFrame)), scale: 1, orientation: .up),
            cameraPoster: UIImage(cgImage: try png(dir.appendingPathComponent(ParityFixtureFile.cameraPoster)), scale: 2, orientation: .up)
        )
    }

    func input() -> PreviewStageView.FrameInput {
        PreviewStageView.FrameInput(
            project: project,
            currentTime: currentTime,
            isPlaying: false,
            cursorEvents: cursorEvents,
            cursorCoordinateSize: coordinateSize,
            videoSize: videoSize,
            player: nil,
            cameraPlayer: nil,
            cameraPosterImage: project.settings.showCamera ? cameraPoster : nil,
            cameraVideoAspect: cameraAspect,
            videoPosterImage: videoPoster
        )
    }

    private static func png(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "ParityLabFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot decode \(url.lastPathComponent)"])
        }
        return image
    }
}
