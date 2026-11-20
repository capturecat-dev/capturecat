import CoreGraphics
import Foundation

// The inspector's value logic, shared by the Mac panes (Views/Editor/
// InspectorKit/*PaneAppKit.swift) and the iOS panes (apps/ios/StudioUI/
// Inspector). Studio 4d moved it here so both front ends call ONE copy:
// every control's title, range, step, readout, the project fields it writes
// (with the side rules — "picking a tint at zero strength gives it 0.3",
// "Loop and Stop are exclusive"…) and when it is shown. The front ends only
// draw: the Mac with InspectorKit, iOS with the house UIKit kit.
//
// Ids ("background.blur") are stable: the Mac `--inspector-values-test` and
// the iOS `--inspector` gate address controls by them, and the shared
// transcript (StudioHarness/InspectorValuesTranscript) is keyed by them.

/// What an inspector control reads and writes: the settings, the project
/// (nil for the Mac's settings-only panes), the recording facts that decide
/// what is shown, and the selection-driven targets of the Effects and
/// Annotate panes.
@MainActor
struct InspectorScope {
    let settings: ProjectSettings
    let project: Project?
    var env: InspectorEnvironment
    var motion: MotionPaneContext?
    var annotate: AnnotatePaneContext?

    init(settings: ProjectSettings, project: Project? = nil, env: InspectorEnvironment = InspectorEnvironment(),
         motion: MotionPaneContext? = nil, annotate: AnnotatePaneContext? = nil) {
        self.settings = settings
        self.project = project
        self.env = env
        self.motion = motion
        self.annotate = annotate
    }

    /// The whole project's scope (iOS builds one per access, so an undo that
    /// swaps `project.settings` is never read through a stale object).
    init(project: Project, env: InspectorEnvironment, motion: MotionPaneContext? = nil,
         annotate: AnnotatePaneContext? = nil) {
        self.init(settings: project.settings, project: project, env: env, motion: motion, annotate: annotate)
    }
}

/// Facts about the recording that decide which controls exist — the values
/// the Mac's `InspectorColumnAppKit` computed inline when it built the panes.
struct InspectorEnvironment: Equatable {
    var isDeviceRecording = false
    var supportsMenuBar = true
    var hasRecordedCamera = false
    var hasKeystrokeData = true
    var hasShortcutData = false
    var isWindowRecording = false
    /// Input Monitoring granted (Mac). iOS never records keystrokes and has
    /// no such permission to ask for: true, so the Mac-only prompt stays hidden.
    var hasKeystrokePermission = true

    init() {}

    /// The column's formulas, verbatim.
    @MainActor
    static func of(_ project: Project, hasKeystrokePermission: Bool = true) -> InspectorEnvironment {
        var env = InspectorEnvironment()
        env.isDeviceRecording = project.recordingSourceKind == .device
            || project.sourceSegments.contains { $0.kind == .device }
        env.supportsMenuBar = project.recordingSourceKind != .device
        env.hasRecordedCamera = project.cameraVideoURL != nil
        env.hasKeystrokeData = project.keystrokeDataURL != nil
        env.isWindowRecording = project.recordingSourceKind == .window
        env.hasShortcutData = project.keystrokeDataURL
            .flatMap { try? KeystrokeRecording.load(from: $0).events }?
            .contains { $0.shortcut != nil } ?? false
        env.hasKeystrokePermission = hasKeystrokePermission
        return env
    }
}

// MARK: - Control specs

/// A slider: one label-inside pill (CCSlider on both platforms). `step` nil
/// is continuous; `format` nil shows the house 0–100% readout.
@MainActor
struct InspectorSlider {
    let id: String
    let title: String
    let range: ClosedRange<Double>
    let step: Double?
    var format: ((Double) -> String)?
    /// A range that depends on the target (the Annotate border: 1…30 for a
    /// drawing, else 0…12).
    var rangeFor: ((InspectorScope) -> ClosedRange<Double>)?
    let read: (InspectorScope) -> Double
    let write: (InspectorScope, Double) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }

    func range(in scope: InspectorScope) -> ClosedRange<Double> { rangeFor?(scope) ?? range }
}

@MainActor
struct InspectorToggle {
    let id: String
    let title: String
    let read: (InspectorScope) -> Bool
    let write: (InspectorScope, Bool) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }
    var enabled: (InspectorScope) -> Bool = { _ in true }
}

