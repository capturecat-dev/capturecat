import Foundation

extension Project {
    /// Every persisted property of `other` (all but `id`), assigned in place
    /// — how the editor's live model takes a restored or merged document
    /// without being replaced (the stage, timeline and inspector observe this
    /// instance). Runtime-only state (`previewCanvasSize`, save bookkeeping)
    /// stays.
    ///
    /// The list must name every `CodingKeys` case: DEBUG builds re-encode
    /// both sides afterwards and trap on any difference, and the History gate
    /// compares the restored model with the Mac's.
    func adoptState(of other: Project) {
        name = other.name
        createdAt = other.createdAt
        videoURL = other.videoURL
        cursorDataURL = other.cursorDataURL
        keystrokeDataURL = other.keystrokeDataURL
        cameraVideoURL = other.cameraVideoURL
        cameraTimeOffset = other.cameraTimeOffset
        settings = other.settings
        zoomRegions = other.zoomRegions
        tiltRegions = other.tiltRegions
        blurRegions = other.blurRegions
        highlightRegions = other.highlightRegions
        focusRegions = other.focusRegions
        cameraLayoutRegions = other.cameraLayoutRegions
        annotations = other.annotations
        voiceOverClips = other.voiceOverClips
        subtitles = other.subtitles
        speedRegions = other.speedRegions
        splitPoints = other.splitPoints
        videoClipSegments = other.videoClipSegments
        duration = other.duration
        trimStart = other.trimStart
        trimEnd = other.trimEnd
        recordingSourceKind = other.recordingSourceKind
        recordedAppBundleID = other.recordedAppBundleID
        sourceSegments = other.sourceSegments
        reminderDate = other.reminderDate
        isStillCapture = other.isStillCapture
        stillTreatment = other.stillTreatment
        referenceCanvasSize = other.referenceCanvasSize
        #if DEBUG
        let mine = Self.encodedWithoutID(self), theirs = Self.encodedWithoutID(other)
        assert(mine == theirs, "Project.adoptState(of:) misses a persisted property — add it")
        #endif
    }

    #if DEBUG
    private static func encodedWithoutID(_ project: Project) -> String {
        guard let data = try? JSONEncoder().encode(project),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        object["id"] = nil
        let out = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: out, as: UTF8.self)
    }
    #endif
}
