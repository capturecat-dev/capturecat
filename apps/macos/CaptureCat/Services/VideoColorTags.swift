import AVFoundation
import CoreVideo

/// The color tags BOTH the recorder and the exporter write.
///
/// Shared for the same reason TiltMath and friends are: the preview==export
/// gamma contract depends on the recorded file and the exported file carrying
/// byte-identical color tags, so the values must not be forked per call site.
///
/// Modern Mac displays are Display P3. Recordings are captured in Display P3
/// (P3-D65 primaries + the sRGB transfer function) so saturated on-screen
/// colors survive 1:1 instead of being gamut-clipped to sRGB at capture time.
/// The exporter detects the source's primaries per file and tags its output to
/// MATCH — P3 source → P3 tags, older sRGB/709-primaries recordings → sRGB
/// tags — so the player renders exactly what was recorded.
///
/// The availability dance: `AVVideoTransferFunction_IEC_sRGB` is a macOS 15+
/// SYMBOL, but the tag it resolves to — CoreMedia's "IEC_sRGB" — long predates
/// it. On macOS 14 the literal produces the identical bytes in the file.
/// Do NOT fall back to 709 here; that re-introduces the dull-export gamma bug
/// this tagging exists to prevent.
enum VideoColorTags {
    static var sRGBTransferFunction: String {
        if #available(macOS 15.0, *) {
            return AVVideoTransferFunction_IEC_sRGB
        }
        return "IEC_sRGB"
    }

    /// AVAssetWriter `AVVideoColorPropertiesKey` payload.
    /// Display P3 and sRGB share the same transfer curve; only the primaries
    /// tag differs. YCbCr matrix stays 709 in both (standard for RGB-native
    /// screen content in both P3-D65 and sRGB files).
    static func colorProperties(p3: Bool) -> [String: Any] {
        [
            AVVideoColorPrimariesKey: p3
                ? AVVideoColorPrimaries_P3_D65
                : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: sRGBTransferFunction,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    /// True when a source video track carries P3-D65 primaries.
    /// Missing/unknown primaries fall back to the sRGB path (older recordings
    /// and the synthetic harness fixtures are sRGB/709).
    static func isP3(formatDescription: CMFormatDescription?) -> Bool {
        guard let formatDescription,
              let primaries = CMFormatDescriptionGetExtension(
                  formatDescription,
                  extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
              ) as? String
        else { return false }
        return primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
    }

    /// The CGColorSpace matching `colorProperties(p3:)` — used as the export
    /// CIContext working space and every `render(colorSpace:)` destination so
    /// pixels are written in exactly the space the file is tagged with.
    static func renderColorSpace(p3: Bool) -> CGColorSpace {
        p3 ? CGColorSpace(name: CGColorSpace.displayP3)!
           : CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
