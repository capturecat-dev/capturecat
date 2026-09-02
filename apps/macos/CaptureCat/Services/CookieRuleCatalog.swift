import Foundation

/// EasyList Cookie List rules, converted to plain CSS selectors by
/// `apps/api/scripts/update-cookie-rules.mjs` and bundled as
/// `Resources/cookie-rules.generated.json` — byte-identical to the API
/// worker's copy, so app and worker captures hide the same elements.
/// (Source URL, fetch date and licence live in the JSON's `meta`; attribution
/// in `Resources/COOKIE-RULES-ATTRIBUTION.txt`.)
///
/// The hand-curated `WebHideRules` lists remain a verified overrides layer
/// applied on top — they cover interstitials (Google, Stripe) proven by hand.
enum CookieRuleCatalog {
    private struct RuleFile: Decodable {
        var generic: [String]
        var domains: [String: [String]]
    }

    /// Loaded once; nil only if the bundle resource is missing (the curated
    /// layer still applies, so hiding degrades rather than breaks).
    private static let rules: RuleFile? = {
        guard let url = Bundle.main.url(forResource: "cookie-rules.generated", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RuleFile.self, from: data) else { return nil }
        return decoded
    }()

    /// The generic list is ~15k selectors; the CSS block is pre-joined once at
    /// first use so per-capture cost is a string append, not a 15k-element join.
    static let genericCSS: String? = {
        guard let generic = rules?.generic, !generic.isEmpty else { return nil }
        return "\(generic.joined(separator: ",\n")) { display: none !important; }"
    }()

    /// Domain-scoped selectors with AdBlock subdomain semantics: a rule for
    /// `example.com` applies to `www.example.com` but never `notexample.com`.
    static func domainSelectors(forHost host: String?) -> [String] {
        guard let host, let domains = rules?.domains else { return [] }
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return [] }
        var out: [String] = []
        for i in 0..<(labels.count - 1) {
            let suffix = labels[i...].joined(separator: ".")
            if let sels = domains[suffix] { out += sels }
        }
        return out
    }

    /// True when the bundled rule file loaded (asserted by --web-device-test).
    static var isLoaded: Bool { rules != nil }
    static var genericCount: Int { rules?.generic.count ?? 0 }
    static var domainCount: Int { rules?.domains.count ?? 0 }
}
