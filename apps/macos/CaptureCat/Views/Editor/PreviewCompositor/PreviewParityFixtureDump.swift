import AppKit
import ImageIO

/// `--preview-parity-fixtures <dir>` — writes the preview-parity fixture as
/// data (ParityFixtureFile + the Mac's rasters) for the iOS harness app.
/// Built exactly the way `runMatrix` builds it: the appearance is pinned to
/// darkAqua FIRST (the system colours in the defaults resolve at construction
/// time), then the same project, frame, poster, cursor path and logo.
@MainActor
extension PreviewParityHarness {
    static func dumpFixtures() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview-parity-fixtures"), args.indices.contains(i + 1) else {
            print("usage: CaptureCat --preview-parity-fixtures <dir>"); exit(64)
        }
        let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let project = makeFixtureProject()
            let naturalSize = CGSize(width: 1920, height: 1200)
            let t0 = project.effectiveTrimStart + 2.0
            let events = syntheticCursorEvents(around: t0, size: naturalSize)
            project.videoURL = dir.appendingPathComponent("video.mov")
            try writeLogoPNG(to: dir.appendingPathComponent(ParityFixtureFile.logo))
            guard let frame = syntheticVideoFrame(size: naturalSize).cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let poster = gradientPoster(size: CGSize(width: 400, height: 300))
                      .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("PARITY-FIXTURES FAIL rasters"); exit(1)
            }
            try writePNG(frame, dir.appendingPathComponent(ParityFixtureFile.videoFrame))
            try writePNG(poster, dir.appendingPathComponent(ParityFixtureFile.cameraPoster))
            let file = ParityFixtureFile(
                project: try JSONEncoder().encode(project),
                currentTime: t0,
                cursorEvents: events,
                coordinateSize: naturalSize,
                videoSize: naturalSize,
                cameraAspect: 4.0 / 3.0,
                canvas: paneSize
            )
            try JSONEncoder().encode(file).write(to: dir.appendingPathComponent(ParityFixtureFile.fileName))
            print("PARITY-FIXTURES OK dir=\(dir.path) frame=\(frame.width)x\(frame.height) poster=\(poster.width)x\(poster.height)")
            exit(0)
        } catch {
            print("PARITY-FIXTURES FAIL \(error)"); exit(1)
        }
    }

    private static func writePNG(_ image: CGImage, _ url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "parity-fixtures", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "parity-fixtures", code: 2) }
    }
}
