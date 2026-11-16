import Foundation

/// Annotate tab — the selected annotation: header with an undoable Delete,
/// per-type Text / Tap / Style sections, Effects (opacity, blackout, build
/// in/out, shadow), drawing strokes, Timing. Moved verbatim from
/// AnnotationSettingsPaneAppKit (Studio 4d). Every write goes through
/// `mutate`, which edits the selected annotation in place.
@MainActor
enum AnnotationPane {
    typealias Scope = InspectorScope

    static func selectedIndex(_ s: Scope) -> Int? {
        guard let project = s.project, let id = s.annotate?.selectedAnnotationID.wrappedValue else { return nil }
        return project.annotations.firstIndex(where: { $0.id == id })
    }
    static func selected(_ s: Scope) -> Annotation? {
        selectedIndex(s).flatMap { s.project?.annotations[$0] }
    }
    static func mutate(_ s: Scope, _ change: (inout Annotation) -> Void) {
        guard let project = s.project, let idx = selectedIndex(s) else { return }
        var annotation = project.annotations[idx]
        change(&annotation)
        project.annotations[idx] = annotation
    }

    static func hasSelection(_ s: Scope) -> Bool { selectedIndex(s) != nil }
    private static func type(_ s: Scope) -> AnnotationType? { selected(s)?.type }
    static func isText(_ s: Scope) -> Bool { type(s) == .text || type(s) == .callout }
    static func isTap(_ s: Scope) -> Bool { type(s) == .tap }
    static func isDrawing(_ s: Scope) -> Bool { type(s) == .drawing }
    static func hasFill(_ s: Scope) -> Bool { isText(s) || type(s) == .rectangle || type(s) == .ellipse }
    static func hasBorder(_ s: Scope) -> Bool {
        let t = type(s)
        return t == .arrow || t == .drawing || t == .rectangle || t == .ellipse
    }

    static func name(for type: AnnotationType) -> String {
        switch type {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .callout: return "Callout"
        case .drawing: return "Drawing"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .tap: return "Tap Indicator"
        }
    }

    static func icon(for type: AnnotationType) -> String {
        switch type {
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .callout: return "bubble.left"
        case .drawing: return "scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .tap: return "hand.tap"
        }
    }

    // MARK: Header

    /// Undoable: the removed annotation comes back on undo.
    static let delete = InspectorAction(
        id: "annotate.delete", title: "Delete", destructive: true,
        run: { scope in
            guard let project = scope.project, let idx = selectedIndex(scope) else { return }
            let removed = project.annotations[idx]
            project.annotations.remove(at: idx)
            scope.annotate?.selectedAnnotationID.wrappedValue = nil
            scope.annotate?.undoManager?.registerUndo(withTarget: project) { p in
                p.annotations.append(removed)
            }
            scope.annotate?.undoManager?.setActionName("Delete Annotation")
        },
        visible: hasSelection)

    // MARK: Text

    static let text = InspectorText(
        id: "annotate.text", title: "Text", placeholder: "Label", commit: .onEnd,
        read: { selected($0)?.text ?? "" }, write: { scope, v in mutate(scope) { $0.text = v } },
        visible: isText)
    static let fontSize = InspectorSlider(
        id: "annotate.fontSize", title: "Size", range: 10...72, step: 1,
        read: { selected($0)?.fontSize ?? 24 }, write: { scope, v in mutate(scope) { $0.fontSize = v } },
        visible: isText)
    static let font = InspectorChoice(
        id: "annotate.font", title: "Font", style: .menu, items: FontCatalog.menuNames,
        read: { FontCatalog.menuIndex(for: selected($0)?.fontName) },
        write: { scope, i in mutate(scope) { $0.fontName = FontCatalog.storedName(forMenuIndex: i) } },
        visible: isText)
    static let weight = InspectorChoice(
        id: "annotate.weight", title: "Weight", style: .chips,
        items: ProjectSettings.SubtitleWeight.allCases.map(\.rawValue),
        read: { scope in selected(scope).flatMap { ProjectSettings.SubtitleWeight.allCases.firstIndex(of: $0.fontWeight) } },
        write: { scope, index in
            let all = ProjectSettings.SubtitleWeight.allCases
            guard all.indices.contains(index) else { return }
            mutate(scope) { $0.fontWeight = all[index] }
        },
        visible: isText)
    static let uppercase = InspectorToggle(
        id: "annotate.uppercase", title: "Uppercase",
        read: { selected($0)?.uppercase ?? false }, write: { scope, on in mutate(scope) { $0.uppercase = on } },
        visible: isText)

