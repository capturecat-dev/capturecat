import AppKit

/// The house "preview well" — the recessed .lg surface behind every mini
/// demo canvas (placement pad, shadow preview, effect pads). Subclass it (or
/// use it bare as a container) and draw demo content inside `contentRect`;
/// the chrome, optional 3×3 dot grid and radius come from the kit so all
/// pads read as one component.
@MainActor
open class CCPreviewPad: NSView {
    /// Inset from the well edge to the drawable demo area.
    public var contentInset: CGFloat = 6

    private var gridDots: [CALayer] = []
    private var themeObservation: CCThemeObservation?

    public var contentRect: CGRect {
        bounds.insetBy(dx: contentInset, dy: contentInset)
    }

    public init(showsGridDots: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        if showsGridDots {
            for _ in 0..<9 {
                let dot = CALayer()
                dot.cornerRadius = 1.5
                layer?.addSublayer(dot)
                gridDots.append(dot)
            }
        }
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            let ink: NSColor = CCTheme.isDark ? .white : .black
            self.layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
            self.layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
            // Skeuo: the demo well is genuinely recessed.
            if let layer = self.layer {
                CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated),
                                 radius: CCTheme.radius(.lg))
            }
            for dot in self.gridDots {
                dot.backgroundColor = ink.withAlphaComponent(0.18).cgColor
            }
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    open override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
        guard !gridDots.isEmpty else { return }
        let rect = bounds.insetBy(dx: 12, dy: 12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in gridDots.enumerated() {
            let fx = CGFloat(index % 3) / 2
            let fy = CGFloat(index / 3) / 2
            dot.frame = CGRect(
                x: rect.minX + fx * rect.width - 1.5,
                y: rect.minY + fy * rect.height - 1.5,
                width: 3, height: 3
            )
        }
        CATransaction.commit()
    }
}
