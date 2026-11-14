#if DEBUG
import UIKit

/// `-kitGallery`: every CCKit component in the SAME order and with the same
/// content as the Mac's capkit gallery (CCKitGalleryHarness), for side-by-side
/// style comparison. Dark mirrors the Mac's dark capture (toggle/checkbox off,
/// field focused); light mirrors its light capture (toggle/checkbox on, the
/// form row showing its error).
final class KitGalleryViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let field = CCField(placeholder: "Project name", value: "Launch demo")
    private let toggle = CCToggle(isOn: false)
    private let checkbox = CCCheckbox(title: "Also export captions")
    private let formField = CCField(placeholder: "you@studio.com")
    private lazy var formRow = CCFormRow(label: "Email", control: formField, hint: "Receipts land here.")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        let buttons = FlowRow(views: [
            CCButton(title: "Primary", style: .primary),
            CCButton(title: "Secondary", style: .secondary),
            CCButton(title: "Outline", style: .outline),
            CCButton(title: "Ghost", style: .ghost),
            CCButton(title: "Link", style: .link),
            CCButton(title: "Delete", style: .destructive),
        ])
        let gear = CCButton(symbol: "gear", style: .secondary)
        gear.accessibilityLabelOverride = "Settings"
        let next = CCButton(title: "Next", symbol: "chevron-right", style: .outline)
        next.symbolPlacement = .trailing
        let variants = FlowRow(views: [
            CCButton(title: "Copy", style: .secondary, size: .sm),
            CCButton(title: "Export", style: .primary, size: .lg),
            gear,
            CCButton(title: "Record", symbol: "record", style: .primary, radius: .full),
            next,
        ])
        let segmented = CCSegmented(segments: ["Fit", "Fill", "Stretch"], selectedIndex: 1)
        let pill = CCSegmented(segments: ["All · 49", "Videos · 25", "Notes"], selectedIndex: 0, radius: .full)
        let slider = CCSlider(title: "Volume", value: 0.65)
        let select = CCSelect(options: ["Draft", "Standard", "High", "Lossless"], selectedIndex: 1)
        select.prompt = "Quality"
        select.presenter = self
        let badges = UIStackView(arrangedSubviews: [
            CCBadge("Beta"), CCBadge("Live", variant: .primary), CCBadge("Failed", variant: .destructive), CCBadge("Draft", variant: .outline),
        ])
        badges.spacing = CCSpace.sm
        let divider = CCDivider()
        let progress = CCProgressBar()
        let spinner = CCSpinner(diameter: 18)
        spinner.startAnimating()
        let card = CCCard()
        let cardStack = UIStackView(arrangedSubviews: [
            ccLabel("Recording", font: CCFont.header, color: CCTheme.color.foreground),
            ccLabel("Card body row", font: CCFont.label, color: CCTheme.color.foreground),
        ])
        cardStack.axis = .vertical
        cardStack.spacing = CCSpace.sm
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.md + 2),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.md),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.md + 2),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.md - 2),
        ])
        let combobox = CCSelect(options: ["MacBook Display", "Studio Display", "iPhone 16 Pro", "iPad Air", "External Camera"], selectedIndex: 0)
        combobox.prompt = "Select a device"
        combobox.presenter = self
        let search = CCSearchField(placeholder: "Search captures… (⌘K)")
        let pad = CCPreviewPad(showsGridDots: true)
        pad.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let components: [UIView] = [buttons, variants, toggle, checkbox, segmented, pill, slider, field, formRow,
                                    select, badges, divider, progress, spinner, card, combobox, search, pad]
        let flexible: [UIView] = [buttons, variants, slider, field, formRow, divider, progress, card, search, pad]
        for view in components {
            stack.addArrangedSubview(view)
            if flexible.contains(where: { $0 === view }) {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        select.widthAnchor.constraint(equalToConstant: 200).isActive = true
        combobox.widthAnchor.constraint(equalToConstant: 200).isActive = true
        progress.value = 0.6
        applyState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyState()
        if ProcessInfo.processInfo.arguments.contains("-kitGallerySnapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.writeSnapshot() }
        }
    }

    /// The whole gallery (taller than the screen) rendered at 3x into
    /// Documents/kit-gallery-<light|dark>.png, for the Mac comparison.
    private func writeSnapshot() {
        let pad: CGFloat = 20
        let size = CGSize(width: stack.bounds.width + pad * 2, height: stack.bounds.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            CCTheme.color.background.resolvedColor(with: traitCollection).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: pad, y: pad)
            stack.layer.render(in: context.cgContext)
        }
        let name = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("kit-gallery-\(name).png")
        try? image.pngData()?.write(to: url)
        print("KITGALLERY wrote \(url.path)")
    }

    /// Mirror the Mac's captured states per theme.
    private func applyState() {
        let dark = traitCollection.userInterfaceStyle == .dark
        toggle.setOn(!dark, animated: false)
        checkbox.setOn(!dark, animated: false)
        formRow.setError(dark ? nil : "A name is required")
        if dark {
            // Focused (ink ring) without the system keyboard covering the gallery.
            field.inputView = UIView(frame: .zero)
            field.inputAccessoryView = nil
            _ = field.becomeFirstResponder()
            field.selectAll(nil)
        }
    }
}

/// A row that wraps its views onto extra lines when they don't fit.
final class FlowRow: UIView {
    private let items: [UIView]
    private let spacing: CGFloat = CCSpace.sm
    private var height: NSLayoutConstraint!

    init(views: [UIView]) {
        items = views
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: 44)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        // Rows are centre-aligned vertically, like an NSStackView row.
        var row: [(UIView, CGSize)] = []
        func flush() {
            for (view, size) in row {
                view.frame.origin.y = y + (rowHeight - size.height) / 2
            }
            y += rowHeight + spacing
            x = 0; rowHeight = 0; row = []
        }
        for view in items {
            let size = view.intrinsicContentSize
            if x > 0, x + size.width > bounds.width { flush() }
            view.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
            row.append((view, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        flush()
        let total = max(0, y - spacing)
        if abs(height.constant - total) > 0.5 {
            height.constant = total
        }
    }
}
#endif
