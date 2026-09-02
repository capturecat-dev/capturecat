import AVFoundation
import Foundation
import os

private let stitchLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "RecordingStitcher")

/// Joins the segment files produced by mid-recording source switches
/// (desktop → iPhone → …) into one continuous movie. Segments can have
/// different dimensions — each is aspect-fit into the first segment's render
/// size. Returns per-segment metadata (time range, source kind, content rect)
/// so the editor can crop and bezel-frame device segments at display time.
enum RecordingStitcher {
    struct InputSegment {
        let url: URL
        let kind: RecordingSourceKind
    }

    struct Result {
        let url: URL
        let segments: [ProjectSourceSegment]
    }

    enum StitchError: LocalizedError {
        case noSegments
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noSegments: return "No recorded segments to combine."
            case .exportFailed: return "Combining the recording segments failed."
            }
        }
    }

    static func stitch(_ inputs: [InputSegment], outputURL: URL) async throws -> Result {
        guard !inputs.isEmpty else { throw StitchError.noSegments }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw StitchError.exportFailed }
        // Up to two parallel audio lanes (system audio + mic on screen segments).
        var audioTracks: [AVMutableCompositionTrack] = []

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var segmentInfos: [ProjectSourceSegment] = []
        var cursor = CMTime.zero
        var renderSize = CGSize.zero

        for input in inputs {
            let asset = AVURLAsset(url: input.url)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
                stitchLogger.error("segment has no video track: \(input.url.lastPathComponent, privacy: .public)")
                continue
            }

            // Writers anchored to a shared clock leave an EMPTY lead before the
            // first sample (renders as black). Start each segment at its first
            // real frame.
            let firstSample = await firstVideoSampleTime(of: asset, track: sourceVideo)
            let trackRange = (try? await sourceVideo.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: .zero)
            let contentStart = max(trackRange.start, CMTime(seconds: firstSample, preferredTimescale: 600))
            let contentDuration = CMTimeSubtract(trackRange.end, contentStart)
            guard contentDuration.seconds > 0.05 else { continue }
            let sourceRange = CMTimeRange(start: contentStart, duration: contentDuration)

            try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)

            let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            for (index, audio) in sourceAudio.prefix(2).enumerated() {
                while audioTracks.count <= index {
                    guard let track = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { break }
                    audioTracks.append(track)
                }
                guard index < audioTracks.count else { continue }
                try? audioTracks[index].insertTimeRange(sourceRange, of: audio, at: cursor)
            }

            let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            if renderSize == .zero {
                renderSize = naturalSize
            }

            // Aspect-fit this segment into the render size.
            let scale = min(renderSize.width / max(1, naturalSize.width),
                            renderSize.height / max(1, naturalSize.height))
            let scaledWidth = naturalSize.width * scale
            let scaledHeight = naturalSize.height * scale
            let offsetX = (renderSize.width - scaledWidth) / 2
            let offsetY = (renderSize.height - scaledHeight) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: cursor)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: contentDuration)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            segmentInfos.append(ProjectSourceSegment(
                startTime: cursor.seconds,
                duration: contentDuration.seconds,
                kind: input.kind,
                contentX: Double(offsetX / renderSize.width),
                contentY: Double(offsetY / renderSize.height),
                contentWidth: Double(scaledWidth / renderSize.width),
                contentHeight: Double(scaledHeight / renderSize.height)
            ))

            cursor = CMTimeAdd(cursor, contentDuration)
        }

        guard cursor.seconds > 0.05, renderSize != .zero else { throw StitchError.noSegments }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = instructions

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StitchError.exportFailed
        }
        export.videoComposition = videoComposition
        try? FileManager.default.removeItem(at: outputURL)
        try await export.export(to: outputURL, as: .mov)
        stitchLogger.info("stitched \(inputs.count) segments → \(outputURL.lastPathComponent, privacy: .public) (\(cursor.seconds, privacy: .public)s)")
        return Result(url: outputURL, segments: segmentInfos)
    }

    /// First real sample PTS — writers can leave an empty (black) lead.
    private static func firstVideoSampleTime(of asset: AVAsset, track: AVAssetTrack) async -> TimeInterval {
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else { return 0 }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        reader.cancelReading()
        return time.isFinite ? max(0, time) : 0
    }
}
