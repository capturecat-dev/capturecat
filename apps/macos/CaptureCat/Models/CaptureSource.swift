import AVFoundation
import ScreenCaptureKit

enum CaptureSource {
    case display(SCDisplay)
    case window(SCWindow)
    case area(SCDisplay, CGRect) // display + rect in display points
    /// A connected iPhone/iPad exposed as a CoreMediaIO screen-capture device
    /// (the mechanism QuickTime's "New Movie Recording" uses).
    case iosDevice(AVCaptureDevice)
    /// An iPhone streaming over Wi-Fi from the CaptureCat iOS app's broadcast
    /// extension (WirelessDeviceHub / WirelessServer), by its lowercase
    /// device id. Recorded exactly like `.iosDevice`: a `.device` segment.
    case wirelessDevice(String)
}
