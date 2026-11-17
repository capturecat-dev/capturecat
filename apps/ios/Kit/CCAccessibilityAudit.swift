#if DEBUG
import UIKit

/// The accessibility auditor behind the a11y gate (StudioLab `--a11y`, the
/// app's `-uiA11yAudit`; apps/ios/scripts/ios-a11y.sh). It reads a screen the
/// way VoiceOver does — the container protocol (`accessibilityElements`,
/// `isAccessibilityElement`), hidden subtrees, `accessibilityViewIsModal` —
/// and MEASURES what the rules are about instead of trusting declarations:
///
///  • every element VoiceOver can reach has a non-empty label, and an
///    interactive one (a control, or a view with a tap recognizer) carries an
///    interactive trait; adjustable elements speak a value;
///  • hit targets ≥ 44 × 44 pt — probed with `UIWindow.hitTest` outward from
///    the element's activation point, so a superview that clips the target,
///    or a sibling on top of it, shrinks what is measured;
///  • no two focusable frames overlap (their visible parts);
///  • text at any size: every visible label's text fits its frame (no
///    truncation), no two visible texts overlap, and nothing is cut off by
///    a non-scrolling ancestor that clips.
///
/// DEBUG only, extension-safe (it is handed a window).
enum CCAccessibilityAudit {
    struct Element {
        let object: NSObject
        let label: String
        let value: String
        let hint: String
        let traits: UIAccessibilityTraits
        /// In window coordinates.
        let frame: CGRect
        var visibleFrame: CGRect
        let actions: [String]
        let view: UIView?
        let isInteractive: Bool
        let needsInteractiveTrait: Bool

        var traitNames: String { CCAccessibilityAudit.names(traits) }
    }

    struct Problem: CustomStringConvertible {
        let rule: String
        let detail: String
        var description: String { "\(rule): \(detail)" }
    }

    static let interactiveTraits: UIAccessibilityTraits = [.button, .link, .adjustable, .keyboardKey, .searchField, .toggleButton]

    // MARK: - VoiceOver's reading order

    /// Every element VoiceOver can reach in `window`, in navigation order.
    static func elements(in window: UIWindow) -> [Element] {
        let root: UIView = topmostModal(in: window) ?? window
        var out: [Element] = []
        var seen = Set<ObjectIdentifier>()
        visit(root, window: window, clip: window.bounds, out: &out, seen: &seen)
        // Floating chrome (`ccFloatsOverContent`) covers what scrolls under
        // it: those parts leave the elements beneath (wholly covered ones
        // keep a null visible frame — VoiceOver scrolls them out first).
        let overlays = floatingOverlays(in: window)
        for i in out.indices {
            guard let view = out[i].view, !overlays.contains(where: { view === $0 || view.isDescendant(of: $0) }) else { continue }
            for overlay in overlays {
                let rect = overlay.convert(overlay.bounds, to: window)
                out[i].visibleFrame = carve(out[i].visibleFrame, around: rect)
            }
        }
        return out
    }

