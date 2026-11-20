import AppKit

/// The localization gate's eyes (apps/macos/scripts/mac-l10n.sh): for one
/// screen of a REAL window chain it records every text a person can see or
/// hear — text-field strings and placeholders, stock button titles,
/// CATextLayer strings, tooltips and what VoiceOver reads — and measures the
/// text problems a longer language causes:
///
///   truncated  the field's cell needs more room than its frame (single line:
///              width; wrapping: height at its real width);
///   clipped    an ancestor cuts part of the field off (outside any scroll
///              view, where being cut off is how scrolling works).
///
/// It does not judge the language itself: the script runs the same screens
/// in English and in each locale and calls a text that comes out identical
/// untranslated (scripts/mac-l10n-judge.py), unless the catalog says it is
/// the same word in that language (OK, Zoom, Pro…).
///
/// Off unless the gate passes `--l10n-audit <dir>`, so a gate's own checks
/// and artifacts are unchanged without it. Each screen writes
/// `<dir>/<screen>.json` and `<dir>/<screen>.png`.
@MainActor
enum CCLocalizationAudit {
    struct Text: Encodable {
        let text: String
        /// label · field · placeholder · button · layer · tooltip · ax-label · menu
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

    /// Where reports go; nil = the audit is off (no `--l10n-audit`).
    static let directory: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--l10n-audit"), i + 1 < args.count else { return nil }
        let url = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isEnabled: Bool { directory != nil }

    /// Screens audited so far this run (the gate prints a summary).
    private(set) static var screens: [String] = []
    private(set) static var problemCount = 0

    /// Gate-power seam (`--l10n-inject <defect>`): `untranslated` puts a
    /// hard-coded English "Delete" on every audited screen, `truncate` squeezes
    /// the first text field wider than 40 pt to half its width. The judge run
    /// with `--expect` must call each one out.
    static let injected: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--l10n-inject"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// Audits what `window` shows now (its content view and every child
    /// window — the custom menus and popovers are child panels).
    static func capture(_ screen: String, window: NSWindow) {
        guard isEnabled, let content = window.contentView else { return }
        var roots: [(NSView, NSWindow)] = [(content, window)]
        for child in window.childWindows ?? [] where child.isVisible || child.alphaValue > 0 {
            if let view = child.contentView { roots.append((view, child)) }
        }
        capture(screen, roots: roots, size: window.frame.size)
    }

    /// Audits one view tree (an offscreen-hosted surface).
    static func capture(_ screen: String, view: NSView) {
        guard isEnabled else { return }
        capture(screen, roots: [(view, view.window)], size: view.bounds.size)
    }

    /// Records a menu built from NSMenu (the menu bar, the status item):
    /// every item title, recursively. No geometry — the system draws them.
    static func capture(_ screen: String, menu: NSMenu) {
        guard isEnabled else { return }
        var texts: [Text] = []
        func walk(_ menu: NSMenu, depth: Int) {
            if depth > 0, !menu.title.isEmpty { texts.append(Text(text: menu.title, kind: "menu", frame: [])) }
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if !item.title.isEmpty { texts.append(Text(text: item.title, kind: "menu", frame: [])) }
                if let tip = item.toolTip, !tip.isEmpty { texts.append(Text(text: tip, kind: "tooltip", frame: [])) }
                if let sub = item.submenu { walk(sub, depth: depth + 1) }
            }
        }
        walk(menu, depth: 0)
        write(Report(screen: screen, locale: locale, window: [], texts: texts, problems: []), image: nil, screen: screen)
    }

    /// Records texts a surface holds as data rather than views (a popup's
    /// option list before it opens).
    static func capture(_ screen: String, texts: [String]) {
        guard isEnabled else { return }
        let items = texts.filter { !$0.isEmpty }.map { Text(text: $0, kind: "option", frame: []) }
        write(Report(screen: screen, locale: locale, window: [], texts: items, problems: []), image: nil, screen: screen)
    }

    private static var locale: String { Bundle.main.preferredLocalizations.first ?? "?" }

