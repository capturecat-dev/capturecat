import UIKit

// Comment drawings in the share viewer: the canvas that paints them over the
// video frame, the drawing surface a viewer draws on while writing a comment
// (the web's AnnotationSurface), and its floating glass toolbar (the web's
// AnnotationToolbar). Geometry, canonical form and the draw plan all come
// from Core/ShareAnnotation.swift — the web's annotation.ts, ported and held
// to the web's own fixtures — so a drawing reads the same on every screen.
//
// The marks are CONTENT (they never retheme); the toolbar is floating chrome
// (CCGlassView), its keys house kit.

// MARK: - Renderer

enum ShareAnnotationRenderer {
    /// The label face: the web's "SF Pro Text" 600.
    static func labelFont(_ px: CGFloat) -> UIFont { .systemFont(ofSize: max(1, px), weight: .semibold) }

    static func measure(_ text: String, px: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: labelFont(px)]).width
    }

    /// "#rrggbb" or "rgba(r,g,b,a)".
    static func color(_ text: String) -> UIColor {
        if text.hasPrefix("rgba(") {
            let parts = text.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 { return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3]) }
        }
        return UIColor.ccHex(text) ?? .white
    }

    /// Paint `shapes` over `rect` (the video frame, in the context's points):
    /// the web renderer's calls, in its order, with its styles.
    static func draw(_ shapes: [ShareAnnotationShape], in ctx: CGContext, rect: CGRect, minStrokePx: CGFloat = 0, shadows: Bool = true) {
        let plan = ShareAnnotationMath.plan(shapes, rect: rect, minStrokePx: minStrokePx, shadows: shadows) { measure($0, px: $1) }
        for shape in plan {
            ctx.saveGState()
            ctx.setAlpha(shape.alpha)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let ink = color(shape.shape.color)
            ctx.setStrokeColor(ink.cgColor)
            if shape.shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: shape.shadowOffsetY), blur: shape.shadowBlur,
                              color: UIColor(white: 0, alpha: 0.38).cgColor)
            }
            var path = CGMutablePath()
            for op in shape.ops {
                switch op {
                case let .moveTo(p): path.move(to: p)
                case let .lineTo(p): path.addLine(to: p)
                case let .quad(c, p): path.addQuadCurve(to: p, control: c)
                case let .arc(c, r): path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                case let .ellipse(c, rx, ry): path.addEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                case let .rect(r): path.addRect(r)
                case let .roundRect(r, radius):
                    let k = min(radius, r.width / 2, r.height / 2)
                    path.addRoundedRect(in: r, cornerWidth: k, cornerHeight: k)
                case let .stroke(width):
                    ctx.addPath(path)
                    ctx.setLineWidth(width)
                    ctx.strokePath()
                    path = CGMutablePath()
                case let .fill(fill):
                    // Canvas keeps the path after fill() (the arrow head is
                    // stroked again, rounding its corners like the shaft).
                    path.closeSubpath()
                    ctx.addPath(path)
                    ctx.setFillColor(color(fill).cgColor)
                    ctx.fillPath()
                case let .fillText(text, at):
                    ctx.setShadow(offset: .zero, blur: 0, color: nil)
                    let font = labelFont(shape.fontPx)
                    // Canvas "top" baseline: the em box's top at y. UIKit
                    // draws from the line box's top; centre the em in it.
                    let y = at.y - (font.lineHeight - shape.fontPx) / 2
                    UIGraphicsPushContext(ctx)
                    (text as NSString).draw(at: CGPoint(x: at.x, y: y), withAttributes: [.font: font, .foregroundColor: ink])
                    UIGraphicsPopContext()
                }
            }
            ctx.restoreGState()
        }
    }
}

/// Paints shapes over the video frame. Its FRAME is the frame's rect (the
/// picture inside the player — letterboxed or fill-cropped), so it scales
/// with the picture when the player animates between fit and fill.
final class ShareAnnotationCanvas: UIView {
    var shapes: [ShareAnnotationShape] = [] { didSet { if shapes != oldValue { setNeedsDisplay() } } }
    var minStrokePx: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var shadows = true { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !shapes.isEmpty else { return }
        ShareAnnotationRenderer.draw(shapes, in: ctx, rect: bounds, minStrokePx: minStrokePx, shadows: shadows)
    }
}

/// A comment row's drawing preview: the marks on a dark plate shaped like the
/// video (the web's AnnotationThumb).
final class ShareAnnotationThumb: UIView {
    init(shapes: [ShareAnnotationShape], aspect: CGFloat, width: CGFloat = 64) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let height = min(width * aspect, width * 1.1)
        let canvas = ShareAnnotationCanvas()
        canvas.minStrokePx = 1.1
        canvas.shadows = false
        canvas.shapes = shapes
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(canvas)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: height)])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Editor state

