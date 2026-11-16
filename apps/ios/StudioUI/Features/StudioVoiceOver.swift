import Observation
import UIKit

/// What the voice-over sheet needs from the editor's player: where the
/// playhead is (the take starts there, clamped into the trim window, as on
/// the Mac) and the play switch (the recording plays while the narrator
/// speaks, as on the Mac). `StudioPlaybackController` and the timeline's
/// bare `StudioTimelinePlayhead` both conform.
@MainActor
protocol StudioVoiceOverTransport: AnyObject {
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    func setPlaying(_ playing: Bool, for project: Project)
    /// The voice clips changed: rebuild what the player mixes (the Mac's
    /// `scheduleVoiceOverRefresh`).
    func scheduleVoiceOverRefresh(for project: Project)
}

extension StudioPlaybackController: StudioVoiceOverTransport {
    /// The Mac's voice refresh: 250 ms after the clips change (and never
    /// mid-take), reload the player so its audio mix carries the new voice
    /// track, at the same playhead, resuming if it was playing.
    func scheduleVoiceOverRefresh(for project: Project) {
        StudioVoiceOverRefresh.shared.schedule { [weak self] in
            guard let self, !StudioVoiceOver.session.isRecording else { return }
            let resume = self.isPlaying
            await self.setup(for: project, initialTime: self.currentTime)
            if resume { self.setPlaying(true, for: project) }
        }
    }
}

extension StudioTimelinePlayhead: StudioVoiceOverTransport {
    func setPlaying(_ playing: Bool, for project: Project) { isPlaying = playing }
    func scheduleVoiceOverRefresh(for project: Project) {}
}

/// One pending refresh at a time (the Mac's `voiceOverRefreshTask`).
@MainActor
final class StudioVoiceOverRefresh {
    static let shared = StudioVoiceOverRefresh()
    private var task: Task<Void, Never>?

    func schedule(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await work()
            self?.task = nil
        }
    }
}

/// Voice-over (Studio 4e): record narration from the microphone into the
/// VOICE track. The engine is the Mac's — `VoiceOverSession` (Studio/):
/// the same recorder settings, start clamp, 45 ms level meter, file
/// finalize wait and clip placement. This file is only the touch front end.
///
///     StudioVoiceOver.present(from: editor, project: project,
///                             undoManager: undo, transport: playback)
///
/// The take lands as ONE undo step ("Record Voice Over"; the file stays on
/// disk so redo restores it). The timeline's VOICE row draws the live take
/// from `StudioVoiceOver.session` (`isRecording`, `recordingStartTime`,
/// `liveSamples` — the fields its `StudioTimelinePlayback` reads).
@MainActor
enum StudioVoiceOver {
    /// The one take engine for the open editor.
    static let session = VoiceOverSession()

    @discardableResult
    static func present(
        from presenter: UIViewController,
        project: Project,
        undoManager: UndoManager?,
        transport: StudioVoiceOverTransport? = nil,
        onClipAdded: ((VoiceOverClip) -> Void)? = nil
    ) -> StudioVoiceOverController {
        let controller = StudioVoiceOverController(project: project, undoManager: undoManager,
                                                   transport: transport, session: session)
        controller.onClipAdded = onClipAdded
        controller.present(from: presenter)
        return controller
    }

    /// One undo step for a recorded clip (redo puts it back); `changed`
    /// runs after each (the player's voice refresh).
    static func registerUndo(adding clip: VoiceOverClip, to project: Project, undoManager: UndoManager?,
                             changed: @escaping () -> Void = {}) {
        undoManager?.registerUndo(withTarget: project) { project in
            project.voiceOverClips.removeAll { $0.id == clip.id }
            changed()
            undoManager?.registerUndo(withTarget: project) { project in
                project.voiceOverClips.append(clip)
                changed()
                registerUndo(adding: clip, to: project, undoManager: undoManager, changed: changed)
            }
        }
        undoManager?.setActionName("Record Voice Over")
    }
}

@MainActor
final class StudioVoiceOverController {
    let project: Project
    let session: VoiceOverSession
    private weak var undoManager: UndoManager?
    private weak var transport: StudioVoiceOverTransport?
    var onClipAdded: ((VoiceOverClip) -> Void)?
    var onError: ((String) -> Void)?

    let meter = StudioVoiceLevelMeter()
    let timeLabel = ccLabel("0:00.0", font: CCFont.mono, color: CCTheme.color.foreground, alignment: .center)
    let recordButton = CCButton(title: "Record", symbol: "mic.fill", style: .primary, size: .lg)
    private(set) var alert: CCAlert?
    private var observation: SurfaceObservation?
    private var wasPlaying = false

    /// The clips this sheet added (probe).
    private(set) var addedClips: [VoiceOverClip] = []

    init(project: Project, undoManager: UndoManager?, transport: StudioVoiceOverTransport?, session: VoiceOverSession) {
        self.project = project
        self.undoManager = undoManager
        self.transport = transport
        self.session = session
        recordButton.onTap = { [weak self] in self?.toggle() }
        recordButton.accessibilityIdentifier = "studio.voiceover.record"
        timeLabel.accessibilityIdentifier = "studio.voiceover.time"
    }

    func present(from presenter: UIViewController) {
        let meterRow = UIStackView(arrangedSubviews: [meter, timeLabel])
        meterRow.axis = .vertical
        meterRow.spacing = CCSpace.sm
        let alert = StudioFeatureSheet.make(
            title: "Voice Over",
            message: "Narrate over the recording from the playhead. It plays while you speak; stop when you're done and the take lands on the voice track.",
            symbol: "mic.fill",
            content: [meterRow, recordButton])
        alert.addButton("Done", role: .cancel)
        self.alert = alert
        alert.present(from: presenter) { [weak self] _ in self?.sheetClosed() }
        observation = SurfaceObservation { [weak self] in self?.apply() }
    }

