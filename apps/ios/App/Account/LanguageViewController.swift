import UIKit

/// The app's language (Account → Language), modelled on Strobia's picker:
/// "System" plus the twelve App Store languages, each written in its own
/// language with its name in the current one underneath ("Deutsch" /
/// "German"), so a mistaken switch is easy to undo.
///
/// Picking one sets `AppleLanguages` in the app's defaults (System clears
/// it) — the per-app language iOS also offers in Settings → CaptureCat.
/// Bundles resolve their language at launch, so the change applies the next
/// time CaptureCat opens; the page and a confirmation say so.
final class LanguageViewController: DetailPageViewController {
    struct Language: Equatable {
        /// `AppleLanguages` value; empty = follow the system.
        let code: String
        /// The language's name in that language.
        let nativeName: String
    }

    /// Catalog languages (Localization/Localizable.xcstrings), names in their own language.
    static let languages: [Language] = [
        Language(code: "", nativeName: ""),
        Language(code: "en-GB", nativeName: "English (UK)"),
        Language(code: "en-US", nativeName: "English (US)"),
        Language(code: "de", nativeName: "Deutsch"),
        Language(code: "es", nativeName: "Español (España)"),
        Language(code: "es-MX", nativeName: "Español (México)"),
        Language(code: "fr", nativeName: "Français"),
        Language(code: "it", nativeName: "Italiano"),
        Language(code: "nl", nativeName: "Nederlands"),
        Language(code: "pt-BR", nativeName: "Português (Brasil)"),
        Language(code: "ja", nativeName: "日本語"),
        Language(code: "ko", nativeName: "한국어"),
        Language(code: "zh-Hans", nativeName: "简体中文"),
    ]

    static let defaultsKey = "AppleLanguages"

    /// The override in effect for the next launch ("" = System).
    static var selectedCode: String {
        // Only the app's own domain: `UserDefaults.standard.array` would also
        // return the system-wide list when there is no override.
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[defaultsKey] as? [String],
              let first = list.first else { return "" }
        return languages.contains(where: { $0.code == first }) ? first : ""
    }

    /// What the Account row shows: "System" or the chosen language's own name.
    static var selectedDisplayName: String {
        let code = selectedCode
        return code.isEmpty ? String(localized: "System", comment: "Language setting: follow the device language")
            : (languages.first { $0.code == code }?.nativeName ?? code)
    }

    static func apply(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }

