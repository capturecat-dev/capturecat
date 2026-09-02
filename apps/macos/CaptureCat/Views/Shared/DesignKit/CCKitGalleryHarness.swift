import AppKit

/// Headless acceptance probe for the whole CCKit component set.
///
///   CaptureCat --capkit-shot
///
/// Builds a gallery of every kit component in the DARK theme, then asserts the
/// three things the visual gates have been burned by before:
///  • topology — every component resolves a non-degenerate frame inside the
///    real gallery stack (not a bare pre-sized window per component);
///  • live theming — switching to the LIGHT theme recolors already-mounted
///    views in place (sampled from actual layer colors, not the token table);
///  • motion — a toggled CCToggle's thumb is genuinely mid-flight shortly
///    after the flip, not snapped to its endpoint;
///  • responsiveness — the window is then SHRUNK and every flexible
///    component must track the new width exactly, with nothing degenerate
///    at the narrow size (a settled 560pt matrix proved nothing about
///    resize behavior, per the static-frames failure mode).
/// Saves settled dark + light + narrow captures beside the report. DEBUG tooling.
@MainActor
enum CCKitGalleryHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        CCTheme.setMode(.dark, persist: false)

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 560, height: 1180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = CCTheme.color.background.cgColor
        window.contentView = root
        let backgroundObservation = CCThemeObservation { [weak root] in
            root?.layer?.backgroundColor = CCTheme.color.background.cgColor
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.md
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // — every component, one gallery —
        let buttons = NSStackView(views: [
            CCButton(title: "Primary", style: .primary),
            CCButton(title: "Secondary", style: .secondary),
            CCButton(title: "Outline", style: .outline),
            CCButton(title: "Ghost", style: .ghost),
            CCButton(title: "Link", style: .link),
            CCButton(title: "Delete", style: .destructive),
        ])
        buttons.spacing = CCSpace.sm

        // Size scale + icon variants: leading/trailing symbol, icon-only
        // square, capsule radius override.
        let iconButton = CCButton(symbol: "gearshape", style: .secondary)
        let capsuleButton = CCButton(title: "Record", symbol: "record.circle",
                                      style: .primary, radius: .full)
        let trailingButton = CCButton(title: "Next", symbol: "chevron.right",
                                       style: .outline, symbolPlacement: .trailing)
        let smallButton = CCButton(title: "Copy", style: .secondary, size: .sm)
        let largeButton = CCButton(title: "Export", style: .primary, size: .lg)
        let buttonVariants = NSStackView(views: [
            smallButton, largeButton, iconButton, capsuleButton, trailingButton,
        ])
        buttonVariants.spacing = CCSpace.sm

        let toggle = CCToggle(isOn: false)
        let checkbox = CCCheckbox(title: "Also export captions")
        let segmented = CCSegmented(segments: ["Fit", "Fill", "Stretch"], selectedIndex: 1)
        let pillSegmented = CCSegmented(segments: ["All · 49", "Videos · 25", "Notes"],
                                        selectedIndex: 0, radius: .full, hoverWash: true)
        let slider = CCSlider(title: "Volume")
        slider.doubleValue = 0.65
        let field = CCField(placeholder: "Project name", value: "Launch demo")
        let formField = CCField(placeholder: "you@studio.com")
        let formRow = CCFormRow(label: "Email", control: formField,
                                 hint: "Receipts land here.")
        let select = CCSelect(placeholder: "Quality…")
        select.options = ["Draft", "Standard", "High", "Lossless"].map { .init(title: $0) }
        select.selectedIndex = 1
        let badges = NSStackView(views: [
            CCBadge("Beta"),
            CCBadge("Live", variant: .primary),
            CCBadge("Failed", variant: .destructive),
            CCBadge("Draft", variant: .outline),
        ])
        badges.spacing = CCSpace.sm
        let divider = CCDivider()
        let progress = CCProgressBar()
        progress.doubleValue = 0.6
        let spinner = CCSpinner()
        spinner.startAnimation(nil)
        let card = CCCard(title: "Recording")
        card.addContent(NSTextField(labelWithString: "Card body row"))
        let combobox = CCCombobox(placeholder: "Select a device…")
        combobox.options = ["MacBook Display", "Studio Display", "iPhone 16 Pro",
                            "iPad Air", "External Camera"].map { .init(title: $0) }
        combobox.selectedIndex = 0
        let search = CCSearchField(placeholder: "Search captures… (⌘K)")
        let previewPad = CCPreviewPad(showsGridDots: true)
        previewPad.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let components: [(String, NSView)] = [
            ("buttons", buttons), ("buttonVariants", buttonVariants),
            ("toggle", toggle), ("checkbox", checkbox), ("segmented", segmented),
            ("pillSegmented", pillSegmented),
            ("slider", slider), ("field", field), ("formRow", formRow),
            ("select", select), ("badges", badges),
            ("divider", divider), ("progress", progress), ("spinner", spinner),
            ("card", card), ("combobox", combobox),
            ("search", search), ("previewPad", previewPad),
        ]
        // Components that must TRACK the available width (the responsive
        // contract); the rest size themselves and merely must not degenerate.
        let flexible: [(String, NSView)] = [
            ("slider", slider), ("field", field), ("formRow", formRow),
            ("divider", divider), ("progress", progress), ("card", card),
            ("search", search), ("previewPad", previewPad),
        ]
        for (_, view) in components {
            stack.addArrangedSubview(view)
            if flexible.contains(where: { $0.1 === view }) {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            }
        }
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()

        // 1b. Field padding — measured on the REAL cell and, later (after the
        // motion sample — focusing a field this early poisoned the toggle's
        // spring commit), on the REAL focused field editor.
        let cellPadX = (field.cell?.drawingRect(forBounds: field.bounds).minX ?? 0) - field.bounds.minX
        var editorPadX: CGFloat = -1
        func measureEditorPad() {
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView, let sup = editor.superview {
                editorPadX = field.convert(editor.frame, from: sup).minX - field.bounds.minX
            }
            window.makeFirstResponder(nil)
        }

        // 1. Topology — every component resolves a real frame in the stack.
        let degenerate = components.filter { _, view in
            let frame = view.convert(view.bounds, to: root)
            return frame.width < 10 || frame.height < 1 || !root.bounds.intersects(frame)
        }
        for (name, _) in degenerate { print("CAPKIT degenerate component: \(name)") }

        // 1a. Button variant geometry — the size scale resolves distinct
        // heights, the icon-only button is square, `.full` radius is a
        // capsule (half the resolved height).
        let sizesOK = smallButton.bounds.height == 24
            && largeButton.bounds.height == 36
            && iconButton.bounds.width == iconButton.bounds.height
            && abs((capsuleButton.layer?.cornerRadius ?? 0) - capsuleButton.bounds.height / 2) < 0.5
        print("CAPKIT button sizes sm=\(smallButton.bounds.height) lg=\(largeButton.bounds.height) "
            + "iconSquare=\(iconButton.bounds.size) capsuleRadius=\(capsuleButton.layer?.cornerRadius ?? -1) ok=\(sizesOK)")

        // 1c. Radius override — the `.full` segmented resolves as a capsule
        // and its selection chip stays concentric (outer − inset).
        // 1b1. Key shadow present WITHOUT any hover — AppKit reconfigures
        // view backing layers on window attach and drops init-time shadows
        // ("shadows only appear after hovering"); refit must have healed it
        // by the first in-window layout.
        let shadowOK = (largeButton.layer?.shadowOpacity ?? 0) > 0.1
        print("CAPKIT key shadow opacity=\(largeButton.layer?.shadowOpacity ?? -1) ok=\(shadowOK)")

        // 1b2. Material orientation — the recessed shade must sit at the
        // VISUAL top: every ccmat gradient's start point must match its
        // host's LIVE flippedness (a stale creation-time orientation shipped
        // as "the black bottom inside" on sliders and toggles).
        var materialOK = true
        for (name, view) in [("slider", slider as NSView), ("toggle", toggle), ("field", field)] {
            // PRESENCE is part of the assert: a silent `continue` here let
            // "material missing until hover" ship while the gate passed.
            guard let host = view.layer,
                  let baseGrad = host.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer
            else {
                materialOK = false
                print("CAPKIT material MISSING on \(name) (dropped by backing-layer rebuild?)")
                continue
            }
            let expected: CGFloat = host.isGeometryFlipped ? 0 : 1
            if abs(baseGrad.startPoint.y - expected) > 0.01 {
                materialOK = false
                print("CAPKIT material orientation WRONG on \(name): "
                    + "flipped=\(host.isGeometryFlipped) startY=\(baseGrad.startPoint.y)")
            }
        }
        print("CAPKIT material orientation ok=\(materialOK)")

        let pillOuter = pillSegmented.layer?.cornerRadius ?? -1
        let pillChip = pillSegmented.probeSelectionLayer.cornerRadius
        let pillOK = abs(pillOuter - pillSegmented.bounds.height / 2) < 0.5
            && abs(pillChip - (pillOuter - CCSegmented.Size.regular.inset)) < 0.5
        print("CAPKIT pill segmented outer=\(pillOuter) chip=\(pillChip) ok=\(pillOK)")

        func snapshot(_ suffix: String) {
            guard let layer = root.layer,
                  let img = CARendererSnapshot.render(layer: layer, size: root.bounds.size, scale: 2) else { return }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-capkit-\(suffix).png")
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("CAPKIT capture \(out.path)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            snapshot("dark")
            let darkBackground = root.layer?.backgroundColor
            let darkSliderBorder = slider.layer?.borderColor

            // 2. Live theming — flip to light; mounted views must recolor.
            CCTheme.setMode(.light, persist: false)
            root.layoutSubtreeIfNeeded()
            let backgroundChanged = root.layer?.backgroundColor != darkBackground
            let sliderChanged = slider.layer?.borderColor != darkSliderBorder
            print("CAPKIT theme-swap backgroundChanged=\(backgroundChanged) sliderChanged=\(sliderChanged)")

            // 3. Motion — flip the toggle and sample its thumb mid-flight.
            // The checkbox flips in the NEXT beat: sharing the toggle's
            // CATransaction delays the spring's commit enough to skew the
            // tight 50ms window (measured: 12.40 vs the 12.5 floor).
            toggle.isOn = true
            // 70ms, not 50: the grown gallery renders its first frames
            // slower, and at 50ms the thumb reads 12.49–12.54 — riding the
            // 12.5 floor. 70ms clears the edge with the same strict band.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                let thumb = toggle.probeThumbLayer
                let x = (thumb.presentation() ?? thumb).position.x
                // Off center ≈ 11.5, on center ≈ 24.5 — mid-flight is neither.
                let midFlight = x > 12.5 && x < 23.5
                print("CAPKIT toggle thumb x@70ms=\(x) midFlight=\(midFlight)")

                checkbox.isOn = true
                var checkMidFlight = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let check = checkbox.probeCheckLayer
                    let stroke = (check.presentation() ?? check).strokeEnd
                    checkMidFlight = stroke > 0.02 && stroke < 0.98
                    print("CAPKIT checkbox strokeEnd@50ms=\(stroke) midFlight=\(checkMidFlight)")

                    // Only after the motion samples: setError's synchronous
                    // animation-group layout would delay later springs. It
                    // settles (~0.28s) well before the final block reads it.
                    formRow.setError("A name is required")

                    // Park the hover wash on segment 1 now — by the time the
                    // final block hops it to segment 2 (~0.5s later) the wash
                    // is fully faded in, so that hop MUST glide, not appear.
                    pillSegmented.routeHover(to: 1)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    snapshot("light")
                    _ = backgroundObservation

                    // 4. Combobox — drive the REAL popup: open, filter,
                    // keyboard-commit. Asserts the search actually narrows
                    // the list and ↩ selects the active match.
                    measureEditorPad()
                    let fieldPadded = cellPadX >= 6 && editorPadX >= 6
                    print("CAPKIT field padding cell=\(cellPadX) editor=\(editorPadX) ok=\(fieldPadded)")

                    var comboOK = false
                    var picked: Int? = nil
                    combobox.onSelect = { picked = $0 }
                    combobox.open()
                    if let popup = combobox.probePopup {
                        let all = popup.probeRowTitles.count
                        popup.applyFilter("iP")
                        let filtered = popup.probeRowTitles
                        popup.commitActive()
                        comboOK = all == 5
                            && filtered == ["iPhone 16 Pro", "iPad Air"]
                            && picked == 2
                            && combobox.probePopup == nil
                        print("CAPKIT combobox all=\(all) filtered=\(filtered) picked=\(String(describing: picked)) ok=\(comboOK)")
                    } else {
                        print("CAPKIT combobox FAIL popup did not open")
                    }

                    // 5. Select — searchless popup: no search row mounted,
                    // ↓↓ + ↩ commit through the panel's key routing.
                    var selectOK = false
                    var selectPicked: Int? = nil
                    select.onSelect = { selectPicked = $0 }
                    select.open()
                    if let popup = select.probePopup {
                        let searchHidden = !popup.probeSearchVisible
                        _ = popup.probeSendKey(#selector(NSResponder.moveDown(_:)))
                        _ = popup.probeSendKey(#selector(NSResponder.moveDown(_:)))
                        _ = popup.probeSendKey(#selector(NSResponder.insertNewline(_:)))
                        selectOK = searchHidden && selectPicked == 2 && select.probePopup == nil
                        print("CAPKIT select searchHidden=\(searchHidden) picked=\(String(describing: selectPicked)) ok=\(selectOK)")
                    } else {
                        print("CAPKIT select FAIL popup did not open")
                    }

                    // 6. Form row — the error line is visible and the field
                    // border went destructive with it.
                    let errorField = formRow.probeErrorField
                    let errorShown = !errorField.isHidden && errorField.alphaValue > 0.9
                        && formField.isError
                    print("CAPKIT formRow errorShown=\(errorShown)")

                    // 7. Title-swap motion — a longer title must GLIDE the
                    // frame wider, not snap it: sample the layer mid-resize.
                    let widthBefore = smallButton.frame.width
                    smallButton.title = "Copy Link"
                    let widthTarget = smallButton.intrinsicContentSize.width
                    // 8. Glide highlight — the wash appears in place on the
                    // first row, then genuinely GLIDES toward the second
                    // (sampled mid-spring on the presentation layer).
                    let glideHost = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
                    glideHost.wantsLayer = true
                    root.addSubview(glideHost)
                    let rowA = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
                    let rowB = NSView(frame: NSRect(x: 100, y: 30, width: 90, height: 24))
                    glideHost.addSubview(rowA)
                    glideHost.addSubview(rowB)
                    let glide = CCGlideHighlight(host: glideHost)
                    glide.update(row: rowA, active: true)
                    let landedOnA = glide.debugPresentationFrame.midX == rowA.frame.midX
                    glide.update(row: rowB, active: true)

                    // Hop the (long-settled) segmented hover wash 1 → 2; the
                    // same 50ms sample below must catch it mid-spring.
                    let hoverFrom = pillSegmented.probeHoverLayer.frame.midX
                    pillSegmented.routeHover(to: 2)
                    let hoverTo = pillSegmented.probeHoverLayer.frame.midX

                    // Apple press: the surface must tint in place — shade
                    // fading in at the 50ms sample with ZERO movement
                    // (a traveling button was vetoed as un-Apple).
                    if let buttonLayer = largeButton.layer { CCMaterial.press(buttonLayer, down: true) }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let presented = smallButton.layer?.presentation()?.bounds.width ?? -1
                        let resizeMidFlight = presented > widthBefore + 1 && presented < widthTarget - 1
                        print("CAPKIT title-swap width \(widthBefore) -> \(widthTarget) @50ms=\(presented) midFlight=\(resizeMidFlight)")

                        let glideMidX = glide.debugPresentationFrame.midX
                        let glideMidFlight = glideMidX > rowA.frame.midX + 1
                            && glideMidX < rowB.frame.midX - 1
                        print("CAPKIT glide landedOnA=\(landedOnA) midX@50ms=\(glideMidX) midFlight=\(glideMidFlight)")
                        glideHost.removeFromSuperview()

                        let hoverLayer = pillSegmented.probeHoverLayer
                        let hoverMidX = (hoverLayer.presentation() ?? hoverLayer).position.x
                        let hoverMidFlight = hoverMidX > hoverFrom + 1 && hoverMidX < hoverTo - 1
                            && (hoverLayer.presentation() ?? hoverLayer).opacity > 0.9
                        print("CAPKIT segmented hover \(hoverFrom) -> \(hoverTo) midX@50ms=\(hoverMidX) midFlight=\(hoverMidFlight)")

                        let buttonLayer = largeButton.layer
                        let pressTy = (buttonLayer?.presentation() ?? buttonLayer)?
                            .value(forKeyPath: "transform.translation.y") as? CGFloat ?? 99
                        let pressShade = buttonLayer?.sublayers?
                            .first(where: { $0.name == "ccmat.pressShade" })
                        let shadeOpacity = (pressShade?.presentation() ?? pressShade)?.opacity ?? -1
                        let pressMidFlight = abs(pressTy) < 0.01 && shadeOpacity > 0.02
                        print("CAPKIT press darken ty@50ms=\(pressTy) shadeOpacity=\(shadeOpacity) ok=\(pressMidFlight)")
                        if let buttonLayer { CCMaterial.press(buttonLayer, down: false) }

                        // 9. Responsive — shrink the window: every flexible
                        // component must track the resolved width exactly, and
                        // nothing may degenerate at the narrow size. The
                        // window settles WIDER than asked (the six-button
                        // row's natural width outranks the window's ~500
                        // content-size constraints — the standard AppKit
                        // "don't shrink below usable content" floor), so the
                        // contract is measured against the resolved root, not
                        // the requested 380.
                        let wideWidth = slider.frame.width
                        window.setContentSize(NSSize(width: 380, height: 1180))
                        root.layoutSubtreeIfNeeded()
                        let narrowTarget = root.bounds.width - 48
                        // Constraints solve on ALIGNMENT rects; NSTextField
                        // frames carry ~2pt of bezel slop per side, so compare
                        // alignment rects, not frames.
                        let misTracked = flexible.filter {
                            abs($0.1.alignmentRect(forFrame: $0.1.frame).width - narrowTarget) > 0.5
                        }
                        for (name, view) in misTracked {
                            print("CAPKIT responsive mis-tracked: \(name) "
                                + "width=\(view.alignmentRect(forFrame: view.frame).width) target=\(narrowTarget)")
                        }
                        let degenerateNarrow = components.filter { _, view in
                            let frame = view.convert(view.bounds, to: root)
                            return frame.width < 10 || frame.height < 1 || !root.bounds.intersects(frame)
                        }
                        for (name, _) in degenerateNarrow { print("CAPKIT narrow degenerate component: \(name)") }
                        let responsiveOK = misTracked.isEmpty && degenerateNarrow.isEmpty
                            && root.bounds.width < 520            // the resize genuinely landed
                            && stack.frame.width == root.bounds.width
                            && wideWidth - narrowTarget >= 60     // flexible views genuinely narrowed
                        print("CAPKIT responsive wide=\(wideWidth) narrow=\(narrowTarget) "
                            + "root=\(root.bounds.width) ok=\(responsiveOK)")

                        // The capture waits a beat: snapped in the same turn
                        // as the resize it renders BLANK — the views haven't
                        // redrawn into their resized layers yet.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            snapshot("narrow")

                            let pass = degenerate.isEmpty && sizesOK && pillOK && materialOK
                                && shadowOK && backgroundChanged && sliderChanged
                                && midFlight && checkMidFlight && comboOK && selectOK && errorShown
                                && resizeMidFlight && fieldPadded
                                && landedOnA && glideMidFlight && hoverMidFlight && pressMidFlight
                                && responsiveOK
                            print(pass ? "CAPKIT PASS" : "CAPKIT FAIL")
                            exit(pass ? 0 : 1)
                        }
                    }
                }
            }
        }
        app.run()
        exit(0)
    }
}