    func toggle() {
        Task { @MainActor in
            if session.isRecording { await stop() } else { await start() }
        }
    }

    func start() async {
        guard !session.isRecording else { return }
        do {
            try await session.prepare(for: project)
            try session.begin(for: project, currentTime: transport?.currentTime ?? project.effectiveTrimStart)
            CCHaptics.light()
            wasPlaying = transport?.isPlaying ?? false
            if transport?.isPlaying == false { transport?.setPlaying(true, for: project) }
        } catch {
            session.abort()
            alert?.probeShowError(error.localizedDescription)
            onError?(error.localizedDescription)
        }
    }

    @discardableResult
    func stop(discard: Bool = false) async -> VoiceOverClip? {
        guard session.isRecording else { return nil }
        let fallback = transport?.currentTime ?? project.effectiveTrimStart
        let clip = await session.finish(for: project, discard: discard, fallbackStart: fallback)
        if !wasPlaying { transport?.setPlaying(false, for: project) }
        if let clip {
            let project = project
            StudioVoiceOver.registerUndo(adding: clip, to: project, undoManager: undoManager) { [weak transport] in
                transport?.scheduleVoiceOverRefresh(for: project)
            }
            transport?.scheduleVoiceOverRefresh(for: project)
            addedClips.append(clip)
            CCHaptics.success()
            onClipAdded?(clip)
        }
        return clip
    }

    private func sheetClosed() {
        // Done mid-take keeps the take, as the Mac's stop key does.
        if session.isRecording { Task { @MainActor in await stop() } }
        observation = nil
    }

    private func apply() {
        let recording = session.isRecording
        let samples = session.liveSamples
        meter.show(samples: samples, recording: recording)
        let t = recording ? session.recorder.currentTime : 0
        timeLabel.text = String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
        let title = recording ? "Stop" : "Record"
        if recordButton.title != title {
            recordButton.title = title
            recordButton.symbol = recording ? "stop.fill" : "mic.fill"
            recordButton.style = recording ? .destructive : .primary
        }
    }
}

/// The live level: the session's last samples as bars, newest at the
/// right. Each new sample's bar springs up from the baseline (house spring);
/// older bars shift left without motion.
@MainActor
final class StudioVoiceLevelMeter: UIView {
    static let barCount = 48
    private var bars: [CALayer] = []
    private var shownCount = 0
    private var lastSamples: [Float] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        layer.cornerRadius = CCTheme.radius(.md)
        layer.cornerCurve = .continuous
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.cornerRadius = 1.5
            layer.addSublayer(bar)
            bars.append(bar)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Input level"
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.active), radius: CCTheme.radius(.md), traits: traitCollection)
        for bar in bars { bar.backgroundColor = CCTheme.color.primary.resolvedColor(with: traitCollection).cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CCMaterial.refit(layer, radius: CCTheme.radius(.md))
        layoutBars(animatingNewest: false)
    }

    private var slot: CGFloat { bounds.width / CGFloat(Self.barCount) }
    private var maxHeight: CGFloat { max(0, bounds.height - 12) }

    private func height(for level: Float) -> CGFloat {
        max(2, maxHeight * CGFloat(min(1, max(0, level))))
    }

    func show(samples: [Float], recording: Bool) {
        let visible = Array(samples.suffix(Self.barCount))
        let grew = samples.count != lastSamples.count || samples.last != lastSamples.last
        lastSamples = samples
        shownCount = visible.count
        accessibilityValue = recording ? "\(Int(((visible.last ?? 0) * 100).rounded())) percent" : "Idle"
        guard bounds.width > 0 else { return }
        layoutBars(animatingNewest: recording && grew && !visible.isEmpty)
    }

    private func layoutBars(animatingNewest: Bool) {
        let visible = Array(lastSamples.suffix(Self.barCount))
        let offset = Self.barCount - visible.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let x = (CGFloat(i) + 0.5) * slot
            bar.position = CGPoint(x: x, y: bounds.height - 6)
            let level: Float? = i >= offset ? visible[i - offset] : nil
            bar.isHidden = level == nil
            let h = level.map(height(for:)) ?? 0
            if !(animatingNewest && i == bars.count - 1) {
                bar.removeAnimation(forKey: "ccmotion.bounds.size.height")
                bar.bounds = CGRect(x: 0, y: 0, width: max(2, slot - 2), height: h)
            }
        }
        CATransaction.commit()
        if animatingNewest, let newest = bars.last, let level = visible.last {
            newest.bounds.size.width = max(2, slot - 2)
            probeHeightsShown.append(height(for: level))
            CCMotion.spring(newest, keyPath: "bounds.size.height", from: 2, to: height(for: level), .snappy)
        }
    }

    /// Probe seams: the newest bar as drawn now vs its target, and the
    /// levels shown.
    var probeNewestBar: (drawn: CGFloat, target: CGFloat)? {
        guard let bar = bars.last, !bar.isHidden, let level = lastSamples.last else { return nil }
        return ((bar.presentation() ?? bar).bounds.height, height(for: level))
    }
    var probeShownCount: Int { shownCount }
    /// Every height the newest bar was sent to, plus where it springs from
    /// (a snapped bar only ever draws one of those).
    private(set) var probeHeightsShown: [CGFloat] = [2]
}