    // MARK: Tap

    static let tapSize = InspectorSlider(
        id: "annotate.tapSize", title: "Size", range: 20...120, step: 5,
        read: { selected($0)?.fontSize ?? 44 }, write: { scope, v in mutate(scope) { $0.fontSize = v } },
        visible: isTap)

    // MARK: Style

    static let color = InspectorColor(
        id: "annotate.color", title: "Color",
        read: { selected($0)?.color ?? SystemColorDefaults.white },
        write: { scope, c in mutate(scope) { $0.color = c } },
        visible: hasSelection)
    /// "Fill" for shapes, "Background" for text.
    static func fillTitle(_ s: Scope) -> String {
        (type(s) == .rectangle || type(s) == .ellipse) ? "Fill" : "Background"
    }
    static let fillToggle = InspectorToggle(
        id: "annotate.fill", title: "Background",
        read: { selected($0)?.showBackground ?? false },
        write: { scope, on in mutate(scope) { $0.showBackground = on } },
        visible: hasFill)
    static let fillColor = InspectorColor(
        id: "annotate.fillColor", title: "Background",
        read: { selected($0)?.backgroundColor ?? SystemColorDefaults.black },
        write: { scope, c in mutate(scope) { $0.backgroundColor = c } },
        visible: { hasFill($0) && (selected($0)?.showBackground ?? false) })
    static let corners = InspectorSlider(
        id: "annotate.corners", title: "Corners", range: 0...24, step: 1,
        read: { selected($0)?.cornerRadius ?? 0 }, write: { scope, v in mutate(scope) { $0.cornerRadius = v } },
        visible: { isText($0) || type($0) == .rectangle })
    static let border = InspectorSlider(
        id: "annotate.border", title: "Border", range: 0...12, step: 0.5,
        rangeFor: { isDrawing($0) ? 1...30 : 0...12 },
        read: { selected($0)?.lineWidth ?? 0 }, write: { scope, v in mutate(scope) { $0.lineWidth = v } },
        visible: hasBorder)

    // MARK: Effects

    static let opacity = InspectorSlider(
        id: "annotate.opacity", title: "Opacity", range: 0.2...1.0, step: 0.05,
        format: InspectorFormat.percent,
        read: { selected($0)?.opacity ?? 1 }, write: { scope, v in mutate(scope) { $0.opacity = v } },
        visible: hasSelection)
    /// Below the first stop reads (and writes) as Off.
    static let blackout = InspectorSlider(
        id: "annotate.blackout", title: "Blackout", range: 0...0.9, step: 0.05,
        format: { $0 < 0.026 ? "Off" : "\(Int(($0 * 100).rounded()))%" },
        read: { selected($0)?.backdropOpacity ?? 0 },
        write: { scope, v in mutate(scope) { $0.backdropOpacity = v < 0.026 ? 0 : v } },
        visible: hasSelection)
    static let buildIn = InspectorChoice(
        id: "annotate.buildIn", title: "Build In", style: .menu,
        items: AnnotationEffect.allCases.map(\.rawValue),
        read: { scope in selected(scope).flatMap { AnnotationEffect.allCases.firstIndex(of: $0.enterEffect) } },
        write: { scope, index in
            let all = AnnotationEffect.allCases
            guard all.indices.contains(index) else { return }
            mutate(scope) { $0.enterEffect = all[index] }
        },
        visible: hasSelection)
    static let buildOut = InspectorChoice(
        id: "annotate.buildOut", title: "Build Out", style: .menu,
        items: AnnotationEffect.allCases.map(\.rawValue),
        read: { scope in selected(scope).flatMap { AnnotationEffect.allCases.firstIndex(of: $0.exitEffect) } },
        write: { scope, index in
            let all = AnnotationEffect.allCases
            guard all.indices.contains(index) else { return }
            mutate(scope) { $0.exitEffect = all[index] }
        },
        visible: hasSelection)
    static let shadow = InspectorToggle(
        id: "annotate.shadow", title: "Shadow",
        read: { selected($0)?.showShadow ?? false }, write: { scope, on in mutate(scope) { $0.showShadow = on } },
        visible: { hasSelection($0) && !isTap($0) })

    // MARK: Drawing