    private static func capture(_ screen: String, roots: [(NSView, NSWindow?)], size: CGSize) {
        var texts: [Text] = []
        var problems: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?, _ kind: String, _ frame: CGRect) {
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            let box = [Int(frame.minX.rounded()), Int(frame.minY.rounded()), Int(frame.width.rounded()), Int(frame.height.rounded())]
            guard seen.insert("\(kind)|\(text)|\(box)").inserted else { return }
            texts.append(Text(text: text, kind: kind, frame: box))
        }

        if let defect = injected { inject(defect, into: roots.first?.0) }

        for (root, _) in roots {
            root.layoutSubtreeIfNeeded()
            walk(root, root: root, add: add, problems: &problems)
        }

        let report = Report(screen: screen, locale: locale, window: [Int(size.width), Int(size.height)],
                            texts: texts, problems: problems)
        write(report, image: snapshot(roots.first?.0), screen: screen)
    }

    private static func walk(_ view: NSView, root: NSView,
                             add: (String?, String, CGRect) -> Void, problems: inout [String]) {
        guard !view.isHidden, view.alphaValue > 0.01 else { return }
        let frame = view.convert(view.bounds, to: root)
        if let tip = view.toolTip { add(tip, "tooltip", frame) }
        if let label = view.accessibilityLabel(), !(view is NSTextField) { add(label, "ax-label", frame) }

        if let field = view as? NSTextField {
            if !field.stringValue.isEmpty {
                add(field.stringValue, field.isEditable ? "field" : "label", frame)
                if !field.isEditable, let issue = truncation(field) {
                    problems.append("truncated: \"\(field.stringValue)\" \(issue)")
                }
            } else if let placeholder = field.placeholderString ?? field.placeholderAttributedString?.string,
                      !placeholder.isEmpty {
                add(placeholder, "placeholder", frame)
                if let issue = placeholderTruncation(field, placeholder) {
                    problems.append("truncated: \"\(placeholder)\" \(issue)")
                }
            }
            if let issue = clipping(field), !field.stringValue.isEmpty {
                problems.append("clipped: \"\(field.stringValue)\" \(issue)")
            }
        } else if let button = view as? NSButton, !button.title.isEmpty, !button.isTransparent {
            add(button.title, "button", frame)
        }
        if let layer = view.layer { walkLayers(layer, root: root, add: add) }
        for sub in view.subviews { walk(sub, root: root, add: add, problems: &problems) }
    }

    /// CATextLayer strings a view draws directly (onboarding stage, rolling labels).
    private static func walkLayers(_ layer: CALayer, root: NSView, add: (String?, String, CGRect) -> Void) {
        for sub in layer.sublayers ?? [] where !(sub.delegate is NSView) {
            guard !sub.isHidden, sub.opacity > 0.01 else { continue }
            if let text = sub as? CATextLayer {
                let string = (text.string as? String) ?? (text.string as? NSAttributedString)?.string
                let frame = root.layer.map { sub.convert(sub.bounds, to: $0) } ?? sub.frame
                add(string, "layer", frame)
            }
            walkLayers(sub, root: root, add: add)
        }
    }

    /// Why `field`'s text doesn't fit its frame, or nil when it does.
    static func truncation(_ field: NSTextField) -> String? {
        guard let cell = field.cell, field.bounds.width > 1, field.bounds.height > 1 else { return nil }
        let bounds = field.bounds
        if wraps(field) {
            let need = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: 100_000)).height)
            return need > bounds.height + 1 ? "needs h\(Int(need)) has \(Int(bounds.height)) at w\(Int(bounds.width))" : nil
        }
        // AppKit's own test: a cell's expansion frame (the rect its full
        // text would need, as shown by expansion tooltips) is non-empty
        // exactly when the text doesn't fit the frame it has.
        let need = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000)).width)
        let expansion = cell.expansionFrame(withFrame: bounds, in: field)
        guard !expansion.isEmpty || need > bounds.width + 6 else { return nil }
        return "needs w\(Int(need)) has \(Int(bounds.width))"
    }

    private static func placeholderTruncation(_ field: NSTextField, _ placeholder: String) -> String? {
        guard field.bounds.width > 1 else { return nil }
        let font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let width = ceil((placeholder as NSString).size(withAttributes: [.font: font]).width)
        // A bezel-less field's text inset is ~2 pt a side; a bezeled one ~4.
        let inset: CGFloat = field.isBezeled ? 8 : 4
        return width + inset > field.bounds.width + 1 ? "needs w\(Int(width + inset)) has \(Int(field.bounds.width))" : nil
    }

    private static func wraps(_ field: NSTextField) -> Bool {
        guard let cell = field.cell else { return false }
        if field.maximumNumberOfLines == 1 { return false }
        return cell.wraps || field.maximumNumberOfLines > 1 || field.lineBreakMode == .byWordWrapping
            || field.lineBreakMode == .byCharWrapping
    }

    /// An ancestor that cuts part of the field off — outside a scroll view,
    /// where content clipped at the edge is just scrolled away.
    private static func clipping(_ field: NSTextField) -> String? {
        guard field.window != nil, field.bounds.width > 1, field.bounds.height > 1 else { return nil }
        var ancestor = field.superview
        while let view = ancestor {
            if view is NSClipView || view is NSScrollView { return nil }
            ancestor = view.superview
        }
        let visible = field.visibleRect
        let lost = field.bounds.width * field.bounds.height - visible.width * visible.height
        // Only the part the text actually draws in matters: measure against
        // the cell's own need, so a generously sized field half off its
        // superview's padding doesn't count.
        guard let cell = field.cell else { return nil }
        let need = cell.cellSize(forBounds: field.bounds)
        let textRect = NSRect(x: 0, y: 0, width: min(need.width, field.bounds.width),
                              height: min(need.height, field.bounds.height))
        let shown = visible.intersection(field.isFlipped ? textRect
                                         : textRect.offsetBy(dx: 0, dy: field.bounds.height - textRect.height))
        guard lost > 1, shown.width * shown.height < textRect.width * textRect.height - 4 else { return nil }
        return "shows \(Int(shown.width))x\(Int(shown.height)) of \(Int(textRect.width))x\(Int(textRect.height))"
    }

    private static func inject(_ defect: String, into root: NSView?) {
        guard let root else { return }
        switch defect {
        case "untranslated":
            let id = NSUserInterfaceItemIdentifier("l10n.injected")
            guard !root.subviews.contains(where: { $0.identifier == id }) else { return }
            // App copy hard-coded past the catalog (the bug class people
            // see: an English "Delete" in a translated inspector).
            let label = NSTextField(labelWithString: "Delete")  // l10n: verbatim — injected defect
            label.identifier = id
            label.sizeToFit()
            label.frame.origin = NSPoint(x: 8, y: 8)
            root.addSubview(label)
        case "truncate":
            func first(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, !field.isEditable, !field.isHidden,
                   !field.stringValue.isEmpty, field.bounds.width > 40, truncation(field) == nil { return field }
                for sub in view.subviews where !sub.isHidden { if let hit = first(sub) { return hit } }
                return nil
            }
            guard let field = first(root) else { return }
            field.translatesAutoresizingMaskIntoConstraints = true
            field.frame.size.width = floor(field.frame.width / 2)
        default:
            break
        }
    }

    private static func snapshot(_ view: NSView?) -> NSBitmapImageRep? {
        guard let view, view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func write(_ report: Report, image: NSBitmapImageRep?, screen: String) {
        guard let dir = directory else { return }
        screens.append(screen)
        problemCount += report.problems.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(report).write(to: dir.appendingPathComponent("\(screen).json"))
        if let png = image?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(screen).png"))
        }
        print("L10NAUDIT \(screen) texts=\(report.texts.count) problems=\(report.problems.count)")
        for problem in report.problems.prefix(12) { print("L10NAUDIT   ! \(problem)") }
    }
}
