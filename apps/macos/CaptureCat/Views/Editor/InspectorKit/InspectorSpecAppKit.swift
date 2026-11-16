import AppKit

// InspectorKit controls built from the shared inspector specs
// (Studio/Editor/Inspector). A pane makes each control from its spec — the
// title, range, step, readout and items come from the one shared copy — and
// wires the control's callback to the spec's write. Every control also takes
// the spec's id as its `identifier`, which the `--inspector-values-test`
// harness addresses it by.

extension NSView {
    /// The shared spec id this control was built from (nil for chrome).
    var inspectorSpecID: String? {
        get { identifier?.rawValue }
        set { identifier = newValue.map { NSUserInterfaceItemIdentifier($0) } }
    }
}

extension InspectorSliderRow {
    convenience init(_ spec: InspectorSlider) {
        self.init(label: spec.title, range: spec.range, step: spec.step)
        format = spec.format
        inspectorSpecID = spec.id
    }

    /// onChange → the spec's write, through the pane's current scope.
    func bind(_ spec: InspectorSlider, _ scope: @escaping () -> InspectorScope?) {
        onChange = { v in
            guard let s = scope() else { return }
            spec.write(s, v)
        }
    }
}

extension InspectorToggleControl {
    convenience init(_ spec: InspectorToggle) {
        self.init(spec.title)
        inspectorSpecID = spec.id
    }

    func bind(_ spec: InspectorToggle, _ scope: @escaping () -> InspectorScope?) {
        onChange = { on in
            guard let s = scope() else { return }
            spec.write(s, on)
        }
    }
}

extension InspectorChipsControl {
    convenience init(_ spec: InspectorChoice) {
        self.init()
        // Through a method: an assignment in an initializer skips `didSet`,
        // and `items`' didSet is what builds the chips.
        assignItems(spec.items)
        inspectorSpecID = spec.id
    }

    private func assignItems(_ items: [String]) { self.items = items }

    func bind(_ spec: InspectorChoice, _ scope: @escaping () -> InspectorScope?) {
        onSelect = { index in
            guard let s = scope() else { return }
            spec.write(s, index)
        }
    }
}

extension InspectorMenuControl {
    convenience init(_ spec: InspectorChoice) {
        self.init()
        // Through a method, so `items`' didSet (the title refresh) runs.
        assignItems(spec.items.map { .init(title: $0) })
        inspectorSpecID = spec.id
    }

    private func assignItems(_ items: [Item]) { self.items = items }

    func bind(_ spec: InspectorChoice, _ scope: @escaping () -> InspectorScope?) {
        onSelect = { index in
            guard let s = scope() else { return }
            spec.write(s, index)
        }
    }
}

extension InspectorButton {
    convenience init(_ spec: InspectorAction, initialTitle: String? = nil) {
        self.init(initialTitle ?? Self.staticTitle(spec), destructive: spec.destructive)
        inspectorSpecID = spec.id
    }

    func bind(_ spec: InspectorAction, _ scope: @escaping () -> InspectorScope?) {
        onClick = {
            guard let s = scope() else { return }
            spec.run(s)
        }
    }

    /// The title a spec shows with no target — fixed titles ignore the scope.
    private static func staticTitle(_ spec: InspectorAction) -> String {
        spec.title(InspectorScope(settings: ProjectSettings()))
    }
}

extension InspectorColorWellControl {
    /// getColor/setColor through the spec (sRGB both ways, the house rule).
    /// `requireSRGB`: drop a pick that has no sRGB form instead of storing
    /// its raw components (the Background and Cursor wells always did).
    func bind(_ spec: InspectorColor, _ scope: @escaping () -> InspectorScope?,
              fallback: NSColor = .white, requireSRGB: Bool = false) {
        inspectorSpecID = spec.id
        supportsOpacity = spec.supportsOpacity
        getColor = {
            guard let s = scope() else { return fallback }
            return spec.read(s).nsColor
        }
        setColor = { color in
            guard let s = scope() else { return }
            if requireSRGB {
                guard let srgb = color.usingColorSpace(.sRGB) else { return }
                spec.write(s, CodableColor(srgb))
            } else {
                spec.write(s, CodableColor(color))
            }
        }
    }
}

extension InspectorFlatTextField {
    convenience init(_ spec: InspectorText, width: CGFloat? = nil) {
        self.init(placeholder: spec.placeholder, width: width)
        inspectorSpecID = spec.id
    }
}

extension InspectorKitViews {
    /// One-line caption (full story in the tooltip) from a shared caption.
    static func captionLine(_ caption: InspectorCaption) -> NSTextField {
        let field = captionLine(caption.fixed ?? "", full: caption.full)
        field.inspectorSpecID = caption.id
        return field
    }

    /// Wrapping caption from a shared caption.
    static func caption(_ caption: InspectorCaption) -> NSTextField {
        let field = self.caption(caption.fixed ?? "")
        field.inspectorSpecID = caption.id
        return field
    }
}

extension MotionPaneContext {
    /// A context that only answers the Slide join — what the project-wide
    /// Effects list needs from the selection.
    static func joinOnly(_ join: @escaping () -> Bool) -> MotionPaneContext {
        MotionPaneContext(
            highlightRegion: .constant(nil), onDeleteHighlight: {},
            tiltRegion: .constant(nil), onDeleteTilt: {},
            zoomRegion: .constant(nil), onDeleteZoom: {},
            onAddTiltToBlock: {}, onAddZoomToBlock: {},
            onJoinSlideToSelectedBlock: join)
    }
}
