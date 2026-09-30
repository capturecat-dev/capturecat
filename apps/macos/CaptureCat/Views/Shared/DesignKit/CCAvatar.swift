import AppKit

/// CCKit avatar — shadcn's Avatar: a round face showing an image, or the
/// person's initials on a DETERMINISTIC hue derived from their name (the same
/// name always gets the same color, across launches). An optional status dot
/// sits at the lower right, cut out of the face by a ring of the surface
/// color; `.live` breathes a soft pulse.
///
///     let me = CCAvatar(name: "Mike Garland")                    // "MG" on its hue
///     let pic = CCAvatar(name: "Ada", image: photo, size: .lg, status: .online)
///
/// The image is CONTENT and never themes; the initials disc, ring and status
/// chrome all re-apply live on theme change.
@MainActor
final class CCAvatar: NSView {
    enum Size {
        case sm
        case md
        case lg
        case xl

        var side: CGFloat {
            switch self {
            case .sm: return 24
            case .md: return 32
            case .lg: return 40
            case .xl: return 56
            }
        }
    }

    enum Status {
        case online
        case away
        case busy
        case offline
        /// Recording/streaming — the dot breathes a soft pulse.
        case live
    }

    let name: String
    let size: Size

    var image: NSImage? {
        didSet { refreshFace() }
    }

    var status: Status? {
        didSet { refreshStatus() }
    }

    /// Ring drawn around the face in `ringColor` (default: the window
    /// background). Groups use it as the "gap" between overlapping faces.
    var ringWidth: CGFloat = 0 {
        didSet { applyTheme() }
    }

    /// The surface the avatar sits on — the ring and the status dot's
    /// cut-out use it. nil = `CCTheme.color.background`.
    var ringColor: NSColor? {
        didSet { applyTheme() }
    }

    /// Leaf host for the face material / image layer.
    private let face = NSView()
    private let imageLayer = CALayer()
    private let initialsField = NSTextField(labelWithString: "")
    /// Leaf host for the status dot + its pulse halo.
    private let statusHost = NSView()
    private let statusDot = CALayer()
    private let pulse = CALayer()
    /// "+N" overflow chips reuse the avatar chrome with a neutral disc.
    private let isOverflowChip: Bool
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { NSSize(width: size.side, height: size.side) }

    init(name: String, image: NSImage? = nil, size: Size = .md, status: Status? = nil) {
        self.name = name
        self.image = image
        self.size = size
        self.status = status
        isOverflowChip = false
        super.init(frame: .zero)
        build()
    }

    /// The "+N" chip a group shows for hidden members.
    init(overflow count: Int, size: Size) {
        name = "+\(count)"
        image = nil
        self.size = size
        status = nil
        isOverflowChip = true
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        wantsLayer = true
        face.wantsLayer = true
        face.layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        face.layer?.addSublayer(imageLayer)

        initialsField.alignment = .center
        initialsField.stringValue = isOverflowChip ? name : Self.initials(for: name)

        statusHost.wantsLayer = true
        pulse.opacity = 0
        statusHost.layer?.addSublayer(pulse)
        statusHost.layer?.addSublayer(statusDot)

        for view in [face, initialsField, statusHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let side = size.side
        let dot = Self.statusSide(for: side)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.trailingAnchor.constraint(equalTo: trailingAnchor),
            face.topAnchor.constraint(equalTo: topAnchor),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
            initialsField.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsField.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusHost.widthAnchor.constraint(equalToConstant: dot),
            statusHost.heightAnchor.constraint(equalToConstant: dot),
            // Sits on the circle's lower-right edge (45°), overhanging it.
            statusHost.centerXAnchor.constraint(equalTo: leadingAnchor, constant: side * 0.854),
            statusHost.centerYAnchor.constraint(equalTo: topAnchor, constant: side * 0.854),
        ])
        refreshFace()
        refreshStatus()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    static func statusSide(for side: CGFloat) -> CGFloat { max(8, (side * 0.28).rounded()) }

    /// First letters of the first two words ("Mike Garland" → "MG").
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Stable hue in [0, 1) from the name — FNV-1a, never `hashValue`
    /// (Swift's hash is randomized per launch; colors would reshuffle).
    static func hue(for name: String) -> CGFloat {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return CGFloat(hash % 360) / 360
    }

    /// The initials disc color — same hue per name, tuned per theme so the
    /// white initials keep their contrast on dark and light surfaces.
    static func discColor(for name: String) -> NSColor {
        let color = NSColor(
            hue: hue(for: name),
            saturation: CCTheme.isDark ? 0.5 : 0.44,
            brightness: CCTheme.isDark ? 0.62 : 0.74,
            alpha: 1
        )
        return color.usingColorSpace(.sRGB) ?? color
    }