/// One-of-N: chips (InspectorChipsControl / CCChipGroup) or a menu
/// (InspectorMenuControl / CCSelect).
@MainActor
struct InspectorChoice {
    enum Style { case chips, menu }

    let id: String
    /// The menu row's label; chips are titled by their section (VoiceOver
    /// reads it as the group's label).
    let title: String
    let style: Style
    let items: [String]
    /// nil = nothing selected (a menu showing "Custom", an action chip row).
    let read: (InspectorScope) -> Int?
    let write: (InspectorScope, Int) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }
    /// A menu's collapsed title while a freeform value supersedes the enum.
    var overrideTitle: (InspectorScope) -> String? = { _ in nil }
}

@MainActor
struct InspectorColor {
    let id: String
    let title: String
    var supportsOpacity = true
    let read: (InspectorScope) -> CodableColor
    let write: (InspectorScope, CodableColor) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }
}

@MainActor
struct InspectorText {
    /// `.live` writes on every keystroke (SwiftUI TextField semantics);
    /// `.onEnd` when editing ends.
    enum Commit { case live, onEnd }

    let id: String
    let title: String
    let placeholder: String
    let commit: Commit
    let read: (InspectorScope) -> String
    let write: (InspectorScope, String) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }
}

/// A button whose effect is a model edit (Reset Look, Remove Highlight…).
@MainActor
struct InspectorAction {
    let id: String
    let title: (InspectorScope) -> String
    var destructive = false
    let run: (InspectorScope) -> Void
    var visible: (InspectorScope) -> Bool = { _ in true }

    init(id: String, title: String, destructive: Bool = false,
         run: @escaping (InspectorScope) -> Void,
         visible: @escaping (InspectorScope) -> Bool = { _ in true }) {
        self.init(id: id, dynamicTitle: { _ in title }, destructive: destructive, run: run, visible: visible)
    }

    init(id: String, dynamicTitle: @escaping (InspectorScope) -> String, destructive: Bool = false,
         run: @escaping (InspectorScope) -> Void,
         visible: @escaping (InspectorScope) -> Bool = { _ in true }) {
        self.id = id
        self.title = dynamicTitle
        self.destructive = destructive
        self.run = run
        self.visible = visible
    }
}

/// Muted copy under a control; `full` is the Mac tooltip's longer story.
@MainActor
struct InspectorCaption {
    let id: String
    let text: (InspectorScope) -> String
    /// The copy when it never changes (nil for dynamic captions).
    let fixed: String?
    var full: String?
    var visible: (InspectorScope) -> Bool = { _ in true }

    init(id: String, _ text: String, full: String? = nil,
         visible: @escaping (InspectorScope) -> Bool = { _ in true }) {
        self.id = id
        self.text = { _ in text }
        self.fixed = text
        self.full = full
        self.visible = visible
    }

    init(id: String, dynamic text: @escaping (InspectorScope) -> String,
         visible: @escaping (InspectorScope) -> Bool = { _ in true }) {
        self.id = id
        self.text = text
        self.fixed = nil
        self.full = nil
        self.visible = visible
    }
}

/// A button that starts a feature built elsewhere (transcription, Auto Zoom,
/// background removal, voice-over, History). The pane only hosts the key;
/// the host wires the feature (Studio 4e/4f on iOS).
enum InspectorFeature: String, CaseIterable {
    case transcribe
    case autoZoom
    case removeBackground
    case recordVoiceOver
    case showHistory

    var title: String {
        switch self {
        case .transcribe: return String(localized: "Generate Subtitles", comment: "Inspector: button that starts a feature")
        case .autoZoom: return String(localized: "Auto Zoom", comment: "Inspector: button that starts a feature")
        case .removeBackground: return String(localized: "Remove Background", comment: "Inspector: button that starts a feature")
        case .recordVoiceOver: return String(localized: "Record Voice Over", comment: "Inspector: button that starts a feature")
        case .showHistory: return String(localized: "History", comment: "Inspector: button that opens the project version history")
        }
    }