    static func floatingOverlays(in window: UIWindow) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            guard isShown(view) else { return }
            if view.ccFloatsOverContent { found.append(view); return }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// The largest part of `rect` outside `cover` (null when none is left).
    static func carve(_ rect: CGRect, around cover: CGRect) -> CGRect {
        guard !rect.isNull, rect.intersects(cover) else { return rect }
        let parts = [
            CGRect(x: rect.minX, y: rect.minY, width: max(0, cover.minX - rect.minX), height: rect.height),
            CGRect(x: cover.maxX, y: rect.minY, width: max(0, rect.maxX - cover.maxX), height: rect.height),
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, cover.minY - rect.minY)),
            CGRect(x: rect.minX, y: cover.maxY, width: rect.width, height: max(0, rect.maxY - cover.maxY)),
        ].filter { $0.width > 1 && $0.height > 1 }
        return parts.max { $0.width * $0.height < $1.width * $1.height } ?? .null
    }

    /// The last visible `accessibilityViewIsModal` view (VoiceOver reads only it).
    static func topmostModal(in window: UIWindow) -> UIView? {
        var found: UIView?
        func walk(_ view: UIView) {
            guard isShown(view) else { return }
            if view.accessibilityViewIsModal { found = view }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return found
    }

    static func isShown(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0.01 && !view.accessibilityElementsHidden
    }

    private static func visit(_ object: NSObject, window: UIWindow, clip: CGRect, out: inout [Element], seen: inout Set<ObjectIdentifier>) {
        var clip = clip
        if let view = object as? UIView {
            guard isShown(view), view === window || view.window === window else { return }
            if view.clipsToBounds || view is UIScrollView {
                clip = clip.intersection(view.convert(view.bounds, to: window))
            }
        } else if object.accessibilityElementsHidden {
            return
        }
        if object.isAccessibilityElement {
            let id = ObjectIdentifier(object)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            if let element = make(object, window: window, clip: clip) { out.append(element) }
            return
        }
        if let children = object.accessibilityElements as? [NSObject] {
            for child in children { visit(child, window: window, clip: clip, out: &out, seen: &seen) }
            return
        }
        if let view = object as? UIView {
            for sub in readingOrder(view.subviews) { visit(sub, window: window, clip: clip, out: &out, seen: &seen) }
        }
    }

    /// UIKit's default for a container without `accessibilityElements`:
    /// top to bottom, then leading to trailing.
    static func readingOrder(_ views: [UIView]) -> [UIView] {
        views.enumerated().sorted { a, b in
            let fa = a.element.frame, fb = b.element.frame
            if abs(fa.minY - fb.minY) > 4 { return fa.minY < fb.minY }
            if abs(fa.minX - fb.minX) > 0.5 { return fa.minX < fb.minX }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func owningView(_ object: NSObject) -> UIView? {
        if let view = object as? UIView { return view }
        var container: Any? = (object as? UIAccessibilityElement)?.accessibilityContainer
        while let c = container {
            if let view = c as? UIView { return view }
            container = (c as? UIAccessibilityElement)?.accessibilityContainer
        }
        return nil
    }

    private static func make(_ object: NSObject, window: UIWindow, clip: CGRect) -> Element? {
        let screenFrame = object.accessibilityFrame
        let frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        guard frame.width > 0.5, frame.height > 0.5 else { return nil }
        let view = owningView(object)
        var interactive = false
        var needsTrait = false
        if let v = object as? UIView {
            if let control = v as? UIControl, control.isEnabled, control.isUserInteractionEnabled { interactive = true; needsTrait = true }
            if v.isUserInteractionEnabled, (v.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer && $0.isEnabled }) {
                interactive = true; needsTrait = true
            }
            if v is UITextField || v is UITextView { needsTrait = false }
        }
        let traits = object.accessibilityTraits
        if !traits.intersection(interactiveTraits).isEmpty { interactive = true }
        let actions = (object.accessibilityCustomActions ?? []).map(\.name)
        return Element(
            object: object,
            label: (object.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            value: object.accessibilityValue ?? "",
            hint: object.accessibilityHint ?? "",
            traits: traits,
            frame: frame,
            visibleFrame: frame.intersection(clip),
            actions: actions,
            view: view,
            isInteractive: interactive,
            needsInteractiveTrait: needsTrait)
    }

    // MARK: - Rules

    /// Elements whose geometry is DATA (timeline blocks, stage objects): their
    /// size follows the content, so the 44 pt rule is replaced by "has
    /// custom actions that do the same edits" (checked by the gate). Their
    /// owners tag them with this identifier prefix.
    static let dataGeometryPrefix = CCAccessibility.dataGeometryPrefix

    static func isDataGeometry(_ e: Element) -> Bool {
        let id = (e.object as? UIView)?.accessibilityIdentifier ?? (e.object as? UIAccessibilityElement)?.accessibilityIdentifier
        return id?.hasPrefix(dataGeometryPrefix) == true
    }

    /// Labels, traits, values, targets, overlaps.
    static func check(_ elements: [Element], in window: UIWindow, minTarget: CGFloat = 44) -> [Problem] {
        var problems: [Problem] = []
        for e in elements {
            let name = describe(e)
            if e.label.isEmpty { problems.append(Problem(rule: "label", detail: "\(name) has no label")) }
            if e.needsInteractiveTrait && e.traits.intersection(interactiveTraits).isEmpty && !isDataGeometry(e) {
                problems.append(Problem(rule: "traits", detail: "\(name) is interactive but has traits [\(e.traitNames)]"))
            }
            if e.traits.contains(.adjustable) && e.value.isEmpty {
                problems.append(Problem(rule: "value", detail: "\(name) is adjustable but speaks no value"))
            }
            if e.isInteractive, !e.traits.contains(.notEnabled), e.visibleFrame.width > 1, e.visibleFrame.height > 1 {
                if isDataGeometry(e) {
                    if e.actions.isEmpty {
                        problems.append(Problem(rule: "actions", detail: "\(name) is sized by its data but offers no custom actions"))
                    }
                } else if abs(e.visibleFrame.width - e.frame.width) > 1 || abs(e.visibleFrame.height - e.frame.height) > 1 {
                    // Partly scrolled out of view: VoiceOver scrolls it in
                    // first; its target is measured where it is fully shown.
                    continue
                } else {
                    // The probe steps 0.5 pt from the activation point; one
                    // point of slack covers a target edge between samples.
                    let target = hitTarget(e, in: window)
                    if target.width + 1 < minTarget || target.height + 1 < minTarget {
                        var detail = String(format: "%@ hit target %.0f×%.0f pt", name, target.width, target.height)
                        let c = CGPoint(x: e.visibleFrame.midX, y: e.visibleFrame.midY)
                        if target == .zero, let hit = window.hitTest(c, with: nil) {
                            detail += " (covered by \(type(of: hit)))"
                        } else if target.height + 1 < minTarget {
                            // What takes the touch just past the measured span.
                            let above = window.hitTest(CGPoint(x: c.x, y: c.y - target.height / 2 - 1), with: nil)
                            let below = window.hitTest(CGPoint(x: c.x, y: c.y + target.height / 2 + 1), with: nil)
                            detail += " (above: \(above.map { String(describing: type(of: $0)) } ?? "-"), below: \(below.map { String(describing: type(of: $0)) } ?? "-"))"
                        }
                        problems.append(Problem(rule: "target", detail: detail))
                    }
                }
            }
        }
        // Focusable frames never overlap (the visible parts).
        for i in elements.indices {
            for j in elements.indices where j > i {
                let a = elements[i].visibleFrame, b = elements[j].visibleFrame
                guard !a.isNull, !b.isNull else { continue }
                let x = a.intersection(b)
                // Two objects the USER placed on top of each other (stage
                // annotations, regions) may overlap — that is the content.
                if isDataGeometry(elements[i]), isDataGeometry(elements[j]) { continue }
                if !x.isNull, x.width > 2, x.height > 2 {
                    problems.append(Problem(rule: "overlap", detail: "\(describe(elements[i])) overlaps \(describe(elements[j])) by \(Int(x.width))×\(Int(x.height)) pt"))
                }
            }
        }
        return problems
    }

    /// The touch target around the element's activation point, measured by
    /// hit-testing the window outward (0.5 pt steps, ±40 pt).
    static func hitTarget(_ e: Element, in window: UIWindow) -> CGSize {
        guard let view = e.view else { return e.visibleFrame.size }
        // A sub-element (a segment of a segmented control) owns its own
        // column / row of its view: the probe may not run into a neighbour.
        let isPart = e.object !== view
        var c = CGPoint(x: e.visibleFrame.midX, y: e.visibleFrame.midY)
        if !isPart {
            let p = window.convert(e.object.accessibilityActivationPoint, from: window.screen.coordinateSpace)
            if e.frame.contains(p) { c = p }
        }
        func owns(_ p: CGPoint) -> Bool {
            guard let hit = window.hitTest(p, with: nil) else { return false }
            return hit === view || hit.isDescendant(of: view)
        }
        guard owns(c) else { return .zero }
        // Half-point steps out to `limit` pt.
        func span(_ dx: CGFloat, _ dy: CGFloat, limit: CGFloat) -> CGFloat {
            var n: CGFloat = 0
            while n < limit, owns(CGPoint(x: c.x + dx * (n + 0.5), y: c.y + dy * (n + 0.5))) { n += 0.5 }
            return n
        }
        if isPart {
            // Along the parts' axis the target is the part itself.
            let r = e.visibleFrame
            let horizontalParts = r.width < view.bounds.width - 1
            let w = horizontalParts ? r.width : span(-1, 0, limit: 40) + span(1, 0, limit: 40) + 0.5
            let h = horizontalParts ? span(0, -1, limit: 40) + span(0, 1, limit: 40) + 0.5 : r.height
            return CGSize(width: w, height: h)
        }
        return CGSize(width: span(-1, 0, limit: 40) + span(1, 0, limit: 40) + 0.5,
                      height: span(0, -1, limit: 40) + span(0, 1, limit: 40) + 0.5)
    }

    // MARK: - Text (Dynamic Type)

    struct TextRun {
        let view: UIView
        let text: String
        let frame: CGRect
    }

    /// Visible text views under `root` and the text problems among them.
    static func checkText(in root: UIView, window: UIWindow) -> (runs: [TextRun], problems: [Problem]) {
        var runs: [TextRun] = []
        var problems: [Problem] = []
        func walk(_ view: UIView, clip: CGRect, clippers: [UIView]) {
            guard isShown(view) else { return }
            var clip = clip
            var clippers = clippers
            if view.clipsToBounds || view is UIScrollView {
                clip = clip.intersection(view.convert(view.bounds, to: window))
                clippers.append(view)
            }
            if let label = view as? UILabel, let text = label.text ?? label.attributedText?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.bounds.width > 0.5 {
                let frame = label.convert(label.bounds, to: window)
                let visible = frame.intersection(clip)
                if !visible.isNull, visible.width > 1, visible.height > 1 {
                    runs.append(TextRun(view: label, text: text, frame: visible))
                    if let issue = truncation(label) {
                        problems.append(Problem(rule: "truncated", detail: "\"\(short(text))\" \(issue)"))
                    }
                    // Cut off by a clipping ancestor that cannot scroll to it.
                    if let cutter = clippers.last(where: { !($0 is UIScrollView) }) {
                        let box = cutter.convert(cutter.bounds, to: window)
                        if frame.minY < box.minY - 1 || frame.maxY > box.maxY + 1 || frame.minX < box.minX - 1 || frame.maxX > box.maxX + 1,
                           !clippers.contains(where: { $0 is UIScrollView && $0.isDescendant(of: cutter) }) {
                            problems.append(Problem(rule: "clipped", detail: "\"\(short(text))\" cut off by \(type(of: cutter))"))
                        }
                    }
                }
            }
            for sub in view.subviews { walk(sub, clip: clip, clippers: clippers) }
        }
        walk(root, clip: window.bounds, clippers: [])
        // Text on floating chrome passes over the content by design.
        let overlays = floatingOverlays(in: window)
        func floats(_ v: UIView) -> Bool { overlays.contains { v.isDescendant(of: $0) } }
        for i in runs.indices {
            for j in runs.indices where j > i {
                if floats(runs[i].view) != floats(runs[j].view) { continue }
                let x = runs[i].frame.intersection(runs[j].frame)
                if !x.isNull, x.width > 1.5, x.height > 1.5 {
                    problems.append(Problem(rule: "text-overlap", detail: "\"\(short(runs[i].text))\" overlaps \"\(short(runs[j].text))\" by \(Int(x.width))×\(Int(x.height)) pt"))
                }
            }
        }
        return (runs, problems)
    }

    /// The point size of every visible label (to prove text grows).
    static func fontSizes(in window: UIWindow) -> [ObjectIdentifier: CGFloat] {
        var sizes: [ObjectIdentifier: CGFloat] = [:]
        func walk(_ view: UIView) {
            guard isShown(view) else { return }
            if let label = view as? UILabel, let font = label.font { sizes[ObjectIdentifier(label)] = font.pointSize }
            view.subviews.forEach(walk)
        }
        walk(window)
        return sizes
    }

    /// Why a label's text does not fit its frame (nil = it fits).
    static func truncation(_ label: UILabel) -> String? {
        let bounds = label.bounds
        guard let font = label.font else { return nil }
        let text = label.attributedText ?? NSAttributedString(string: label.text ?? "", attributes: [.font: font])
        if label.numberOfLines == 1 {
            var need = ceil(text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin], context: nil).width)
            if label.adjustsFontSizeToFitWidth { need *= max(label.minimumScaleFactor, 0.01) }
            if need > bounds.width + 1 { return String(format: "needs %.0f pt, has %.0f", need, bounds.width) }
            let lineHeight = font.lineHeight
            if lineHeight > bounds.height + 2 { return String(format: "line %.0f pt tall, frame %.0f", lineHeight, bounds.height) }
            return nil
        }
        let fitted = label.textRect(forBounds: CGRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude),
                                    limitedToNumberOfLines: 0)
        if fitted.height > bounds.height + 2 {
            return String(format: "needs %.0f pt of height, has %.0f (lines %d)", fitted.height, bounds.height, label.numberOfLines)
        }
        return nil
    }

    // MARK: - One screen

    /// The whole audit of what `window` shows now, at one text size: the
    /// element transcript (`lines`), the problems, and a one-line summary.
    /// `baseFonts` (from `fontSizes` at the default size) turns on the text
    /// checks — fit, overlap, clipping, and that every text grew.
    static func screen(_ window: UIWindow, baseFonts: [ObjectIdentifier: CGFloat]? = nil)
        -> (lines: [String], problems: [Problem], summary: String) {
        window.layoutIfNeeded()
        let elements = elements(in: window)
        var problems = check(elements, in: window)
        if elements.isEmpty { problems.append(Problem(rule: "empty", detail: "VoiceOver reaches nothing")) }
        var lines = elements.enumerated().map { "   " + line($0.element, index: $0.offset) }
        var texts = 0
        if let baseFonts {
            let text = checkText(in: topmostModal(in: window) ?? window, window: window)
            texts = text.runs.count
            problems += text.problems
            for run in text.runs {
                guard let label = run.view as? UILabel, let before = baseFonts[ObjectIdentifier(label)] else { continue }
                if label.font.pointSize <= before + 0.01 {
                    problems.append(Problem(rule: "fixed-size", detail: String(format: "\"%@\" stays %.0f pt at the largest size", short(run.text), before)))
                }
            }
        }
        lines += problems.map { "   ! \($0)" }
        let interactive = elements.filter(\.isInteractive).count
        let summary = problems.isEmpty
            ? "\(elements.count) elements (\(interactive) interactive): " + (baseFonts == nil ? "labels, traits, targets ≥ 44 pt, no overlaps" : "\(texts) texts fit, grew, none overlap")
            : "\(problems.count) problem(s): " + problems.prefix(5).map(\.description).joined(separator: " | ")
        return (lines, problems, summary)
    }

    /// Whether UIKit's accessibility runtime answers (it does under VoiceOver,
    /// Accessibility Inspector, or `ApplicationAccessibilityEnabled`): without
    /// it UIKit's own elements report nothing and an audit would be blind.
    static func runtimeLoaded(in window: UIWindow) -> Bool {
        let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        probe.text = "probe"
        window.addSubview(probe)
        defer { probe.removeFromSuperview() }
        return probe.isAccessibilityElement && probe.accessibilityLabel == "probe" && probe.accessibilityFrame.width > 1
    }

    // MARK: - Words

    static func describe(_ e: Element) -> String {
        let kind = e.view.map { String(describing: type(of: $0)) } ?? String(describing: type(of: e.object))
        let label = e.label.isEmpty ? "<no label>" : short(e.label)
        return "\(kind)[\(label)]"
    }

    static func short(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? String(flat.prefix(47)) + "…" : flat
    }

    static func names(_ traits: UIAccessibilityTraits) -> String {
        let all: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.adjustable, "adjustable"), (.selected, "selected"),
            (.staticText, "text"), (.header, "header"), (.image, "image"), (.notEnabled, "notEnabled"),
            (.updatesFrequently, "updates"), (.keyboardKey, "key"), (.searchField, "search"),
            (.toggleButton, "toggle"), (.tabBar, "tabBar"), (.summaryElement, "summary"),
            (.allowsDirectInteraction, "direct"), (.startsMediaSession, "media"), (.playsSound, "sound"),
        ]
        return all.filter { traits.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    /// One log line per element (the gate's transcript of what VoiceOver reads).
    static func line(_ e: Element, index: Int) -> String {
        var s = String(format: "#%02d %@ traits=[%@]", index, describe(e), e.traitNames)
        if !e.value.isEmpty { s += " value=\"\(short(e.value))\"" }
        if !e.hint.isEmpty { s += " hint=\"\(short(e.hint))\"" }
        if !e.actions.isEmpty { s += " actions=[\(e.actions.joined(separator: "|"))]" }
        s += String(format: " frame=%.0f,%.0f %.0f×%.0f", e.frame.minX, e.frame.minY, e.frame.width, e.frame.height)
        return s
    }
}
#endif