    static func strokeCount(_ s: Scope) -> Int { selected(s)?.drawingStrokes.count ?? 0 }
    static func strokesText(_ s: Scope) -> String {
        let strokes = strokeCount(s)
        return "\(strokes) stroke\(strokes == 1 ? "" : "s")"
    }
    static let undoStroke = InspectorAction(
        id: "annotate.undoStroke", title: "Undo Last",
        run: { scope in
            mutate(scope) {
                guard !$0.drawingStrokes.isEmpty else { return }
                $0.drawingStrokes.removeLast()
            }
        },
        visible: { isDrawing($0) && strokeCount($0) > 0 })
    static let clearStrokes = InspectorAction(
        id: "annotate.clearStrokes", title: "Clear", destructive: true,
        run: { scope in mutate(scope) { $0.drawingStrokes = [] } },
        visible: { isDrawing($0) && strokeCount($0) > 0 })

    // MARK: Timing

    /// Typed times commit on end editing; an unparseable entry is ignored.
    static let start = InspectorText(
        id: "annotate.start", title: "Start", placeholder: "0.00", commit: .onEnd,
        read: { String(format: "%.2f", selected($0)?.startTime ?? 0) },
        write: { scope, text in
            guard let value = Double(text) else { return }
            mutate(scope) { $0.startTime = max(0, value) }
        },
        visible: hasSelection)
    static let end = InspectorText(
        id: "annotate.end", title: "End", placeholder: "0.00", commit: .onEnd,
        read: { String(format: "%.2f", selected($0)?.endTime ?? 0) },
        write: { scope, text in
            guard let value = Double(text) else { return }
            mutate(scope) { $0.endTime = max($0.startTime + 0.5, value) }
        },
        visible: hasSelection)
    static let atPlayhead = InspectorAction(
        id: "annotate.atPlayhead", title: "At Playhead",
        run: { scope in
            guard let project = scope.project else { return }
            let time = scope.annotate?.currentTime ?? 0
            let duration = project.duration
            mutate(scope) {
                $0.startTime = max(0, time)
                $0.endTime = min(duration, time + 3)
            }
        },
        visible: hasSelection)

    // MARK: Copy

    static let emptyHeader = "Annotate"
    static var emptyCaption: String { InspectorPlatformCopy.annotateEmptyCaption }
    static var textTip: String { InspectorPlatformCopy.annotateTextTip }
    static var drawingTip: String { InspectorPlatformCopy.annotateDrawingTip }
    static let tapTip = "Drag the ripple on the preview over the tapped spot. It pulses for the block's whole duration."
    static let timingTip = "Drag the block's edges on the ANNOTATE lane to retime it."
    static var textTipCaption: InspectorCaption { InspectorCaption(id: "annotate.textTip", textTip, visible: isText) }
    static var tapTipCaption: InspectorCaption { InspectorCaption(id: "annotate.tapTip", tapTip, visible: isTap) }
    static var drawingTipCaption: InspectorCaption {
        InspectorCaption(id: "annotate.drawingTip", drawingTip, visible: isDrawing)
    }
    static var timingTipCaption: InspectorCaption {
        InspectorCaption(id: "annotate.timingTip", timingTip, visible: hasSelection)
    }

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "annotate.section.empty", title: nil, rows: [
                .custom(id: "annotate.empty", visible: { !hasSelection($0) }),
            ], visible: { !hasSelection($0) }),
            InspectorSection(id: "annotate.section.header", title: nil, rows: [
                .custom(id: "annotate.header", visible: hasSelection),
            ], visible: hasSelection),
            InspectorSection(id: "annotate.section.text", title: "Text", rows: [
                .text(text), .caption(textTipCaption),
                .slider(fontSize), .choice(font), .choice(weight), .toggle(uppercase),
            ], visible: isText),
            InspectorSection(id: "annotate.section.tap", title: "Tap Ripple", rows: [
                .slider(tapSize), .caption(tapTipCaption),
            ], visible: isTap),
            InspectorSection(id: "annotate.section.style", title: "Style", rows: [
                .color(color), .custom(id: "annotate.fillRow", visible: hasFill), .slider(corners), .slider(border),
            ], visible: hasSelection),
            InspectorSection(id: "annotate.section.effects", title: "Effects", rows: [
                .slider(opacity), .slider(blackout), .choice(buildIn), .choice(buildOut), .toggle(shadow),
            ], visible: hasSelection),
            InspectorSection(id: "annotate.section.strokes", title: "Strokes", rows: [
                .custom(id: "annotate.strokes", visible: isDrawing),
                .caption(drawingTipCaption),
            ], visible: isDrawing),
            InspectorSection(id: "annotate.section.timing", title: "Timing", rows: [
                .custom(id: "annotate.timing", visible: hasSelection),
                .caption(timingTipCaption),
            ], visible: hasSelection),
        ]
    }
}
