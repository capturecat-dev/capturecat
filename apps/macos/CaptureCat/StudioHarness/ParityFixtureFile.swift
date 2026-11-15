import CoreGraphics
import Foundation

/// The preview-parity fixture as DATA, written by the Mac
/// (`CaptureCat --preview-parity-fixtures <dir>`) and read by the iOS harness
/// app (StudioLab). The iOS gate scores against the Mac's frozen goldens, so
/// its inputs must be the Mac's inputs bit for bit: the project carries the
/// Mac's dark-appearance-resolved colours, and the images are the Mac's own
/// rasters (`video.png`, `camera.png`, `parity-logo.png`) — never redrawn on
/// iOS, where NSGradient and the system colours have no exact equivalent.
///
/// Shared folder: apps/macos/CaptureCat/StudioHarness/ is compiled by the Mac
/// app and by StudioLab; it never ships in the iOS app.
struct ParityFixtureFile: Codable {
    /// `JSONEncoder` output of the fixture `Project` (Mac-resolved).
    var project: Data
    var currentTime: TimeInterval
    var cursorEvents: [CursorEvent]
    var coordinateSize: CGSize
    var videoSize: CGSize
    var cameraAspect: CGFloat
    /// The Mac harness pane — the compositor's canvas there, the virtual
    /// canvas on iOS.
    var canvas: CGSize

    static let fileName = "fixture.json"
    static let videoFrame = "video.png"
    static let cameraPoster = "camera.png"
    static let logo = "parity-logo.png"
}
