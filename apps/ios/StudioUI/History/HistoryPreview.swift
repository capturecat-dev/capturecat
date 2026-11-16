import UIKit

/// History ▸ Preview: an earlier version shown READ-ONLY on the editor's
/// live stage — the iOS twin of the Mac's `VersionPreviewController`.
///
/// The version's document is decoded into a SEPARATE `Project` (media
/// re-pointed into the project folder, `isPreview` set) and handed to the
/// editor as `stageProjectOverride`: the stage and transport show it, the
/// player and scrubbing stay live, editing is off, and nothing is ever saved
/// from it. A banner on the stage says what is shown — "Viewing Sep 28, 3:42
/// PM — Ana on Web" — with [Restore] [Back to Current].
///
/// Opening is animated as one move (and probed as a SEQUENCE by StudioLab
/// `--history`): the frame on screen dissolves into the version's while the
/// banner drops in from above the stage.
@available(iOS 26, *)
@MainActor
final class HistoryPreviewSession {
    #if DEBUG
    /// INJECTED DEFECT (`--history --inject snap-preview`): the preview
    /// swaps with no dissolve and the banner snaps in.
    static var debugSnap = false
    #endif

    static let dissolveDuration: TimeInterval = 0.42
    static let bannerTravel: CGFloat = -28

    private static var sessions: [ObjectIdentifier: HistoryPreviewSession] = [:]

    let version: CloudVersion
    let project: Project
    private weak var editor: EditorViewController?
    let banner: HistoryPreviewBanner
    /// The frame that was on screen, dissolving out (nil once gone).
    private(set) var dissolve: UIView?
    var onRestore: ((HistoryPreviewSession) -> Void)?
    var onEnd: (() -> Void)?

    static func current(in editor: EditorViewController) -> HistoryPreviewSession? {
        let key = ObjectIdentifier(editor)
        guard let session = sessions[key] else { return nil }
        // An editor that went away may have left its session; ids are reused.
        guard session.editor === editor else { sessions[key] = nil; return nil }
        return session
    }

    /// Shows `document` (version `version`) on `editor`'s stage.
    @discardableResult
    static func begin(version: CloudVersion, document: Data, in editor: EditorViewController,
                      clock: HistoryClock = .current) throws -> HistoryPreviewSession {
        let resolved = try StudioProjectFolder.resolve(document, in: editor.folder.directory)
        resolved.project.isPreview = true
        let previous = current(in: editor)
        let session = HistoryPreviewSession(version: version, project: resolved.project, editor: editor, clock: clock)
        sessions[ObjectIdentifier(editor)] = session
        previous?.banner.removeFromSuperview()
        previous?.dissolve?.removeFromSuperview()
        session.mount(replacing: previous)
        return session
    }

    private init(version: CloudVersion, project: Project, editor: EditorViewController, clock: HistoryClock) {
        self.version = version
        self.project = project
        self.editor = editor
        banner = HistoryPreviewBanner(title: HistoryWords.previewTitle(for: version, clock: clock),
                                      message: HistoryWords.previewMessage)
        banner.onRestore = { [weak self] in
            guard let self else { return }
            self.onRestore?(self)
        }
        banner.onBack = { [weak self] in self?.end() }
    }

    private func mount(replacing previous: HistoryPreviewSession?) {
        guard let editor else { return }
        editor.canvas.endInlineEdit(commit: true)
        let card = editor.stageCard
        // The frame on screen, held over the stage while the version renders under it.
        let snapshot = card.snapshotView(afterScreenUpdates: false) ?? UIView()
        snapshot.frame = card.frame
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        editor.view.insertSubview(snapshot, aboveSubview: card)
        dissolve = snapshot

        editor.stageProjectOverride = project
        editor.view.addSubview(banner)
        banner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.sm),
            banner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: CCSpace.sm),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -CCSpace.sm),
        ])
        editor.view.layoutIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: banner)

        #if DEBUG
        if Self.debugSnap {
            snapshot.removeFromSuperview()
            dissolve = nil
            return
        }
        #endif
        if CCMotion.reduceMotion {
            CCMotion.fadeAlpha(snapshot, to: 0, duration: 0.2)
            CCMotion.fadeAlpha(banner, to: 1, duration: 0.2, from: 0)
        } else {
            // One move: the old frame dissolves out as the banner drops in.
            CCMotion.fade(snapshot.layer, keyPath: "opacity", to: Float(0), duration: Self.dissolveDuration, from: Float(1))
            snapshot.layer.opacity = 0
            if previous == nil {
                CCMotion.fadeAlpha(banner, to: 1, duration: 0.2, from: 0)
                CCMotion.spring(banner.layer, keyPath: "transform.translation.y", from: Self.bannerTravel, to: 0, .arrive)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(Self.dissolveDuration) + 0.05) { [weak self, weak snapshot] in
            snapshot?.removeFromSuperview()
            if self?.dissolve === snapshot { self?.dissolve = nil }
        }
    }

    /// Back to the project (the banner glides up and out).
    func end(animated: Bool = true) {
        guard let editor else { return }
        if Self.sessions[ObjectIdentifier(editor)] === self { Self.sessions[ObjectIdentifier(editor)] = nil }
        editor.stageProjectOverride = nil
        dissolve?.removeFromSuperview()
        dissolve = nil
        let banner = self.banner
        if animated && !CCMotion.reduceMotion {
            CCMotion.fadeAlpha(banner, to: 0, duration: 0.18)
            CCMotion.run(duration: 0.2, curve: .glide) {
                banner.transform = CGAffineTransform(translationX: 0, y: Self.bannerTravel)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.22)) { banner.removeFromSuperview() }
        } else {
            banner.removeFromSuperview()
        }
        onEnd?()
    }

    // MARK: Probe seams

    var probeDissolve: UIView? { dissolve }
}

/// The stage banner of a preview: what is shown + [Restore] [Back to Current]
/// (the Mac's stage `CCCallout` with its two actions), as a floating kit card.
final class HistoryPreviewBanner: CCSurface {
    var onRestore: (() -> Void)?
    var onBack: (() -> Void)?
    let titleLabel: UILabel
    let messageLabel: UILabel
    let restoreButton = CCButton(title: "Restore", symbol: "clock.arrow.circlepath", style: .primary, size: .sm, radius: .full)
    let backButton = CCButton(title: "Back to Current", style: .secondary, size: .sm, radius: .full)

    init(title: String, message: String) {
        titleLabel = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
        messageLabel = ccLabel(message, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
        super.init(.raised, tint: CCTheme.color.popover, radius: .lg)
        let icon = CCIconView("info-fill", pointSize: 15, weight: .semibold, tint: CCTheme.color.primary)
        restoreButton.onTap = { [weak self] in self?.onRestore?() }
        backButton.onTap = { [weak self] in self?.onBack?() }
        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let top = UIStackView(arrangedSubviews: [icon, text])
        top.spacing = CCSpace.sm + 2
        top.alignment = .top
        let buttons = UIStackView(arrangedSubviews: [restoreButton, backButton])
        buttons.spacing = CCSpace.sm
        let column = UIStackView(arrangedSubviews: [top, buttons])
        column.axis = .vertical
        column.spacing = CCSpace.sm + 2
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.md),
            column.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.md),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.md),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        accessibilityElements = [titleLabel, messageLabel, restoreButton, backButton]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