    private var rows: [LanguageRow] = []
    /// The code the app is running in now (resolved at launch).
    private let launchCode = LanguageViewController.selectedCode
    private let note = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)

    init() {
        super.init(title: String(localized: "Language", comment: "Account: the app language page title"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let intro = ccLabel(String(localized: "Choose the language CaptureCat uses. System follows your \(ThisDevice.noun)’s language.",
                                   comment: "Language page intro; the argument is iPhone or iPad"),
                            font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
        column.addArrangedSubview(intro)

        let card = CCCard()
        let list = UIStackView()
        list.axis = .vertical
        list.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xs),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xs),
            list.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.xs),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.xs),
        ])
        let selected = Self.selectedCode
        for (index, language) in Self.languages.enumerated() {
            if index > 0 { list.addArrangedSubview(CCDivider()) }
            let title = language.code.isEmpty ? String(localized: "System", comment: "Language setting: follow the device language") : language.nativeName
            let row = LanguageRow(title: title, subtitle: Self.subtitle(for: language), selected: language.code == selected)
            row.onTap = { [weak self] in self?.pick(language) }
            row.accessibilityIdentifier = "language.\(language.code.isEmpty ? "system" : language.code)"
            rows.append(row)
            list.addArrangedSubview(row)
        }
        column.addArrangedSubview(card)
        column.addArrangedSubview(note)
        renderNote()
    }

    /// The language's name in the current app language, or for System the
    /// device's own language; nil when it would repeat the title.
    private static func subtitle(for language: Language) -> String? {
        if language.code.isEmpty {
            guard let device = Locale.preferredLanguages.first.flatMap({ Locale.current.localizedString(forIdentifier: $0) }) else { return nil }
            return device.prefix(1).uppercased() + device.dropFirst()
        }
        guard let name = Locale.current.localizedString(forIdentifier: language.code),
              name.compare(language.nativeName, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func renderNote() {
        let pending = Self.selectedCode != launchCode
        note.text = pending
            ? String(localized: "CaptureCat switches language the next time it opens. Close it from the App Switcher, then open it again.",
                     comment: "Language page footnote after a new language was picked")
            : String(localized: "A new language applies the next time CaptureCat opens.",
                     comment: "Language page footnote")
    }

    private func pick(_ language: Language) {
        guard language.code != Self.selectedCode else { return }
        Self.apply(language.code)
        for (row, candidate) in zip(rows, Self.languages) { row.setSelected(candidate.code == language.code) }
        renderNote()
        CCAccessibility.announce(language.code.isEmpty
            ? String(localized: "System", comment: "Language setting: follow the device language")
            : language.nativeName)
        guard language.code != launchCode else { return }
        let alert = CCAlert(title: String(localized: "Reopen CaptureCat", comment: "Alert title after changing the app language"),
                            message: String(localized: "The new language appears the next time CaptureCat opens. Close it from the App Switcher, then open it again.",
                                            comment: "Alert message after changing the app language"))
        alert.symbol = "globe"
        alert.addButton(String(localized: "OK", comment: "Default alert button"), role: .primary)
        alert.present(from: self)
    }
}

/// One language: its own name, the translated name under it, a check at the
/// far right when chosen. Press washes it in place.
final class LanguageRow: UIControl {
    var onTap: (() -> Void)?
    private let wash = UIView()
    private let titleLabel: UILabel
    private let subtitleLabel: UILabel?
    private let check = CCIconView("check", pointSize: 15, weight: .semibold, tint: CCTheme.color.foreground)
    private let valueLabel = ccLabel("", font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 1, alignment: .natural)
    private let chevron = CCIconView("chevron-right", pointSize: 13, weight: .semibold, tint: CCTheme.color.faintForeground)
    private let title: String

    /// Navigation-row mode (Account → Language): the current value and a
    /// chevron instead of the check.
    var accessoryText: String? {
        didSet {
            valueLabel.text = accessoryText
            let isNav = accessoryText != nil
            valueLabel.isHidden = !isNav
            chevron.isHidden = !isNav
            check.isHidden = isNav
            accessibilityLabel = title
            accessibilityValue = accessoryText
        }
    }

    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    init(title: String, subtitle: String?, selected: Bool) {
        self.title = title
        titleLabel = ccLabel(title, font: CCFont.bodyMedium, color: CCTheme.color.foreground, lines: 0)
        subtitleLabel = subtitle.map { ccLabel($0, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wash.isUserInteractionEnabled = false
        wash.alpha = 0
        wash.layer.cornerCurve = .continuous
        wash.layer.cornerRadius = CCRadius.lg.concentric(inset: CCSpace.xs)
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel].compactMap { $0 })
        text.axis = .vertical
        text.spacing = 1
        valueLabel.isHidden = true
        chevron.isHidden = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [text, valueLabel, chevron, check])
        stack.spacing = CCSpace.md
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor), wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor), wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md + 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.md - 2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        isAccessibilityElement = true
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        setSelected(selected, animated: false)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool, animated: Bool = true) {
        accessibilityTraits = selected ? [.button, .selected] : .button
        titleLabel.font = selected ? CCFont.header : CCFont.bodyMedium
        guard animated else { check.alpha = selected ? 1 : 0; return }
        CCMotion.fadeAlpha(check, to: selected ? 1 : 0, duration: selected ? 0.18 : 0.12)
    }

    private func applyTheme() {
        wash.backgroundColor = CCTheme.color.active
        titleLabel.textColor = CCTheme.color.foreground
        subtitleLabel?.textColor = CCTheme.color.mutedForeground
        valueLabel.textColor = CCTheme.color.mutedForeground
        chevron.tintColor = CCTheme.color.faintForeground
        check.tintColor = CCTheme.color.primary
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.06 : 0.22)
        }
    }
}
