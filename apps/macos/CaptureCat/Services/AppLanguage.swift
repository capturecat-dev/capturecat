import AppKit

/// The app's language (Settings ▸ General ▸ Language), the same list and
/// behaviour as the iPhone app's picker: "System" plus the twelve languages
/// the String Catalog carries, each written in its own language.
///
/// Picking one sets `AppleLanguages` in the app's own defaults domain (System
/// removes it) — exactly what macOS writes for System Settings ▸ General ▸
/// Language & Region ▸ Applications, so the two never disagree. A bundle
/// resolves its language at launch, so the change applies after a relaunch.
enum AppLanguage {
    struct Language: Equatable {
        /// `AppleLanguages` value; empty = follow the system.
        let code: String
        /// The language's name in that language.
        let nativeName: String
    }

    /// Catalog languages (Resources/Localizable.xcstrings), in the iPhone
    /// app's order.
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

    /// The language this launch resolved to ("" = no override was set).
    static let launchCode = selectedCode

    /// The override in effect for the next launch ("" = System). Only the
    /// app's own domain: `UserDefaults.standard.array` also returns the
    /// system-wide list when there is no override.
    static var selectedCode: String {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[defaultsKey] as? [String],
              let first = list.first else { return "" }
        return languages.contains(where: { $0.code == first }) ? first : ""
    }

    /// The menu title: "System" or the language's own name, with its name in
    /// the current language after it when that differs ("Deutsch — German").
    static func title(for language: Language) -> String {
        if language.code.isEmpty {
            return String(localized: "System", comment: "Settings ▸ General ▸ Language: follow the Mac's language")
        }
        guard let name = Locale.current.localizedString(forIdentifier: language.code),
              name.compare(language.nativeName, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else { return language.nativeName }
        return "\(language.nativeName) — \(name.prefix(1).uppercased() + name.dropFirst())"
    }

    static func apply(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }

    /// System Settings ▸ General ▸ Language & Region, where macOS lists
    /// CaptureCat under Applications with the same choice.
    static func openSystemLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a fresh copy of the app and quits this one, so the new language
    /// takes effect. Only ever on the person's explicit "Relaunch".
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
