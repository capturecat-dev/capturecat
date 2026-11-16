import UIKit

/// The in-place label editor for text and callout annotations (iOS) — the
/// twin of the Mac's NSTextField editor in `PreviewInteractionView`: a
/// BACKING view carries the annotation's pill (background + accent editing
/// ring) at the exact drawn rect, and a transparent, glyph-sized field sits
/// inside it, so entering edit mode does not move the text. The compositor
/// omits the drawn label meanwhile (`PreviewStageView
/// .inlineEditingIDProvider`). The field grows symmetrically about the
/// label's centre as the user types; Return commits, Esc discards, a tap on
/// the canvas commits (the core's click-away).
@MainActor
final class EditorInlineTextEditor: NSObject, UITextFieldDelegate {
    let annotationID: UUID
    var onFinish: ((Bool) -> Void)?

    private let backing = UIView()
    private let field = UITextField()
    private let center: CGPoint
    private let pads: CGSize

    var text: String { field.text ?? "" }

    /// `frame` / `pads`: the label's drawn rect and pill padding in the host
    /// view's space; `scale`: canvas zoom × stage magnification (font and
    /// corner radius scale with it, as the drawn label does).
    init(annotation: Annotation, frame: CGRect, pads: CGSize, scale: CGFloat) {
        annotationID = annotation.id
        center = CGPoint(x: frame.midX, y: frame.midY)
        self.pads = pads
        super.init()

        let bg = annotation.backgroundColor
        let showsBG = annotation.type == .callout || annotation.showBackground
        backing.frame = frame
        backing.isUserInteractionEnabled = false
        backing.backgroundColor = showsBG
            ? UIColor(red: bg.red, green: bg.green, blue: bg.blue, alpha: bg.opacity) : .clear
        backing.layer.cornerRadius = max(0, annotation.cornerRadius) * scale
        backing.layer.cornerCurve = .continuous
        backing.layer.borderWidth = 1.5
        backing.layer.borderColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1).cgColor

        field.frame = frame.insetBy(dx: pads.width, dy: pads.height).insetBy(dx: -4, dy: -1)
        field.text = annotation.text
        field.font = FontCatalog.font(named: annotation.fontName,
                                      size: max(10, annotation.fontSize) * scale,
                                      weight: annotation.fontWeight.nsWeight)
        field.textColor = UIColor(red: annotation.color.red, green: annotation.color.green,
                                  blue: annotation.color.blue, alpha: 1)
        field.textAlignment = .center
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.accessibilityIdentifier = "studio.inlineEditor"
    }

    func install(in host: UIView) {
        host.addSubview(backing)
        host.addSubview(field)
        field.becomeFirstResponder()
        field.selectAll(nil)
    }

    func remove() {
        field.delegate = nil
        if field.isFirstResponder { field.resignFirstResponder() }
        field.removeFromSuperview()
        backing.removeFromSuperview()
    }

    /// Harness seam: type into the field as the keyboard would.
    func replaceText(_ text: String) {
        field.text = text
        textChanged()
    }

    @objc private func textChanged() {
        guard let font = field.font else { return }
        let measured = ((field.text?.isEmpty ?? true) ? " " : field.text!)
            .size(withAttributes: [.font: font])
        let w = max(16, measured.width) + 8
        let h = max(12, measured.height) + 2
        field.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        backing.frame = field.frame.insetBy(dx: 4, dy: 1).insetBy(dx: -pads.width, dy: -pads.height)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onFinish?(true)
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // Focus left (keyboard dismissed, another field): commit, like the Mac.
        onFinish?(true)
    }
}
