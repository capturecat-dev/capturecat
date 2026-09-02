import AVFoundation
import CoreGraphics
import Foundation

struct TimelineThumbnail: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let image: CGImage

    var aspectRatio: CGFloat {
        guard image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}

/// Generates a strip of small frames for the timeline's video track — the
/// CapCut/FCP filmstrip look. Frames are decoded off the main actor and kept
/// small (96 px tall) so a full strip costs a few MB at most.
enum TimelineThumbnailer {
    static func generate(
        from url: URL,
        duration: TimeInterval,
        targetCount: Int
    ) async -> [TimelineThumbnail] {
        guard duration > 0, targetCount > 0 else { return [] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 96)
        // Filmstrip frames don't need exact timestamps — allow keyframe snapping
        // so generation stays fast on long HEVC recordings.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let stride = duration / Double(targetCount)
        let times = (0..<targetCount).map { index in
            CMTime(seconds: (Double(index) + 0.5) * stride, preferredTimescale: 600)
        }

        var out: [TimelineThumbnail] = []
        out.reserveCapacity(targetCount)
        for await result in generator.images(for: times) {
            if case .success(let requestedTime, let image, _) = result {
                out.append(TimelineThumbnail(time: requestedTime.seconds, image: image))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Nearest thumbnail at a source time, or nil when none are loaded yet.
    static func thumbnail(
        at time: TimeInterval,
        in thumbnails: [TimelineThumbnail]
    ) -> TimelineThumbnail? {
        guard !thumbnails.isEmpty else { return nil }
        var best = thumbnails[0]
        var bestDistance = abs(best.time - time)
        for thumb in thumbnails.dropFirst() {
            let distance = abs(thumb.time - time)
            if distance < bestDistance {
                best = thumb
                bestDistance = distance
            }
        }
        return best
    }
}