/// Drawing state for one composer (the web's useAnnotationEditor): tool,
/// colour, size, the canonical shapes with undo / redo, the shape under the
/// finger and an open text label.
final class ShareDrawingEditor {
    var tool: ShareAnnotationShape.Kind = .pen { didSet { onChange?() } }
    var color: String { didSet { onChange?() } }
    var size = 2 { didSet { onChange?() } }
    private(set) var shapes: [ShareAnnotationShape] = []
    private(set) var past: [[ShareAnnotationShape]] = []
    private(set) var future: [[ShareAnnotationShape]] = []
    private(set) var initial: [ShareAnnotationShape] = []
    var draft: ShareAnnotationShape? { didSet { onChange?() } }
    var onChange: (() -> Void)?

    init(color: String) { self.color = color }

    var visibleShapes: [ShareAnnotationShape] { draft.map { shapes + [$0] } ?? shapes }

    func open(_ shapes: [ShareAnnotationShape]) {
        self.shapes = shapes
        initial = shapes
        past = []
        future = []
        draft = nil
    }

    #if DEBUG
    /// What fingers made, BEFORE canonicalising (ShareViewerGate hands these
    /// to the web's serializer and compares with what the app posted).
    var probeRawCommits: [ShareAnnotationShape] = []
    #endif

    /// Stored canonical, so the composer shows exactly what will be posted.
    func commit(_ shape: ShareAnnotationShape) {
        draft = nil
        #if DEBUG
        if shapes.count < ShareAnnotationMath.maxShapes, ShareAnnotationMath.canonicalShape(shape) != nil { probeRawCommits.append(shape) }
        #endif
        guard shapes.count < ShareAnnotationMath.maxShapes, let canonical = ShareAnnotationMath.canonicalShape(shape) else { return }
        record(shapes + [canonical])
    }

    private func record(_ next: [ShareAnnotationShape]) {
        past = Array((past + [shapes]).suffix(100))
        future = []
        shapes = next
        onChange?()
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.insert(shapes, at: 0)
        shapes = previous
        onChange?()
    }

    func redo() {
        guard !future.isEmpty else { return }
        past.append(shapes)
        shapes = future.removeFirst()
        onChange?()
    }

    func clear() { if !shapes.isEmpty { record([]) } }
}

// MARK: - Drawing surface (over the video)

/// Where a viewer draws: the frame dims a touch, an accent outline says "you
/// are drawing on THIS frame", one finger draws with the current tool (pen /
/// highlighter strokes, arrow / box / ellipse drags, a tap for a text label).
/// Points map through the VIDEO rect, never the box: a mark lands on the same
/// spot of the picture whether the player is letterboxed or fill-cropped.
/// A UIControl, so the player's own tap-to-play never fires underneath.
final class ShareDrawingSurface: UIControl, UITextFieldDelegate {
    let editor: ShareDrawingEditor
    /// The video frame in this view's coordinates (the surface's videoRect).
    var videoRect: () -> CGRect
    let canvas = ShareAnnotationCanvas()
    private let dim = UIView()
    private let outline = CAShapeLayer()
    let timeBadge = PaddedLabel()
    private(set) var labelField: CCField?
    private var labelAt: CGPoint?
    private var activeTouch: UITouch?
    private let accent: String

