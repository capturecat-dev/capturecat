#if DEBUG
import UIKit

/// The localization gate's eyes (apps/ios/scripts/ios-l10n.sh): for one
/// screen of the REAL window chain it records every text a person can see or
/// hear — label and button text, field text and placeholders, CATextLayer
/// strings, and what VoiceOver reads (label, value, hint) — plus the text
/// problems `CCAccessibilityAudit.checkText` measures (truncated, clipped by
/// a non-scrolling ancestor, two texts overlapping), and a snapshot.
///
/// It does not judge the language itself: the script runs the same screens
/// in English and in each locale and calls a text that comes out identical
/// untranslated, unless the catalog says it is the same in that language
/// (OK, Zoom, Pro…) or it is fixture content (project names, comments).
///
/// DEBUG only, extension-safe (it is handed a window).
enum CCLocalizationAudit {
    struct Text: Encodable {
        let text: String
        /// label · button · field · placeholder · layer · ax-label · ax-value · ax-hint
        let kind: String
        let frame: [Int]
    }

    struct Report: Encodable {
        let screen: String
        let locale: String
        let window: [Int]
        let texts: [Text]
        let problems: [String]
    }

    /// Audits what `window` shows now; writes `<dir>/<screen>.json` and
    /// `<dir>/<screen>.png`. Returns the problems (empty = clean).
    @discardableResult
    static func capture(_ screen: String, window: UIWindow, to dir: URL) -> [String] {
        window.layoutIfNeeded()
        let root = CCAccessibilityAudit.topmostModal(in: window) ?? window
        var texts: [Text] = []
        var seen = Set<String>()
        func add(_ text: String?, _ kind: String, _ frame: CGRect) {
            guard let raw = text else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let box = [Int(frame.minX.rounded()), Int(frame.minY.rounded()), Int(frame.width.rounded()), Int(frame.height.rounded())]
            let id = "\(kind)|\(text)|\(box)"
            guard seen.insert(id).inserted else { return }
            texts.append(Text(text: text, kind: kind, frame: box))
        }

        let measured = CCAccessibilityAudit.checkText(in: root, window: window)
        for run in measured.runs { add(run.text, "label", run.frame) }

        func walk(_ view: UIView, clip: CGRect) {
            guard CCAccessibilityAudit.isShown(view) else { return }
            var clip = clip
            if view.clipsToBounds || view is UIScrollView { clip = clip.intersection(view.convert(view.bounds, to: window)) }
            let frame = view.convert(view.bounds, to: window)
            let visible = !frame.intersection(clip).isNull
            if visible {
                if let field = view as? UITextField {
                    add(field.text, "field", frame)
                    add(field.placeholder ?? field.attributedPlaceholder?.string, "placeholder", frame)
                } else if let textView = view as? UITextView {
                    add(textView.text, "field", frame)
                }
                walkLayers(view.layer, in: view, window: window, add: add)
            }
            for sub in view.subviews { walk(sub, clip: clip) }
        }
        walk(root, clip: window.bounds)

        for element in CCAccessibilityAudit.elements(in: window) where !element.visibleFrame.isNull {
            add(element.label, "ax-label", element.frame)
            add(element.value, "ax-value", element.frame)
            add(element.hint, "ax-hint", element.frame)
        }

        // Truncation with the FULL text (the judge exempts user content —
        // project names, comments — which truncates by design).
        var problems = measured.problems.filter { $0.rule != "truncated" }.map(\.description)
        for run in measured.runs {
            guard let label = run.view as? UILabel, let issue = CCAccessibilityAudit.truncation(label) else { continue }
            problems.append("truncated: \"\(run.text)\" \(issue)")
        }
        let report = Report(screen: screen, locale: Bundle.main.preferredLocalizations.first ?? "?",
                            window: [Int(window.bounds.width), Int(window.bounds.height)], texts: texts, problems: problems)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(report).write(to: dir.appendingPathComponent("\(screen).json"))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(screen).png"))
        return problems
    }

    /// CATextLayer strings drawn by kit views (lanes, chips) — the layers a
    /// view owns directly, not its subviews' (they are walked as views).
    private static func walkLayers(_ layer: CALayer, in view: UIView, window: UIWindow, add: (String?, String, CGRect) -> Void) {
        for sub in layer.sublayers ?? [] where sub.delegate == nil || sub.delegate === view {
            guard !sub.isHidden, sub.opacity > 0.01 else { continue }
            if let text = sub as? CATextLayer {
                let string = (text.string as? String) ?? (text.string as? NSAttributedString)?.string
                add(string, "layer", sub.convert(sub.bounds, to: window.layer))
            }
            walkLayers(sub, in: view, window: window, add: add)
        }
    }
}
#endif
