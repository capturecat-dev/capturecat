import ImageIO
import UIKit

/// The Mac-dumped preview-parity fixture (ParityFixtureFile), loaded for iOS.
/// Images are decoded from the Mac's own PNGs — the iOS run's inputs are the
/// Mac's inputs, so only the compositor can move a pixel.
@MainActor
final class LabFixture {
    let project: Project
    var currentTime: TimeInterval
    var cursorEvents: [CursorEvent]
    let coordinateSize: CGSize
    let videoSize: CGSize
    let cameraAspect: CGFloat
    let canvas: CGSize
    let videoPoster: UIImage
    let cameraPoster: UIImage
    var isPlaying = false
    var cameraMask: CameraMaskTrack?

    private init(file: ParityFixtureFile, dir: URL) throws {
        project = try JSONDecoder().decode(Project.self, from: file.project)
        // The watermark resolves next to videoURL (Project.watermarkImageURL).
        project.videoURL = dir.appendingPathComponent("video.mov")
        currentTime = file.currentTime
        cursorEvents = file.cursorEvents
        coordinateSize = file.coordinateSize
        videoSize = file.videoSize
        cameraAspect = file.cameraAspect
        canvas = file.canvas
        // Same point sizes as the Mac's NSImages: the frame is 1:1 pixels,
        // the poster 2x (gradientPoster draws at scale 2).
        videoPoster = UIImage(cgImage: try Self.png(dir.appendingPathComponent(ParityFixtureFile.videoFrame)), scale: 1, orientation: .up)
        cameraPoster = UIImage(cgImage: try Self.png(dir.appendingPathComponent(ParityFixtureFile.cameraPoster)), scale: 2, orientation: .up)
    }

    static func load(from dir: URL) throws -> LabFixture {
        let data = try Data(contentsOf: dir.appendingPathComponent(ParityFixtureFile.fileName))
        return try LabFixture(file: try JSONDecoder().decode(ParityFixtureFile.self, from: data), dir: dir)
    }

    func input() -> PreviewStageView.FrameInput {
        PreviewStageView.FrameInput(
            project: project,
            currentTime: currentTime,
            isPlaying: isPlaying,
            cursorEvents: cursorEvents,
            cursorCoordinateSize: coordinateSize,
            videoSize: videoSize,
            player: nil,
            cameraPlayer: nil,
            cameraPosterImage: project.settings.showCamera ? cameraPoster : nil,
            cameraVideoAspect: cameraAspect,
            videoPosterImage: videoPoster,
            cameraMask: cameraMask
        )
    }

    private static func png(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "LabFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot decode \(url.lastPathComponent)"])
        }
        return image
    }
}