    init(editor: ShareDrawingEditor, accent: String, time: Double, videoRect: @escaping () -> CGRect) {
        self.editor = editor
        self.accent = accent
        self.videoRect = videoRect
        super.init(frame: .zero)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        dim.isUserInteractionEnabled = false
        addSubview(dim)
        addSubview(canvas)
        outline.fillColor = nil
        outline.lineWidth = 2
        outline.strokeColor = ShareAnnotationRenderer.color(accent).cgColor
        layer.addSublayer(outline)
        timeBadge.text = "Drawing at \(Format.duration(time))"
        timeBadge.font = CCFont.micro
        timeBadge.textColor = UIColor.white.withAlphaComponent(0.85)
        timeBadge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        timeBadge.layer.cornerRadius = 11
        timeBadge.clipsToBounds = true
        timeBadge.isAccessibilityElement = false
        addSubview(timeBadge)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Drawing on the video frame at \(Format.spokenDuration(time))"
        accessibilityHint = "Draw with one finger. Pick a tool, colour and size below."
        accessibilityTraits = .allowsDirectInteraction
        editor.onChange = { [weak self] in self?.refresh() }
        if !CCMotion.reduceMotion { CCMotion.fade(layer, keyPath: "opacity", to: 1, duration: 0.22, from: 0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dim.frame = bounds
        let rect = videoRect()
        canvas.frame = rect
        outline.path = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3).cgPath
        let visible = rect.intersection(bounds)
        let size = timeBadge.intrinsicContentSize
        timeBadge.frame = CGRect(x: visible.minX + CCSpace.md, y: visible.minY + CCSpace.md, width: size.width, height: 22)
        if let field = labelField, let at = labelAt { field.frame = labelFrame(at: at, in: rect) }
    }

    func refresh() { canvas.shapes = editor.visibleShapes }

    private func point(_ touch: UITouch) -> CGPoint {
        let rect = videoRect()
        // Normalized to the frame (the canvas's own space is the frame).
        return ShareAnnotationMath.toFrame(touch.location(in: self), rect: rect)
    }

    /// The probe path: a stroke through `points` (normalized), as fingers do.
    func probeDraw(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        begin(at: first)
        for p in points.dropFirst() { move(to: p) }
        end()
    }

    private func begin(at p: CGPoint) {
        if labelField != nil { commitLabel() }
        if editor.tool == .text { openLabel(at: p); return }
        let base = (editor.color, editor.size)
        switch editor.tool {
        case .pen, .highlight: editor.draft = .stroke(kind: editor.tool, color: base.0, size: base.1, points: [p])
        default: editor.draft = .box(kind: editor.tool, color: base.0, size: base.1, from: p, to: p)
        }
    }

    private func move(to p: CGPoint) {
        guard let draft = editor.draft else { return }
        switch draft {
        case let .stroke(_, _, _, points):
            let rect = videoRect()
            let minStep = rect.width > 0 ? 0.8 / rect.width : 0  // ~0.8 pt, the web's
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= minStep { editor.draft = draft.appending(p) }
        case .box: editor.draft = draft.with(to: p)
        case .text: break
        }
    }

    private func end(cancelled: Bool = false) {
        guard let draft = editor.draft else { return }
        if cancelled { editor.draft = nil } else { editor.commit(draft) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        begin(at: point(touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] { move(to: point(sample)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        move(to: point(touch))
        end()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        end(cancelled: true)
    }

    // MARK: Text labels

    private func labelFrame(at p: CGPoint, in rect: CGRect) -> CGRect {
        let m = ShareAnnotationMath.labelMetrics(size: editor.size, rect: rect)
        let origin = ShareAnnotationMath.toBox(p, rect: rect)
        let width = min(220, max(140, rect.maxX - origin.x))
        return CGRect(x: min(origin.x, bounds.width - width), y: min(origin.y, bounds.height - 40), width: width, height: max(36, m.lineHeight + m.padY * 2))
    }

    func openLabel(at p: CGPoint) {
        let field = CCField(placeholder: "Label")
        field.returnKeyType = .done
        field.accessibilityLabel = "Text label"
        field.delegate = self
        field.onReturn = { [weak self] _ in self?.commitLabel() }
        labelAt = p
        labelField = field
        addSubview(field)
        field.frame = labelFrame(at: p, in: videoRect())
        _ = field.becomeFirstResponder()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let next = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
        return next.unicodeScalars.count <= ShareAnnotationMath.maxTextLength
    }

    /// Commit the open label (if it has text) and close the field.
    func commitLabel() {
        guard let field = labelField, let at = labelAt else { return }
        labelField = nil
        labelAt = nil
        let text = field.text ?? ""
        field.removeFromSuperview()
        editor.commit(.text(color: editor.color, size: editor.size, at: at, text: text))
    }

    #if DEBUG
    /// A point in this view → normalized frame coordinates (the touch path's mapping).
    func probeNormalized(_ point: CGPoint) -> CGPoint { ShareAnnotationMath.toFrame(point, rect: videoRect()) }
    #endif

    /// Done: the open label commits, the shapes are the drawing.
    func finish() -> [ShareAnnotationShape] {
        commitLabel()
        return editor.shapes
    }
}

// MARK: - Toolbar (floating glass)

/// Tools, colours, size, undo / redo, Cancel and Done — the web's
/// AnnotationToolbar, as floating glass chrome docked under the frame
/// (portrait) or over the bottom of the full-width player (landscape).
final class ShareDrawingToolbar: UIView {
    let glass = CCGlassView(shape: .rounded(.lg))
    let titleLabel = ccLabel("", font: CCFont.captionMedium, color: CCTheme.color.foreground)
    let cancelButton = CCButton(title: "Cancel", style: .ghost, size: .sm, radius: .full)
    let doneButton = CCButton(title: "Done", style: .primary, size: .sm, radius: .full)
    let undoButton = CCButton(symbol: "undo", style: .ghost, size: .regular, radius: .full)
    let redoButton = CCButton(symbol: "redo", style: .ghost, size: .regular, radius: .full)
    let sizeButton = CCButton(title: "M", style: .ghost, size: .regular, radius: .full)
    private(set) var toolButtons: [(ShareAnnotationShape.Kind, CCButton)] = []
    private(set) var swatches: [CCColorSwatch] = []
    private let editor: ShareDrawingEditor
    private let palette: [String]

    static let tools: [(ShareAnnotationShape.Kind, String, String)] = [
        (.pen, "pencil", "Pen"), (.highlight, "highlighter", "Highlighter"), (.arrow, "arrow-up-right", "Arrow"),
        (.rect, "rectangle", "Rectangle"), (.ellipse, "ellipse", "Ellipse"), (.text, "text", "Text"),
    ]
    private static let colorNames = ["#ef4444": "Red", "#3b82f6": "Blue", "#22c55e": "Green", "#ffffff": "White", "#111111": "Black", "#fbbf24": "Amber"]

    init(editor: ShareDrawingEditor, accent: String, time: Double) {
        self.editor = editor
        palette = ShareAnnotationMath.palette(accent: accent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Drawing at \(Format.duration(time))"
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undoButton.accessibilityLabelOverride = "Undo"
        redoButton.accessibilityLabelOverride = "Redo"
        sizeButton.accessibilityLabelOverride = "Mark size"
        cancelButton.accessibilityHint = "Puts the drawing back the way it was"
        doneButton.accessibilityHint = "Keeps the drawing with your comment"
        let header = UIStackView(arrangedSubviews: [cancelButton, titleLabel, undoButton, redoButton, doneButton])
        header.spacing = CCSpace.xs
        header.alignment = .center
        header.setCustomSpacing(CCSpace.sm, after: cancelButton)
        header.setCustomSpacing(CCSpace.sm, after: redoButton)

        toolButtons = Self.tools.map { kind, symbol, name in
            let key = CCButton(symbol: symbol, style: .ghost, size: .regular, radius: .full)
            key.accessibilityLabelOverride = name
            key.onTap = { [weak self] in
                self?.editor.tool = kind
                CCHaptics.selection()
            }
            return (kind, key)
        }
        let tools = UIStackView(arrangedSubviews: toolButtons.map(\.1))
        tools.distribution = .equalSpacing
        tools.alignment = .center

        swatches = palette.map { hex in
            let swatch = CCColorSwatch(preset: CCColorPreset(name: Self.colorNames[hex] ?? hex, color: UIColor.ccHex(hex) ?? .white))
            swatch.onPick = { [weak self] _ in self?.editor.color = hex }
            return swatch
        }
        sizeButton.onTap = { [weak self] in
            guard let self else { return }
            self.editor.size = self.editor.size % 3 + 1
            CCHaptics.selection()
        }
        let colors = UIStackView(arrangedSubviews: swatches + [sizeButton])
        colors.distribution = .equalSpacing
        colors.alignment = .center

        undoButton.onTap = { [weak self] in self?.editor.undo() }
        redoButton.onTap = { [weak self] in self?.editor.redo() }

        let stack = UIStackView(arrangedSubviews: [header, tools, colors])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: CCSpace.sm),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -CCSpace.sm),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: CCSpace.sm),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -CCSpace.sm),
            widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refresh() {
        for (kind, key) in toolButtons {
            let on = kind == editor.tool
            if (key.style == .secondary) != on { key.style = on ? .secondary : .ghost }
            key.accessibilityTraits = on ? [.button, .selected] : .button
        }
        for (hex, swatch) in zip(palette, swatches) { swatch.isSelected = hex == editor.color.lowercased() }
        sizeButton.title = ["S", "M", "L"][max(0, min(2, editor.size - 1))]
        sizeButton.accessibilityValue = ["Small", "Medium", "Large"][max(0, min(2, editor.size - 1))]
        undoButton.isEnabled = !editor.past.isEmpty
        redoButton.isEnabled = !editor.future.isEmpty
    }

    /// Grows in at its top edge (the edge that meets the frame) on the bounce.
    func enter() {
        guard !CCMotion.reduceMotion else { return }
        CCMotion.spring(layer, keyPath: "transform.translation.y", from: -10, to: 0, .bouncy)
        CCMotion.fade(layer, keyPath: "opacity", to: 1, duration: 0.18, from: 0)
    }
}

// MARK: - "Whose drawing" pill

/// Over a shown drawing: who drew it and when, with a key to put it away —
/// or, for the composer's own unposted drawing, "not posted yet" + Edit.
final class ShareDrawingPill: UIView {
    let glass = CCGlassView(shape: .capsule)
    let label = ccLabel("", font: CCFont.captionMedium, color: CCTheme.color.foreground)
    let actionButton: CCButton

    init(text: String, action: CCButton) {
        actionButton = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, action])
        row.spacing = CCSpace.xs
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: CCSpace.md),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -2),
        ])
        isAccessibilityElement = false
        label.accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
