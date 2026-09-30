import AppKit

/// Headless acceptance probe for the CCKit EXTRAS — toast/toaster, tooltip,
/// accordion/collapsible, tabs, radio group, avatar/group, skeleton/reveal,
/// stepper (rolling digits), text area, callout, empty state, progress ring,
/// plus the polished progress bar, spinner and badge.
///
///   CaptureCat --capkit-extras-shot
///
/// Everything mounts in ONE real gallery (three column stacks in a window's
/// content view — the app's hosting topology, not a bare pre-sized window
/// per component) and the gate asserts:
///  • topology — non-degenerate frames in the real stack chain;
///  • material — every dressed surface carries its CCMaterial recipe
///    (read through `probe*` seams, never `sublayers.first`);
///  • motion MID-FLIGHT — sampled from presentation layers (or per-tick
///    samplers for curve-true constraint growth), never settled frames only;
///    growth must OVERSHOOT its target with the top edge PINNED;
///  • live dark→light retheme of mounted views, from real layer colors;
///  • responsiveness — the window shrinks and flexible components track
///    the RESOLVED column width (alignment rects).
@MainActor
enum CCKitExtrasHarness {
    private static var results: [(String, Bool)] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok))
        print("CAPKITX \(name)\(detail.isEmpty ? "" : " " + detail) ok=\(ok)")
    }

    /// Sequential script: each step runs `delay` after the previous one, so
    /// no two motion triggers share a transaction (a shared commit skews the
    /// tight mid-flight windows).
    private final class Script {
        private var steps: [(TimeInterval, () -> Void)] = []
        func then(_ delay: TimeInterval, _ body: @escaping () -> Void) { steps.append((delay, body)) }
        func run(_ index: Int = 0) {
            guard index < steps.count else { return }
            let (delay, body) = steps[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                body()
                self.run(index + 1)
            }
        }
    }

    /// Per-tick (120 Hz) sampler for growth animations.
    private final class Sampler {
        private var timer: Timer?
        private(set) var samples: [[CGFloat]] = []
        init(_ probe: @escaping () -> [CGFloat]) {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.samples.append(probe()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        func stop() { timer?.invalidate(); timer = nil }
    }

    // MARK: - Probing helpers

    /// The material recipe on a layer: 1 raised, 2 raised matte, 3 recessed
    /// (nil when the ccmat base is missing — presence is part of the assert).
    private static func materialStyle(_ layer: CALayer?) -> Int? {
        guard let layer, layer.sublayers?.contains(where: { $0.name == "ccmat.base" }) == true else { return nil }
        return layer.value(forKey: "ccmatStyle") as? Int
    }

    private static func materialMid(_ layer: CALayer?) -> CGColor? {
        guard let base = layer?.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer,
              let colors = base.colors, colors.count > 1 else { return nil }
        return (colors[1] as! CGColor)
    }

    private static func presented(_ layer: CALayer?) -> CALayer? { layer.map { $0.presentation() ?? $0 } }

    private static func scalar(_ layer: CALayer?, _ keyPath: String) -> CGFloat {
        (presented(layer)?.value(forKeyPath: keyPath) as? CGFloat) ?? .nan
    }

    /// Screen-truth top edge of a view (window coords, Y-up) from its
    /// PRESENTATION layer.
    private static func presentedTop(_ view: NSView, in root: NSView) -> CGFloat {
        guard let layer = view.layer, let rootLayer = root.layer else { return .nan }
        let shown = layer.presentation() ?? layer
        let rootShown = rootLayer.presentation() ?? rootLayer
        let top = view.isFlipped ? shown.bounds.minY : shown.bounds.maxY
        return shown.convert(CGPoint(x: 0, y: top), to: rootShown).y
    }

    private static func presentedHeight(_ view: NSView) -> CGFloat {
        presented(view.layer)?.bounds.height ?? view.frame.height
    }

    /// A procedurally drawn portrait-ish image (avatar CONTENT, never themed).
    private static func sampleImage(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side * 2, height: side * 2), flipped: false) { rect in
            NSGradient(colors: [
                NSColor(srgbRed: 0.98, green: 0.62, blue: 0.36, alpha: 1),
                NSColor(srgbRed: 0.86, green: 0.28, blue: 0.47, alpha: 1),
            ])?.draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.17, y: rect.height * 0.48,
                                        width: rect.width * 0.34, height: rect.width * 0.34)).fill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.32, y: -rect.height * 0.2,
                                        width: rect.width * 0.64, height: rect.height * 0.62)).fill()
            return true
        }
    }

    // MARK: - Run

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CCTheme.setMode(.dark, persist: false)

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 60, width: 1320, height: 940),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        let backgroundObservation = CCThemeObservation { [weak root] in
            root?.layer?.backgroundColor = CCTheme.color.background.cgColor
        }

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 0
        columns.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            columns.topAnchor.constraint(equalTo: root.topAnchor),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        func makeColumn() -> NSStackView {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 14
            column.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 22, right: 20)
            columns.addArrangedSubview(column)
            return column
        }
        let col1 = makeColumn(), col2 = makeColumn(), col3 = makeColumn()

        var components: [(String, NSView)] = []
        var flexible: [(String, NSView, NSStackView)] = []
        func add(_ name: String, _ view: NSView, to column: NSStackView, flex: Bool = false) {
            column.addArrangedSubview(view)
            if flex {
                view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
                flexible.append((name, view, column))
            }
            components.append((name, view))
        }
        func row(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = spacing
            stack.alignment = align
            return stack
        }

        // ── Column 1: tooltips, tabs, accordion, radios, steppers ──
        let tipButtons = [
            ("square.and.arrow.up", "Export", "⌘E"), ("scissors", "Trim clip", "⌘T"),
            ("wand.and.stars", "Enhance audio", nil), ("gearshape", "Settings", "⌘,"),
        ].map { spec -> (CCButton, CCTooltip) in
            let button = CCButton(symbol: spec.0, style: .secondary)
            return (button, CCTooltip.attach(to: button, text: spec.1, shortcut: spec.2))
        }
        add("tooltipTargets", row(tipButtons.map(\.0), spacing: CCSpace.xs + 2), to: col1)

        func card(_ title: String, _ rows: [NSView]) -> CCCard {
            let card = CCCard(title: title)
            for row in rows { card.addContent(row) }
            return card
        }
        let tabs = CCTabs([
            ("Account", card("Account", [
                CCFormRow(label: "Name", control: CCField(placeholder: "Your name", value: "Mike Garland")),
            ])),
            ("Password", card("Password", [
                CCFormRow(label: "Current password", control: CCField(placeholder: "••••••••")),
                CCFormRow(label: "New password", control: CCField(placeholder: "At least 12 characters"),
                          hint: "Use a passphrase you don't use anywhere else."),
            ])),
            ("Team", card("Team", [{
                let text = NSTextField(wrappingLabelWithString: "Invite teammates to share captures.")
                text.setContentCompressionResistancePriority(.init(250), for: .horizontal)
                return text
            }()])),
        ])
        var tabChanges: [Int] = []
        tabs.onChange = { tabChanges.append($0) }
        add("tabs", tabs, to: col1, flex: true)

        let accordion = CCAccordion(mode: .single)
        accordion.addItem(title: "Is it accessible?",
                          text: "Yes. Headers take keyboard focus, and space or return opens them.")
        accordion.addItem(title: "Is it styled?",
                          text: "It sits on the house raised card, with hairlines between items and a chevron that springs a half turn.")
        accordion.addItem(title: "Is it animated?",
                          text: "Yes — only the bottom edge moves, and growth lands on the house bounce.")
        add("accordion", accordion, to: col1, flex: true)

        let radio = CCRadioGroup(options: [
            .init(title: "Default", detail: "Balanced spacing for most screens"),
            .init(title: "Comfortable", detail: "More room around every row"),
            .init(title: "Compact", detail: "Fits the most on screen"),
        ], selectedIndex: 0)
        add("radio", radio, to: col1)
        let radioRow = CCRadioGroup(options: ["Monthly", "Yearly"], selectedIndex: 1, orientation: .horizontal)
        add("radioHorizontal", radioRow, to: col1)

        let fps = CCStepper(value: 30, min: 1, max: 120, step: 1)
        fps.format = { "\(Int($0)) fps" }
        let speed = CCStepper(value: 1, min: 0.5, max: 4, step: 0.25)
        speed.format = { String(format: "%.2g×", $0) }
        add("steppers", row([fps, speed], spacing: CCSpace.md), to: col1)

        // ── Column 2: text area, callouts, bars, badges ──
        let textArea = CCTextArea(placeholder: "Add a note for this capture…", minLines: 3, maxLines: 6)
        add("textArea", textArea, to: col2, flex: true)
        let callouts = [
            CCCallout(title: "Heads up!", message: "Recordings are saved to your Library automatically."),
            CCCallout(title: "Export complete", message: "launch-demo.mp4 is ready to share.", variant: .success),
            CCCallout(title: "Low disk space", message: "Less than 2 GB left — long captures may stop early.",
                      variant: .warning),
            CCCallout(title: "Upload failed", message: "The server rejected the file. Try again in a moment.",
                      variant: .destructive, dismissible: true),
        ]
        for (index, callout) in callouts.enumerated() { add("callout\(index)", callout, to: col2, flex: true) }
        let doomed = CCCallout(title: "Update available", message: "CaptureCat 3.2 adds keystroke overlays.",
                               dismissible: true)
        add("calloutDismiss", doomed, to: col2, flex: true)
        let bar = CCProgressBar()
        bar.doubleValue = 0.35
        add("progressBar", bar, to: col2, flex: true)
        let busyBar = CCProgressBar()
        busyBar.isIndeterminate = true
        add("progressIndeterminate", busyBar, to: col2, flex: true)
        let countBadge = CCBadge("3 new", variant: .primary)
        add("badges", row([countBadge, CCBadge("Beta"), CCBadge("Failed", variant: .destructive),
                           CCBadge("Draft", variant: .outline)]), to: col2)

        // ── Column 3: avatars, skeletons, rings, empty state ──
        let photo = CCAvatar(name: "Sam Rivera", image: sampleImage(side: 56), size: .xl, status: .online)
        let ada = CCAvatar(name: "Ada Lovelace", size: .lg, status: .live)
        let alan = CCAvatar(name: "Alan Turing", size: .md, status: .away)
        let grace = CCAvatar(name: "Grace Hopper", size: .sm, status: .busy)
        let mike = CCAvatar(name: "Mike Garland", size: .md)
        add("avatars", row([photo, ada, alan, mike, grace], spacing: CCSpace.md), to: col3)
        let group = CCAvatarGroup(names: ["Ada Lovelace", "Alan Turing", "Grace Hopper",
                                          "Linus Torvalds", "Margaret Hamilton", "Ken Thompson"],
                                  maxVisible: 4, size: .md)
        add("avatarGroup", group, to: col3)

        let skeletonCircle = CCSkeleton(.circle(diameter: 40))
        let skeletonLines = CCSkeleton.lines(2)
        let skeletonRow = row([skeletonCircle, skeletonLines], spacing: CCSpace.md)
        skeletonLines.widthAnchor.constraint(equalTo: skeletonRow.widthAnchor, constant: -(40 + CCSpace.md)).isActive = true
        add("skeletonRow", skeletonRow, to: col3, flex: true)
        let skeletonBlock = CCSkeleton(.block(height: 56))
        add("skeletonBlock", skeletonBlock, to: col3, flex: true)
        let revealed = NSTextField(wrappingLabelWithString:
            "Loaded: 12 captures, 3 shared this week. Skeletons crossfade to content like this.")
        let revealedTheme = CCThemeObservation { [weak revealed] in
            revealed?.textColor = CCTheme.color.mutedForeground
            revealed?.font = CCTheme.font.label
        }
        revealed.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let reveal = CCSkeletonReveal(placeholder: CCSkeleton.lines(3), content: revealed)
        add("skeletonReveal", reveal, to: col3, flex: true)

        let ring = CCProgressRing(diameter: 64)
        ring.doubleValue = 0.35
        let smallRing = CCProgressRing(diameter: 44)
        smallRing.doubleValue = 0.72
        let busyRing = CCProgressRing(diameter: 44)
        busyRing.isIndeterminate = true
        let spinner = CCSpinner()
        spinner.startAnimation(nil)
        let bigSpinner = CCSpinner(diameter: 24)
        bigSpinner.startAnimation(nil)
        add("rings", row([ring, smallRing, busyRing, spinner, bigSpinner], spacing: CCSpace.lg), to: col3)

        let empty = CCEmptyState(
            symbol: "film.stack", title: "No recordings yet",
            message: "Press ⌘⇧R to capture your screen, or drop a video here to import it.",
            primary: CCButton(title: "New Recording", style: .primary),
            secondary: CCButton(title: "Import…", style: .outline)
        )
        add("emptyState", empty, to: col3, flex: true)

        let toaster = CCToaster(in: root)
        toaster.followsPointer = false
        // The user's real pointer must never leak into the probe (a hover
        // wash appeared in a capture wherever the cursor happened to sit).
        window.ignoresMouseEvents = true

        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()

        func snapshot(_ suffix: String, layer: CALayer? = nil, size: CGSize? = nil) {
            guard let layer = layer ?? root.layer else { return }
            let size = size ?? root.bounds.size
            // CARenderer maps the tree 1:1 into its pixel bounds (a 1x image
            // in the corner of the 2x texture) and reads back Y-mirrored.
            // For review-grade captures, scale the tree 2x and pre-flip it
            // for the duration of the render, so the PNG lands upright and
            // retina-sharp. (Restored before the next commit.)
            let prior = layer.transform
            layer.transform = CATransform3DConcat(CATransform3DMakeScale(2, -2, 1),
                                                  CATransform3DMakeTranslation(0, size.height * 2, 0))
            let rendered = CARendererSnapshot.render(layer: layer, size: size, scale: 2)
            layer.transform = prior
            guard let img = rendered else { return }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-capkitx-\(suffix).png")
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out)
            print("CAPKITX capture \(out.path)")
        }
        func snapshotTooltip(_ tip: CCTooltip, _ suffix: String) {
            guard let content = tip.probePanel.contentView, let layer = content.layer else { return }
            snapshot(suffix, layer: layer, size: content.bounds.size)
        }

        let script = Script()
        let tipTop = tipButtons[0].1
        let tipNext = tipButtons[1].1
        var darkColors: [String: CGColor] = [:]
        var darkMaterial: [String: CGColor] = [:]

        // Retheme probes: real layer colors of MOUNTED views.
        let colorProbes: [(String, () -> CGColor?)] = [
            ("accordion", { accordion.probeSurfaceLayer?.backgroundColor }),
            ("callout", { callouts[1].probeSurfaceLayer?.backgroundColor }),
            ("textArea", { textArea.layer?.backgroundColor }),
            ("stepperWell", { fps.probeWellLayer?.backgroundColor }),
            ("stepperDigits", { fps.probeLabel.probeColumns.first?.foregroundColor }),
            ("radioWell", { radio.probeWellLayer(0)?.backgroundColor }),
            ("avatarDisc", { mike.probeFaceLayer?.backgroundColor }),
            ("statusCutout", { alan.probeStatusDot.borderColor }),
            ("skeleton", { skeletonBlock.layer?.backgroundColor }),
            ("ringGroove", { (ring.probeGrooveLayer.colors?[1]).map { $0 as! CGColor } }),
            ("toastCard", { toaster.toasts.first?.probeCardLayer?.backgroundColor }),
            ("tooltip", { tipTop.probeBubbleLayer?.backgroundColor }),
            ("emptyTile", { empty.probeTileLayer?.backgroundColor }),
            ("tabsList", { tabs.probeList.layer?.backgroundColor }),
            ("spinner", { spinner.probeArcLayer.strokeColor }),
            // The accent fill is theme-invariant by design; the groove is not.
            ("progressTrack", { bar.layer?.backgroundColor }),
        ]
        let materialProbes: [(String, () -> CALayer?)] = [
            ("accordion", { accordion.probeSurfaceLayer }),
            ("callout", { callouts[1].probeSurfaceLayer }),
            ("textArea", { textArea.layer }),
            ("stepperWell", { fps.probeWellLayer }),
            ("emptyWell", { empty.probeWellLayer }),
            ("skeleton", { skeletonBlock.layer }),
        ]

        // 1. Topology + material presence (settled mount, dark).
        script.then(0.5) {
            let degenerate = components.filter { _, view in
                let frame = view.convert(view.bounds, to: root)
                return frame.width < 10 || frame.height < 1 || !root.bounds.intersects(frame)
            }
            for (name, view) in degenerate {
                print("CAPKITX degenerate \(name) frame=\(view.convert(view.bounds, to: root))")
            }
            check("topology", degenerate.isEmpty, "components=\(components.count) degenerate=\(degenerate.count)")

            let expected: [(String, CALayer?, Int)] = [
                ("accordion", accordion.probeSurfaceLayer, 2),
                ("callout", callouts[0].probeSurfaceLayer, 2),
                ("tooltip", tipTop.probeSurfaceLayer, 2),
                ("textArea", textArea.layer, 3),
                ("stepperWell", fps.probeWellLayer, 3),
                ("stepperKey", fps.probeKeyLayers.first, 1),
                ("radioWell", radio.probeWellLayer(0), 3),
                ("radioDot", radio.probeDotLayer(0), 1),
                ("avatarDisc", mike.probeFaceLayer, 2),
                ("skeleton", skeletonBlock.layer, 3),
                ("emptyWell", empty.probeWellLayer, 3),
                ("emptyTile", empty.probeTileLayer, 1),
                ("progressFill", bar.probeFillLayer, 1),
            ]
            let wrong = expected.filter { materialStyle($0.1) != $0.2 }
            for (name, layer, style) in wrong {
                print("CAPKITX material \(name) expected=\(style) got=\(String(describing: materialStyle(layer)))")
            }
            // Content never themes: the photo avatar carries NO material.
            let photoBare = materialStyle(photo.probeFaceLayer) == nil
            check("material", wrong.isEmpty && photoBare,
                  "dressed=\(expected.count - wrong.count)/\(expected.count) photoBare=\(photoBare)")

            // Tooltip delay: a cold hover must NOT show instantly.
            tipButtons[2].1.hoverBegan()
            let delayed = !tipButtons[2].1.isShown
            tipButtons[2].1.hide(animated: false)
            check("tooltip-delay", delayed, "shownImmediately=\(!delayed)")
        }

        // 2. Toast entrance — springs up from the bottom edge.
        var firstToast: CCToast?
        var flash: CCToast?
        var toastFromY: CGFloat = 0
        script.then(0.2) {
            firstToast = toaster.show(title: "Disk almost full", message: "Free up space to keep recording.",
                                      variant: .warning, duration: 30)
            // The FLIP spring runs from the offstage delta (below the
            // overlay's bottom edge) to 0.
            toastFromY = -(firstToast.map { $0.frame.minY + $0.frame.height + 8 } ?? 0)
        }
        script.then(0.06) {
            guard let toast = firstToast else { check("toast-entrance", false, "no toast"); return }
            let ty = scalar(toast.layer, "transform.translation.y")
            let alpha = presented(toast.layer)?.opacity ?? -1
            let mid = ty < -1 && ty > toastFromY + 1 && alpha > 0.02 && alpha < 0.98
            check("toast-entrance", mid, String(format: "ty@60ms=%.1f from=%.1f opacity=%.2f", ty, toastFromY, alpha))
        }
        script.then(0.35) {
            toaster.show(title: "Uploading to Library…", message: "3 of 12 clips", duration: 30)
        }
        script.then(0.3) {
            toaster.show(title: "Recording saved", message: "launch-demo.mov · 1:24",
                         variant: .success, action: .init(title: "Undo") {}, duration: 30)
        }
        // 3. Stack compression settled: older toasts shrink behind the front.
        script.then(0.75) {
            let scales = toaster.toasts.map { scalar($0.probeCardLayer, "transform.scale.x") }
            let peeks = toaster.toasts.map { $0.frame.maxY }
            let compressed = scales.count == 3 && abs(scales[0] - 1) < 0.01
                && scales[1] < 0.97 && scales[2] < scales[1]
                && peeks[1] > peeks[0] && peeks[2] > peeks[1]
            check("toast-stack", compressed,
                  "scales=\(scales.map { String(format: "%.3f", $0) }) tops=\(peeks.map { Int($0) })")
            let counting = (toaster.toasts.last?.probeRemaining ?? 1) < 0.99
            check("toast-countdown", counting,
                  String(format: "remaining=%.3f", toaster.toasts.last?.probeRemaining ?? -1))
            // A short-lived fourth toast: it must dismiss ITSELF (and the
            // stack must settle back to three).
            flash = toaster.show(title: "Link copied", duration: 0.8)
        }

        // 4. Accordion growth — bounce overshoot, top pinned, chevron spring.
        var accordionSampler: Sampler?
        var accordionTarget: CGFloat = 0
        var accordionTop: CGFloat = 0
        var chevronMid = false
        script.then(0.3) {
            let body = accordion.probeBody(1)
            accordionTop = presentedTop(accordion.probeHeader(1), in: root)
            accordionSampler = Sampler {
                [presentedHeight(body), presentedTop(accordion.probeHeader(1), in: root),
                 presentedTop(body, in: root)]
            }
            accordion.setExpanded(true, at: 1)
            accordionTarget = body.probeTargetHeight
        }
        script.then(0.06) {
            let angle = scalar(accordion.probeChevronLayer(1), "transform.rotation.z")
            chevronMid = angle > 0.05 && angle < .pi - 0.05
            print(String(format: "CAPKITX accordion chevron@60ms=%.3frad", angle))
        }
        script.then(0.6) {
            accordionSampler?.stop()
            let samples = accordionSampler?.samples ?? []
            let heights = samples.map { $0[0] }
            let peak = heights.max() ?? 0
            let settled = presentedHeight(accordion.probeBody(1))
            let topDrift = samples.map { abs($0[1] - accordionTop) }.max() ?? .infinity
            let midFlight = heights.contains { $0 > 5 && $0 < accordionTarget - 5 }
            let ok = peak > accordionTarget + 1 && abs(settled - accordionTarget) < 1
                && topDrift < 0.5 && midFlight && chevronMid
            check("accordion-growth", ok, String(format:
                "target=%.1f peak=%.1f settled=%.1f topDrift=%.2f midFlight=%@ chevronMid=%@ samples=%d",
                accordionTarget, peak, settled, topDrift, midFlight ? "y" : "n", chevronMid ? "y" : "n",
                samples.count))
        }

        // 5. Tabs — chip glide + directional pane crossfade.
        var chipFrom: CGFloat = 0, chipTo: CGFloat = 0
        script.then(0.1) {
            let chip = tabs.probeList.probeSelectionLayer
            chipFrom = chip.position.x
            tabs.selectedIndex = 1
            chipTo = chip.position.x
        }
        script.then(0.06) {
            let chipX = scalar(tabs.probeList.probeSelectionLayer, "position.x")
            let outAlpha = presented(tabs.probePane(0).layer)?.opacity ?? -1
            let inAlpha = presented(tabs.probePane(1).layer)?.opacity ?? -1
            let inX = scalar(tabs.probePane(1).layer, "transform.translation.x")
            let outX = scalar(tabs.probePane(0).layer, "transform.translation.x")
            let glide = chipX > chipFrom + 1 && chipX < chipTo - 1
            let fade = outAlpha > 0.02 && outAlpha < 0.98 && inAlpha > 0.02 && inAlpha < 0.98
            // Travel direction: moving right → incoming arrives from the
            // right (+x), outgoing leaves left (−x).
            let slide = inX > 0.5 && inX < CCTabs.slideDistance - 0.5 && outX < -0.5
            check("tabs-switch", glide && fade && slide, String(format:
                "chip %.1f→%.1f @60ms=%.1f out=%.2f in=%.2f inX=%.1f outX=%.1f",
                chipFrom, chipTo, chipX, outAlpha, inAlpha, inX, outX))
        }

        // 6. Radio — the incoming dot springs in, the outgoing one shrinks.
        script.then(0.5) {
            check("tabs-onChange", tabChanges.isEmpty, "programmatic selection is silent")
            radio.selectedIndex = 2
        }
        script.then(0.06) {
            let incoming = scalar(radio.probeDotLayer(2), "transform.scale.x")
            let outgoing = scalar(radio.probeDotLayer(0), "transform.scale.x")
            let ok = incoming > 0.25 && incoming < 0.97 && outgoing > 0.02 && outgoing < 0.97
            check("radio-dot", ok, String(format: "in@60ms=%.3f out@60ms=%.3f", incoming, outgoing))
        }

        // 7. Stepper — digits roll in the direction of change.
        script.then(0.4) {
            fps.value = 31
        }
        script.then(0.06) {
            let incoming = fps.probeLabel.lastIncoming
            let ty = scalar(incoming.first, "transform.translation.y")
            // Flipped label: +y is down — an increase rises in from below.
            let ok = incoming.count == 1 && ty > 0.5 && ty < 16
            check("stepper-roll", ok, String(format: "rolled=%d ty@60ms=%.2f text=%@",
                                             incoming.count, ty, fps.probeLabel.text))
        }

        // 8. Progress ring — the arc springs; the label counts.
        var ringFrom: CGFloat = 0
        script.then(0.4) {
            ringFrom = ring.probeArcLayer.strokeEnd
            ring.doubleValue = 0.8
        }
        script.then(0.06) {
            let stroke = scalar(ring.probeArcLayer, "strokeEnd")
            let label = ring.probeLabel.stringValue
            let counting = label != "35%" && label != "80%"
            check("ring-arc", stroke > ringFrom + 0.01 && stroke < 0.79 && counting,
                  String(format: "strokeEnd %.2f→0.80 @60ms=%.3f label=%@", ringFrom, stroke, label))
        }

        // 9. Tooltip — scale-in pivoting on the edge facing the target, and
        // the instant hand-off to a neighbor.
        script.then(0.5) {
            tipTop.show(tracking: false)
        }
        script.then(0.05) {
            guard let bubble = tipTop.probeBubbleLayer else { check("tooltip-scale", false); return }
            let scale = scalar(bubble, "transform.scale.x")
            let shown = presented(bubble)?.frame ?? .zero
            let model = bubble.frame
            // Flipped to BELOW its target → the TOP edge faces it and stays
            // put (unflipped content: top = maxY); the bottom travels.
            let pinned = abs(shown.maxY - model.maxY) < 0.5
            let travels = shown.minY > model.minY + 0.3
            let ok = scale > 0.905 && scale < 0.995 && pinned && travels
            check("tooltip-scale", ok, String(format:
                "scale@50ms=%.3f facingEdgeDrift=%.2f farEdgeTravel=%.2f",
                scale, abs(shown.maxY - model.maxY), shown.minY - model.minY))
            // Hand-off: with one up, the neighbor shows at once.
            tipNext.hoverBegan()
            check("tooltip-handoff", tipNext.isShown && !tipTop.isShown,
                  "next=\(tipNext.isShown) previous=\(tipTop.isShown)")
            tipNext.hide(animated: false)
        }

        // 10. Text area — grows with the bounce, top pinned.
        var areaSampler: Sampler?
        var areaTop: CGFloat = 0
        var areaStart: CGFloat = 0
        script.then(0.4) {
            areaStart = textArea.frame.height
            areaTop = presentedTop(textArea, in: root)
            areaSampler = Sampler { [presentedHeight(textArea), presentedTop(textArea, in: root)] }
            textArea.text = "Intro: open on the dashboard.\nThen zoom to the export button.\nCut the pause at 0:42.\nEnd on the share sheet."
        }
        script.then(0.6) {
            areaSampler?.stop()
            let samples = areaSampler?.samples ?? []
            let heights = samples.map { $0[0] }
            let target = textArea.probeFittedHeight
            let peak = heights.max() ?? 0
            let topDrift = samples.map { abs($0[1] - areaTop) }.max() ?? .infinity
            let midFlight = heights.contains { $0 > areaStart + 2 && $0 < target - 2 }
            let settled = textArea.frame.height
            let ok = target > areaStart + 10 && peak > target + 0.5 && midFlight
                && topDrift < 0.5 && abs(settled - target) < 1
            check("textarea-growth", ok, String(format:
                "start=%.1f target=%.1f peak=%.1f settled=%.1f topDrift=%.2f midFlight=%@",
                areaStart, target, peak, settled, topDrift, midFlight ? "y" : "n"))
        }

        // 11. Toast stack fans out on hover (the hover seam).
        var fanFrom: CGFloat = 0
        script.then(0.1) {
            fanFrom = toaster.toasts[1].frame.minY
            toaster.setExpanded(true)
        }
        script.then(0.06) {
            let second = toaster.toasts[1]
            let visualY = second.frame.minY + scalar(second.layer, "transform.translation.y")
            let target = second.frame.minY
            let ok = visualY > min(fanFrom, target) + 0.5 && visualY < max(fanFrom, target) - 0.5
            // Hovering pauses every countdown (the hairline freezes).
            let paused = toaster.toasts.allSatisfy {
                $0.probeCountdownLayer.animation(forKey: "cctoast.countdown") == nil
            }
            check("toast-fan", ok && paused, String(format: "y %.1f→%.1f @60ms=%.1f paused=%@",
                                                    fanFrom, target, visualY, paused ? "y" : "n"))
        }

        // 12. Badge — count change pops + crossfades + width glides.
        var badgeFrom: CGFloat = 0
        script.then(0.45) {
            badgeFrom = countBadge.frame.width
            countBadge.text = "12 new"
        }
        script.then(0.06) {
            let scale = scalar(countBadge.layer, "transform.scale.x")
            let width = presented(countBadge.layer)?.bounds.width ?? 0
            let target = countBadge.intrinsicContentSize.width
            let ok = scale > 0.88 && scale < 0.995 && width > badgeFrom + 0.5 && width < target + 6
            check("badge-pop", ok, String(format: "scale@60ms=%.3f width %.1f→%.1f @60ms=%.1f",
                                          scale, badgeFrom, target, width))
        }

        // 13. Progress bar — the fill springs.
        var barFrom: CGFloat = 0
        script.then(0.4) {
            barFrom = bar.probeFillWidth
            bar.doubleValue = 0.9
        }
        script.then(0.06) {
            let width = bar.probeFillWidth
            let target = bar.bounds.width * 0.9
            let sweepX = busyBar.probeFillX
            check("progress-spring", width > barFrom + 1 && width < target - 1,
                  String(format: "fill %.1f→%.1f @60ms=%.1f sweepX=%.1f", barFrom, target, width, sweepX))
        }

        // 14. Skeleton pulse (opacity, not a sweep) + empty-state stagger.
        var pulseA: Float = 0
        script.then(0.1) {
            pulseA = skeletonBlock.probePulseOpacity
            empty.playEntrance()
        }
        script.then(0.07) {
            let pieces = empty.probePieces
            let first = presented(pieces.first?.layer)?.opacity ?? -1
            let last = presented(pieces.last?.layer)?.opacity ?? -1
            let rise = scalar(pieces.first?.layer, "transform.translation.y")
            // Staggered: the tile is well on its way while the actions,
            // three beats later, haven't started.
            let ok = first > 0.05 && first < 0.99 && last < 0.05 && rise < -0.3 && rise > -8
            check("empty-stagger", ok, String(format: "tile=%.2f actions=%.2f tileRise=%.2f",
                                              first, last, rise))
        }
        script.then(0.33) {
            let pulseB = skeletonBlock.probePulseOpacity
            let ok = abs(pulseA - pulseB) > 0.01 && pulseA >= 0.49 && pulseB >= 0.49
                && pulseA <= 1.001 && pulseB <= 1.001
            check("skeleton-pulse", ok, String(format: "opacity %.3f → %.3f (0.4s apart)", pulseA, pulseB))
        }

        // 15. Callout dismiss — collapses (bottom edge rises), top pinned.
        var calloutSampler: Sampler?
        var calloutTop: CGFloat = 0
        var calloutStart: CGFloat = 0
        var belowStart: CGFloat = 0
        script.then(0.1) {
            calloutStart = doomed.frame.height
            calloutTop = presentedTop(doomed, in: root)
            belowStart = presentedTop(bar, in: root)
            calloutSampler = Sampler { [presentedHeight(doomed), presentedTop(doomed, in: root)] }
            doomed.dismiss()
        }
        script.then(0.5) {
            calloutSampler?.stop()
            let samples = calloutSampler?.samples ?? []
            let heights = samples.map { $0[0] }
            let midFlight = heights.contains { $0 > 4 && $0 < calloutStart - 4 }
            let topDrift = samples.filter { $0[0] > 1 }.map { abs($0[1] - calloutTop) }.max() ?? .infinity
            let gone = doomed.superview == nil
            // The content below closes up by exactly the callout + one gap.
            let belowNow = presentedTop(bar, in: root)
            let closed = belowNow - belowStart
            let ok = midFlight && topDrift < 0.5 && gone && abs(closed - (calloutStart + 14)) < 1
            check("callout-dismiss", ok, String(format:
                "start=%.1f midFlight=%@ topDrift=%.2f removed=%@ stackClosed=%.1f",
                calloutStart, midFlight ? "y" : "n", topDrift, gone ? "y" : "n", closed))
        }

        // 16. Avatar group hover spread + live pulse + skeleton reveal.
        var spreadFrom: CGFloat = 0
        script.then(0.1) {
            spreadFrom = group.probeMembers[2].frame.minX
            group.setSpread(true)
            reveal.reveal()
        }
        script.then(0.06) {
            let member = group.probeMembers[2]
            let visual = member.frame.minX + scalar(member.layer, "transform.translation.x")
            let spreadOK = visual > spreadFrom + 0.5 && visual < member.frame.minX - 0.5
            let pulse = ada.probePulseLayer
            let haloScale = scalar(pulse, "transform.scale.x")
            let breathing = pulse.animation(forKey: "ccavatar.pulse") != nil
            let placeholderAlpha = presented(reveal.placeholder.layer)?.opacity ?? -1
            check("avatar-spread", spreadOK, String(format: "x %.1f→%.1f @60ms=%.1f",
                                                    spreadFrom, member.frame.minX, visual))
            check("avatar-live-pulse", breathing && haloScale > 1.001 && haloScale < 2.3,
                  String(format: "haloScale=%.3f", haloScale))
            check("skeleton-reveal", placeholderAlpha > 0.02 && placeholderAlpha < 0.98 && !reveal.content.isHidden,
                  String(format: "placeholder@60ms=%.2f", placeholderAlpha))
        }
        script.then(0.5) {
            let contentAlpha = presented(reveal.content.layer)?.opacity ?? -1
            let settled = reveal.placeholder.isHidden && contentAlpha > 0.99
                && abs(reveal.frame.height - reveal.content.frame.height) < 1
            check("skeleton-reveal-settled", settled, String(format: "content=%.2f height=%.1f/%.1f",
                  contentAlpha, reveal.frame.height, reveal.content.frame.height))
            // The 0.8s toast dismissed itself; the stack is back to three.
            let flashGone = flash.map { !toaster.toasts.contains($0) && $0.superview == nil } ?? false
            check("toast-autodismiss", flashGone && toaster.toasts.count == 3,
                  "gone=\(flashGone) remaining=\(toaster.toasts.count)")
            // Settle everything for the captures, which come LAST: a
            // CARenderer capture re-hosts the live layer tree and the
            // window's next commit drops every in-flight animation, so any
            // mid-flight sample taken after one reads a snapped value.
            group.setSpread(false)
            toaster.setExpanded(false)
            tipTop.show(tracking: false)
        }
        script.then(0.7) {
            // Smart placement: the top-row target has no room above → flips.
            check("tooltip-flip", tipTop.resolvedPlacement == .bottom,
                  "preferred=top resolved=\(tipTop.resolvedPlacement)")
            snapshot("dark")
            snapshotTooltip(tipTop, "tooltip-dark")
        }

        // 17. Live retheme dark → light, from real layer colors.
        script.then(0.1) {
            for (name, probe) in colorProbes { if let color = probe() { darkColors[name] = color } }
            for (name, probe) in materialProbes { if let color = materialMid(probe()) { darkMaterial[name] = color } }
            CCTheme.setMode(.light, persist: false)
            root.layoutSubtreeIfNeeded()
            var unchanged: [String] = []
            for (name, probe) in colorProbes {
                guard let before = darkColors[name], let after = probe() else { unchanged.append(name + "(nil)"); continue }
                if before == after { unchanged.append(name) }
            }
            for (name, probe) in materialProbes {
                guard let before = darkMaterial[name], let after = materialMid(probe()) else {
                    unchanged.append("mat." + name + "(nil)"); continue
                }
                if before == after { unchanged.append("mat." + name) }
            }
            check("retheme", unchanged.isEmpty,
                  "probes=\(colorProbes.count + materialProbes.count) unchanged=\(unchanged)")
            _ = backgroundObservation
            // The light capture shows the fanned-out (hovered) stack.
            toaster.setExpanded(true)
        }
        script.then(0.6) {
            snapshot("light")
            snapshotTooltip(tipTop, "tooltip-light")
            tipTop.hide(animated: false)
        }

        // 18. Responsive — shrink the window; flexible components track the
        // resolved column width, nothing degenerates, toasts re-anchor.
        var wideWidths: [String: CGFloat] = [:]
        script.then(0.1) {
            for (name, view, _) in flexible where view.superview != nil { wideWidths[name] = view.alignmentRect(forFrame: view.frame).width }
            window.setContentSize(NSSize(width: 900, height: 940))
            root.layoutSubtreeIfNeeded()
            var misTracked: [String] = []
            var narrowed = true
            for (name, view, column) in flexible where view.superview != nil {
                let width = view.alignmentRect(forFrame: view.frame).width
                let target = column.frame.width - 40
                if abs(width - target) > 0.5 { misTracked.append("\(name)=\(width)/\(target)") }
                if (wideWidths[name] ?? 0) - width < 60 { narrowed = false }
            }
            let degenerate = components.filter { _, view in
                guard view.superview != nil else { return false }
                let frame = view.convert(view.bounds, to: root)
                return frame.width < 10 || frame.height < 1 || !root.bounds.intersects(frame)
            }.map(\.0)
            let front = toaster.toasts.first?.frame ?? .zero
            let toastAnchored = abs(front.maxX - (root.bounds.width - CCToaster.inset)) < 0.5
            let body = accordion.probeBody(1)
            let collapsibleTracks = abs(body.frame.height - body.probeTargetHeight) < 1
            let ok = misTracked.isEmpty && degenerate.isEmpty && narrowed && toastAnchored
                && collapsibleTracks && root.bounds.width < 1100
            check("responsive", ok,
                  "root=\(root.bounds.width) misTracked=\(misTracked) degenerate=\(degenerate) "
                  + "narrowed=\(narrowed) toastAnchored=\(toastAnchored) collapsibleTracks=\(collapsibleTracks)")
        }
        // Capture a beat later: a CARenderer snapshot in the same turn as a
        // resize renders blank.
        script.then(0.35) {
            // Structural: after the shrink every callout's description has
            // RE-WRAPPED to fit its frame (a parent-driven wrap width reads
            // the child's stale frame and clips the text — shipped once in
            // this very kit build, caught by eye), and a horizontal radio
            // group hugs its items instead of stretching one of them.
            let clipped = callouts.enumerated().filter { !$0.element.probeMessageFits }.map { "callout\($0.offset)" }
            check("text-rewrap", clipped.isEmpty, "clipped=\(clipped)")
            let hug = abs(radioRow.frame.width - radioRow.fittingSize.width)
            check("radio-hug", hug < 1, String(format: "frame=%.1f fitting=%.1f",
                                               radioRow.frame.width, radioRow.fittingSize.width))
            snapshot("narrow")
            let failed = results.filter { !$0.1 }.map(\.0)
            if !failed.isEmpty { print("CAPKITX failed: \(failed)") }
            print(failed.isEmpty ? "CAPKITX PASS" : "CAPKITX FAIL")
            _ = revealedTheme
            exit(failed.isEmpty ? 0 : 1)
        }

        script.run()
        app.run()
        exit(0)
    }
}