    override func layout() {
        super.layout()
        let side = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.layer?.cornerRadius = CCRadius.full.resolved(for: side)
        imageLayer.frame = face.bounds
        imageLayer.cornerRadius = CCRadius.full.resolved(for: side)
        let dot = statusHost.bounds
        statusDot.frame = dot
        statusDot.cornerRadius = dot.height / 2
        pulse.frame = dot
        pulse.cornerRadius = dot.height / 2
        CATransaction.commit()
        if let layer = face.layer, image == nil {
            CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: side))
        }
    }

    private func refreshFace() {
        imageLayer.contents = image
        imageLayer.isHidden = image == nil
        initialsField.isHidden = image != nil
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-arm the live pulse after re-hosting (a moved layer tree can
        // come back with its animations dropped).
        if window != nil, status == .live, pulse.animation(forKey: "ccavatar.pulse") == nil {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        statusHost.isHidden = status == nil
        applyTheme()
        pulse.removeAnimation(forKey: "ccavatar.pulse")
        guard status == .live else { return }
        // A soft halo breathes OUT of the dot: grows and fades, forever.
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.6
        group.timingFunction = CCMotion.settle
        group.repeatCount = .infinity
        pulse.add(group, forKey: "ccavatar.pulse")
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let surface = ringColor ?? colors.background
        let side = size.side
        guard let faceLayer = face.layer else { return }
        faceLayer.borderWidth = ringWidth
        faceLayer.borderColor = surface.cgColor
        if image != nil {
            // Content: a neutral placeholder under transparent images only.
            CCMaterial.strip(faceLayer)
            faceLayer.backgroundColor = colors.elevated.cgColor
        } else {
            let disc = isOverflowChip ? colors.elevated : Self.discColor(for: name)
            faceLayer.backgroundColor = disc.cgColor
            // Skeuo: the initials disc is a raised matte bead (no cast
            // shadow — packed groups would smear it across neighbors).
            CCMaterial.dress(faceLayer, as: .raisedMatte(tint: disc),
                             radius: CCRadius.full.resolved(for: side))
        }
        initialsField.font = NSFont.systemFont(ofSize: (side * (isOverflowChip ? 0.34 : 0.38)).rounded(),
                                               weight: .semibold)
        initialsField.textColor = isOverflowChip
            ? colors.mutedForeground
            : NSColor.white.withAlphaComponent(0.96)

        let statusColor: NSColor
        switch status {
        case .online: statusColor = .systemGreen
        case .away: statusColor = .systemOrange
        case .busy, .live: statusColor = colors.destructive
        case .offline, .none: statusColor = colors.faintForeground
        }
        statusDot.backgroundColor = statusColor.cgColor
        // The cut-out: a ring of the surface color separates dot and face.
        statusDot.borderWidth = 2
        statusDot.borderColor = surface.cgColor
        pulse.backgroundColor = statusColor.cgColor
    }

    // MARK: - Harness seams

    var probeFaceLayer: CALayer? { face.layer }
    var probePulseLayer: CALayer { pulse }
    var probeStatusDot: CALayer { statusDot }
}

/// CCKit avatar group — overlapping faces separated by a ring gap in the
/// surface color, with a "+N" chip for members past `maxVisible`. Hovering
/// the group lifts the overlap slightly so the faces spring apart (the space
/// is reserved, so neighbors never reflow).
///
///     let team = CCAvatarGroup(names: ["Ada Lovelace", "Alan Turing", "Grace Hopper",
///                                       "Linus T", "Margaret H"], maxVisible: 3)
@MainActor
final class CCAvatarGroup: NSView {
    let size: CCAvatar.Size
    private(set) var avatars: [CCAvatar] = []
    private var overflowChip: CCAvatar?
    private var isSpread = false
    private var trackingArea: NSTrackingArea?

    /// Face-to-face step at rest vs. hover, as a fraction of the diameter.
    private static let restStep: CGFloat = 0.74
    private static let spreadStep: CGFloat = 0.9

    /// Surface the group sits on — the ring gap and status cut-outs use it.
    var ringColor: NSColor? {
        didSet { members.forEach { $0.ringColor = ringColor } }
    }

    private var members: [CCAvatar] { avatars + (overflowChip.map { [$0] } ?? []) }

    override var intrinsicContentSize: NSSize {
        // Reserve the SPREAD width: hovering never pushes neighbors around.
        let count = CGFloat(max(members.count, 1))
        let side = size.side
        return NSSize(width: side + (count - 1) * side * Self.spreadStep, height: side)
    }

    convenience init(names: [String], maxVisible: Int = 4, size: CCAvatar.Size = .md) {
        self.init(people: names.map { (name: $0, image: nil as NSImage?) }, maxVisible: maxVisible, size: size)
    }

    init(people: [(name: String, image: NSImage?)], maxVisible: Int = 4, size: CCAvatar.Size = .md) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        let visible = people.count > maxVisible ? max(maxVisible - 1, 1) : people.count
        for person in people.prefix(visible) {
            let avatar = CCAvatar(name: person.name, image: person.image, size: size)
            avatar.ringWidth = 2
            // Frames are ours (manual layout) — later faces stack on top.
            avatar.translatesAutoresizingMaskIntoConstraints = true
            addSubview(avatar)
            avatars.append(avatar)
        }
        if people.count > visible {
            let chip = CCAvatar(overflow: people.count - visible, size: size)
            chip.ringWidth = 2
            chip.translatesAutoresizingMaskIntoConstraints = true
            addSubview(chip)
            overflowChip = chip
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func frame(at index: Int, spread: Bool) -> NSRect {
        let side = size.side
        let step = side * (spread ? Self.spreadStep : Self.restStep)
        return NSRect(x: CGFloat(index) * step, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func layout() {
        super.layout()
        // Idempotent: frames always reflect the current state; the hover
        // transition's springs ride on top as FLIP offsets.
        for (index, member) in members.enumerated() {
            let target = frame(at: index, spread: isSpread)
            if member.frame != target { member.frame = target }
        }
    }

    /// Spread (hover) or rest. Also the harness seam — the tracking area
    /// below feeds it in production.
    func setSpread(_ spread: Bool) {
        guard spread != isSpread else { return }
        isSpread = spread
        for (index, member) in members.enumerated() {
            CCMotion.glide(member, to: frame(at: index, spread: spread), spread ? .bouncy : .smooth)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setSpread(true) }
    override func mouseExited(with event: NSEvent) { setSpread(false) }

    // MARK: - Harness seams

    var probeMembers: [CCAvatar] { members }
}