    var symbol: String {
        switch self {
        case .transcribe: return "captions.bubble"
        case .autoZoom: return "sparkle.magnifyingglass"
        case .removeBackground: return "person.crop.rectangle"
        case .recordVoiceOver: return "mic"
        case .showHistory: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Pane layout

/// One row of a pane, in Mac layout order. `custom` rows are drawn by each
/// front end (pads, previews, grids, lists); their value math is shared in
/// `InspectorPadMath` and the pane enums.
@MainActor
enum InspectorRow {
    case slider(InspectorSlider)
    case toggle(InspectorToggle)
    case choice(InspectorChoice)
    case color(InspectorColor)
    /// Two wells on one labelled row (Camera ▸ Card Colors).
    case colorPair(title: String, InspectorColor, InspectorColor)
    case text(InspectorText)
    case action(InspectorAction)
    /// Several buttons on one row.
    case actions([InspectorAction])
    case caption(InspectorCaption)
    case feature(InspectorFeature, visible: (InspectorScope) -> Bool)
    case custom(id: String, visible: (InspectorScope) -> Bool)

    var id: String {
        switch self {
        case .slider(let s): return s.id
        case .toggle(let t): return t.id
        case .choice(let c): return c.id
        case .color(let c): return c.id
        case .colorPair(_, let a, _): return a.id
        case .text(let t): return t.id
        case .action(let a): return a.id
        case .actions(let a): return a.first?.id ?? "actions"
        case .caption(let c): return c.id
        case .feature(let f, _): return "feature.\(f.rawValue)"
        case .custom(let id, _): return id
        }
    }

    func isVisible(_ scope: InspectorScope) -> Bool {
        switch self {
        case .slider(let s): return s.visible(scope)
        case .toggle(let t): return t.visible(scope)
        case .choice(let c): return c.visible(scope)
        case .color(let c): return c.visible(scope)
        case .colorPair(_, let a, _): return a.visible(scope)
        case .text(let t): return t.visible(scope)
        case .action(let a): return a.visible(scope)
        case .actions(let a): return a.contains { $0.visible(scope) }
        case .caption(let c): return c.visible(scope)
        case .feature(_, let visible): return visible(scope)
        case .custom(_, let visible): return visible(scope)
        }
    }
}

/// A titled group of rows — the Mac's InspectorSectionBox.
@MainActor
struct InspectorSection {
    let id: String
    let title: String?
    let rows: [InspectorRow]
    var visible: (InspectorScope) -> Bool = { _ in true }
}

// MARK: - Readouts (the Mac panes' format closures, verbatim)

enum InspectorFormat {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    /// `Int(v * 100)` — truncating, as the Mac's opacity readouts were written.
    static func percentTruncating(_ v: Double) -> String { "\(Int(v * 100))%" }
    static func degreesRounded(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    static func multiplier1(_ v: Double) -> String { UnitText.multiplier(v, digits: 1) }
    static func multiplier2(_ v: Double) -> String { UnitText.multiplier(v, digits: 2) }
    static func times2(_ v: Double) -> String { String(format: "%.2f×", v) }
    static func seconds1(_ v: Double) -> String { UnitText.seconds(v, digits: 1) }
}

// MARK: - Shared helpers

extension CodableColor {
    /// An opaque colour from the card-style RGB triples.
    init(_ rgb: CameraCardStyle.RGB) {
        self.init(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b), opacity: 1)
    }
}

/// The sounds a few toggles preview (Cursor ▸ Click Sound / Keyboard Sounds).
/// Harnesses mute them; the players themselves are the shared Studio ones.
@MainActor
enum InspectorSounds {
    static var muted = false

    static func clickPreview(volume: Double, style: ClickSoundStyle) {
        guard !muted else { return }
        ClickSoundPlayer.shared.playPreview(volume: volume, style: style)
    }

    static func click(volume: Double, style: ClickSoundStyle) {
        guard !muted else { return }
        ClickSoundPlayer.shared.play(volume: volume, style: style)
    }

    static func keyBurst(volume: Double, style: KeySoundStyle) {
        guard !muted else { return }
        KeySoundPlayer.shared.playTestBurst(volume: volume, style: style)
    }
}

// MARK: - The nine panes

extension InspectorTab {
    /// Each tab's sections in Mac layout order. Effects = the project-wide
    /// effects list, then the selected block's editors (MotionSettingsPane
    /// embeds EffectsSettingsPane first); Motion = how motion feels.
    @MainActor
    var sections: [InspectorSection] {
        switch self {
        case .background: return BackgroundPane.sections
        case .cursor: return CursorPane.sections
        case .camera: return CameraPane.sections
        case .audio: return AudioPane.sections
        case .effects: return EffectsPane.sections + EffectBlocksPane.sections
        case .motion: return MotionFeelPane.sections
        case .subtitles: return SubtitlePane.sections
        case .brand: return BrandPane.sections
        case .annotations: return AnnotationPane.sections
        }
    }
}
