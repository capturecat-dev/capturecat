import AppKit

/// CCKit label — shadcn's Label: small, medium-weight, foreground token.
/// Pair it with any control by hand, or let CCFormRow do the pairing.
@MainActor
final class CCLabel: NSTextField {
    private var themeObservation: CCThemeObservation?

    init(_ text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        stringValue = text
        lineBreakMode = .byTruncatingTail
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            let base = CCTheme.font.label
            self.font = NSFont.systemFont(ofSize: base.pointSize, weight: .medium)
            self.textColor = CCTheme.color.foreground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// CCKit form row — shadcn's FormField: label above the control, optional
/// hint below it, and an error line that glides in/out. When the control is a
/// CCField the error state also tints its border destructive, in sync.
///
///     let name = CCField(placeholder: "Project name")
///     let row = CCFormRow(label: "Name", control: name, hint: "Shown in exports")
///     row.setError("A name is required")   // animated in
///     row.setError(nil)                    // animated out
@MainActor
final class CCFormRow: NSView {
    let control: NSView

    private let labelField: CCLabel
    private let hintField = NSTextField(wrappingLabelWithString: "")
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var themeObservation: CCThemeObservation?

    private(set) var errorMessage: String?

    init(label: String, control: NSView, hint: String? = nil) {
        self.control = control
        labelField = CCLabel(label)
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.xs + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        hintField.stringValue = hint ?? ""
        hintField.isHidden = hint == nil
        errorField.isHidden = true
        errorField.alphaValue = 0

        stack.addArrangedSubview(labelField)
        stack.addArrangedSubview(control)
        stack.addArrangedSubview(hintField)
        stack.addArrangedSubview(errorField)
        // The control stretches to the row's width; text lines hug it.
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        hintField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        errorField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        hintField.font = CCTheme.font.caption
        hintField.textColor = CCTheme.color.mutedForeground
        errorField.font = CCTheme.font.caption
        errorField.textColor = CCTheme.color.destructive
    }

    /// Show (message) or clear (nil) the error line, animated: the row slides
    /// open on the settle curve while the text fades. A CCField control gets
    /// its destructive border toggled in the same beat.
    func setError(_ message: String?) {
        guard message != errorMessage else { return }
        errorMessage = message
        (control as? CCField)?.isError = message != nil

        if let message {
            errorField.stringValue = message
            // Growth lands on the house bounce — the row springs open.
            CCMotion.run(duration: 0.34, curve: CCMotion.bounce) {
                self.errorField.isHidden = false
                self.errorField.alphaValue = 1
                self.stack.layoutSubtreeIfNeeded()
            }
        } else {
            CCMotion.run(duration: 0.2, curve: CCMotion.glide, {
                self.errorField.alphaValue = 0
                self.errorField.isHidden = true
                self.stack.layoutSubtreeIfNeeded()
            }, completion: { [weak self] in
                if self?.errorMessage == nil { self?.errorField.stringValue = "" }
            })
        }
    }

    // MARK: - Harness seams

    var probeErrorField: NSTextField { errorField }
}
