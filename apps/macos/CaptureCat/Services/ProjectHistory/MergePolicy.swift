import Foundation

/// The project-merge policy table (docs/project-history.md §Policy).
///
/// A LITERAL in both languages — this file and
/// apps/web/src/editor/core/merge/policy.ts. `MergePolicy.hash` (FNV-1a 64 of
/// the canonical JSON) is written into the `mergePolicy` golden vectors, and
/// the TS suite fails when its own table hashes differently.
///
/// Facts it encodes (verified against Models/ and the timeline guards,
/// 2026-09-30):
/// - every id collection has a REQUIRED `id` except `cameraLayoutRegions`
///   (`decodeIfPresent(UUID.self) ?? UUID()`), so id-less legacy arrays exist
///   and merge as one value;
/// - splitPoints, sourceSegments, drawingStrokes have no ids → atomic;
/// - `TimelineViewController.splitVideoClip` replaces the split clip with two
///   FRESH-id clips → clip structure is one prompt group, never merged by id;
/// - `VoiceOverClip` has no endTime: its timing group is {startTime,
///   sourceStartTime, duration} (what `VoiceTrackEditMath` edits together);
/// - exclusive lanes: effects = zoom + tilt (`TimelineCanvasView
///   .effectLaneSpans`; co-spanning zoom/tilt within
///   `EffectBlockItem.linkEpsilon` are one linked block, paired exactly like
///   `canvasEffectItems`), focus = blur + depth focus + camera layout +
///   highlight (`focusLaneSpans`), speed = speed regions (add / duplicate
///   guards). Annotations, voice-overs and subtitles may overlap.
nonisolated struct MergePolicy: Sendable {
    struct AtomicGroup: Sendable {
        let name: String
        let keys: [String]
        let prompt: Bool
    }

    struct IdCollection: Sendable {
        let key: String
        let groups: [[String]]
        let regenerationCheck: Bool
        let nested: [IdCollection]

        init(_ key: String, _ groups: [[String]], regenerationCheck: Bool = false, nested: [IdCollection] = []) {
            self.key = key
            self.groups = groups
            self.regenerationCheck = regenerationCheck
            self.nested = nested
        }
    }

    struct LaneLink: Sendable {
        let primary: String
        let secondary: String
        let epsilon: Double
    }

    struct Lane: Sendable {
        let name: String
        let collections: [String]
        let link: LaneLink?
    }

    struct SettingsTab: Sendable {
        let tab: String
        let keys: [String]
    }

    let version: Int
    let rootGroups: [AtomicGroup]
    let settingsKey: String
    let settingsGroups: [AtomicGroup]
    let collections: [IdCollection]
    let lanes: [Lane]
    let overlapEpsilon: Double
    let regenerationSurvival: Double
    let settingsTabs: [SettingsTab]

    private static let timing = ["startTime", "endTime"]
    private static let rect = ["rectX", "rectY", "rectW", "rectH"]

    static let standard = MergePolicy(
        version: 1,
        rootGroups: [
            AtomicGroup(name: "clipStructure", keys: ["videoClipSegments", "splitPoints", "trimStart", "trimEnd"], prompt: true),
            AtomicGroup(
                name: "recording",
                keys: [
                    "sourceSegments", "duration", "videoURL", "cursorDataURL", "keystrokeDataURL",
                    "cameraVideoURL", "cameraTimeOffset", "recordingSourceKind",
                ],
                prompt: false
            ),
        ],
        settingsKey: "settings",
        settingsGroups: [
            AtomicGroup(name: "videoPlacement", keys: ["videoPlacement", "videoCustomX", "videoCustomY"], prompt: false),
            AtomicGroup(name: "cameraPosition", keys: ["cameraPosition", "cameraCustomX", "cameraCustomY"], prompt: false),
            AtomicGroup(name: "subtitlePosition", keys: ["subtitlePosition", "subtitleCustomX", "subtitleCustomY"], prompt: false),
            AtomicGroup(name: "watermarkPosition", keys: ["watermarkX", "watermarkY"], prompt: false),
            AtomicGroup(name: "backgroundImage", keys: ["backgroundType", "backgroundImagePath"], prompt: false),
            AtomicGroup(name: "screenTilt", keys: ["screenTiltMode", "screenTiltAngle", "screenTiltYaw", "screenTiltRoll"], prompt: false),
            AtomicGroup(name: "intro", keys: ["introSlideStyle", "introSlideStart", "introSlideDuration"], prompt: false),
            AtomicGroup(name: "curtain", keys: ["curtainUnveilCorner", "curtainUnveilStart", "curtainUnveilDuration"], prompt: false),
            AtomicGroup(name: "exportSettings", keys: ["exportSettings"], prompt: false),
        ],
        collections: [
            IdCollection("zoomRegions", [timing, ["focalPoint"], ["cardOffsetX", "cardOffsetY"]]),
            IdCollection("tiltRegions", [timing]),
            IdCollection("blurRegions", [timing, rect]),
            IdCollection("highlightRegions", [timing, rect]),
            IdCollection("focusRegions", [timing, rect]),
            IdCollection("cameraLayoutRegions", [timing]),
            IdCollection("annotations", [timing, ["x", "y", "arrowEndX", "arrowEndY"], ["drawingStrokes"]]),
            IdCollection("voiceOverClips", [["startTime", "sourceStartTime", "duration"]]),
            IdCollection("speedRegions", [timing]),
            IdCollection("subtitles", [timing], regenerationCheck: true, nested: [IdCollection("words", [timing])]),
        ],
        lanes: [
            Lane(
                name: "effects",
                collections: ["zoomRegions", "tiltRegions"],
                link: LaneLink(primary: "zoomRegions", secondary: "tiltRegions", epsilon: 0.02)
            ),
            Lane(name: "focus", collections: ["blurRegions", "focusRegions", "cameraLayoutRegions", "highlightRegions"], link: nil),
            Lane(name: "speed", collections: ["speedRegions"], link: nil),
        ],
        overlapEpsilon: 0.0001,
        regenerationSurvival: 0.5,
        // Settings key → inspector tab, from the pane that edits each key
        // (Views/Editor/InspectorKit/*PaneAppKit.swift). "canvas" = the
        // aspect-ratio menu, "export" = the export sheet.
        settingsTabs: [
            SettingsTab(tab: "background", keys: [
                "backgroundType", "gradientStartColor", "gradientEndColor", "solidColor", "backgroundImagePath",
                "backgroundPadding", "videoPlacement", "videoCustomX", "videoCustomY", "cornerRadius",
                "windowCornerRadius", "frameShape", "shadowRadius", "shadowOpacity", "gradientAngle",
                "backgroundBlur", "backgroundBrightness", "backgroundSaturation", "backgroundTintColor",
                "backgroundTintOpacity", "backgroundVignette", "backgroundPixelate", "backgroundHalftone",
                "backgroundNoise", "backgroundContrast", "backgroundHue", "showDeviceFrame", "menuBarReplacement",
                "menuBarTitle", "menuBarTitleAlignment", "menuBarShowStatusIcons", "menuBarClock", "menuBarHeight",
            ]),
            SettingsTab(tab: "cursor", keys: [
                "showCursor", "cursorStyle", "cursorScale", "autoHideCursor", "autoHideDelay", "smoothCursor",
                "smoothingFactor", "cursorTilt", "cursorStretch", "cursorDrag", "cursorWeight", "cursorFluidEnabled",
                "cursorTension", "cursorFriction", "cursorMass", "showClickRipple", "cursorLoopToStart",
                "cursorStopAtEnd", "clickSoundEnabled", "clickSoundVolume", "clickSoundStyle", "keySoundEnabled",
                "keySoundVolume", "keySoundStyle", "showKeystrokes", "keystrokeOverlaySize",
                "keystrokeOverlayPosition", "keystrokeOverlayAnimation", "keystrokeOverlayScopeToRecordedApp",
                "clickRippleColor", "clickRippleSize",
            ]),
            SettingsTab(tab: "camera", keys: [
                "showCamera", "cameraPosition", "cameraCustomX", "cameraCustomY", "cameraSize", "cameraShape",
                "cameraOrientation", "cameraMirrored", "cameraBrightness", "cameraContrast", "cameraSaturation",
                "cameraHue", "cameraFilter", "cameraRingLight", "cameraCornerRadius", "cameraBorderWidth",
                "cameraBorderColor", "cameraOpacity", "cameraTiltPitch", "cameraTiltYaw", "cameraTagText",
                "cameraTagSubtext", "cameraTagFontName", "cameraTagTextColor", "cameraTagBackgroundColor",
                "cameraTagPosition",
            ]),
            SettingsTab(tab: "audio", keys: ["systemAudioVolume", "microphoneVolume", "voiceOverVolume", "muteRecordedAudio"]),
            SettingsTab(tab: "effects", keys: [
                "motionBlur", "motionBlurStrength", "parallaxStrength", "introSlideStyle", "introSlideDuration",
                "introSlideStart", "introSlideBounce", "introSlideSpeed", "introSlideDepth", "curtainUnveilCorner",
                "curtainUnveilDuration", "curtainUnveilStart", "curtainLogoFileName", "curtainLogoOpacity",
                "curtainLogoScale", "curtainLogoTint", "curtainColor", "screenTiltMode", "screenTiltAngle",
                "screenTiltYaw", "screenTiltRoll",
            ]),
            SettingsTab(tab: "motion", keys: ["animationSpeed", "autoZoomLevel", "cameraFollowSpeed"]),
            SettingsTab(tab: "subtitles", keys: [
                "showSubtitles", "subtitleFontSize", "subtitlePosition", "subtitleStyle", "subtitleCustomX",
                "subtitleCustomY", "subtitleWeight", "subtitleUppercase", "subtitleFontName", "subtitleColor",
                "subtitleBackgroundColor", "highlightWords", "subtitleHighlightColor",
            ]),
            SettingsTab(tab: "brand", keys: [
                "showWatermark", "watermarkFileName", "watermarkX", "watermarkY", "watermarkSize", "watermarkOpacity",
            ]),
            SettingsTab(tab: "canvas", keys: ["aspectRatio"]),
            SettingsTab(tab: "export", keys: ["exportSettings"]),
        ]
    )

    /// The tab a settings key belongs to ("other" when unknown).
    func settingsTab(for key: String) -> String {
        settingsTabs.first { $0.keys.contains(key) }?.tab ?? "other"
    }

    func collection(_ key: String) -> IdCollection? {
        collections.first { $0.key == key }
    }

    // MARK: - JSON form (hashed; same shape as policyJSON() in policy.ts)

    private static func strings(_ list: [String]) -> JSONValue { .array(list.map { .string($0) }) }

    private static func groupJSON(_ g: AtomicGroup) -> JSONValue {
        .object(JSONObject([("name", .string(g.name)), ("keys", strings(g.keys)), ("prompt", .bool(g.prompt))]))
    }

    private static func collectionJSON(_ c: IdCollection) -> JSONValue {
        .object(JSONObject([
            ("key", .string(c.key)),
            ("groups", .array(c.groups.map(strings))),
            ("regenerationCheck", .bool(c.regenerationCheck)),
            ("nested", .array(c.nested.map(collectionJSON))),
        ]))
    }

    var json: JSONValue {
        .object(JSONObject([
            ("version", .number(Double(version))),
            ("rootGroups", .array(rootGroups.map(Self.groupJSON))),
            ("settingsKey", .string(settingsKey)),
            ("settingsGroups", .array(settingsGroups.map(Self.groupJSON))),
            ("collections", .array(collections.map(Self.collectionJSON))),
            ("lanes", .array(lanes.map { lane in
                .object(JSONObject([
                    ("name", .string(lane.name)),
                    ("collections", Self.strings(lane.collections)),
                    ("link", lane.link.map { link in
                        .object(JSONObject([
                            ("primary", .string(link.primary)),
                            ("secondary", .string(link.secondary)),
                            ("epsilon", .number(link.epsilon)),
                        ]))
                    } ?? .null),
                ]))
            })),
            ("overlapEpsilon", .number(overlapEpsilon)),
            ("regenerationSurvival", .number(regenerationSurvival)),
            ("settingsTabs", .array(settingsTabs.map { t in
                .object(JSONObject([("tab", .string(t.tab)), ("keys", Self.strings(t.keys))]))
            })),
        ]))
    }

    /// FNV-1a 64 of the canonical JSON — the value both languages must share.
    var hash: String { JSONHash.fnv1a64Hex(json.canonical) }
}
