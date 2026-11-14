#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The exporter's subtitle text run (VideoExporter.renderSubtitle). The Mac
/// branch is the exporter's attributed-string code, verbatim; the exporter
/// keeps the geometry and measures/draws through `PlatformText`.
enum SubtitleText {
    /// The subtitle centred in `font`: karaoke words lit up to `currentTime`
    /// (and dimmed after it) when highlighting is on, uppercased when the
    /// style says so.
    static func attributedString(
        subtitle: SubtitleSegment,
        at currentTime: TimeInterval,
        font: PlatformFont,
        settings: ProjectSettings
    ) -> NSAttributedString {
        // Uppercase style — must transform the SAME strings the preview does.
        let transform: (String) -> String = settings.subtitleUppercase ? { $0.uppercased() } : { $0 }

        #if canImport(AppKit)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textColor = NSColor(
            red: settings.subtitleColor.red,
            green: settings.subtitleColor.green,
            blue: settings.subtitleColor.blue,
            alpha: settings.subtitleColor.opacity
        )

        let attrString: NSAttributedString
        if settings.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = NSColor(
                red: settings.subtitleHighlightColor.red,
                green: settings.subtitleHighlightColor.green,
                blue: settings.subtitleHighlightColor.blue,
                alpha: settings.subtitleHighlightColor.opacity
            )
            let dimColor = NSColor(
                red: textColor.redComponent,
                green: textColor.greenComponent,
                blue: textColor.blueComponent,
                alpha: textColor.alphaComponent * 0.4
            )
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 {
                    mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs))
                }
                let isActive = currentTime >= word.startTime
                let wordAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: isActive ? highlightColor : dimColor,
                ]
                mutable.append(NSAttributedString(string: transform(word.text), attributes: wordAttrs))
            }
            attrString = mutable
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            attrString = NSAttributedString(string: transform(subtitle.text), attributes: attributes)
        }
        return attrString
        #else
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textColor = UIColor(
            red: settings.subtitleColor.red,
            green: settings.subtitleColor.green,
            blue: settings.subtitleColor.blue,
            alpha: settings.subtitleColor.opacity
        )

        let attrString: NSAttributedString
        if settings.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = UIColor(
                red: settings.subtitleHighlightColor.red,
                green: settings.subtitleHighlightColor.green,
                blue: settings.subtitleHighlightColor.blue,
                alpha: settings.subtitleHighlightColor.opacity
            )
            let dimColor = UIColor(
                red: settings.subtitleColor.red,
                green: settings.subtitleColor.green,
                blue: settings.subtitleColor.blue,
                alpha: settings.subtitleColor.opacity * 0.4
            )
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 {
                    mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs))
                }
                let isActive = currentTime >= word.startTime
                let wordAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: isActive ? highlightColor : dimColor,
                ]
                mutable.append(NSAttributedString(string: transform(word.text), attributes: wordAttrs))
            }
            attrString = mutable
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            attrString = NSAttributedString(string: transform(subtitle.text), attributes: attributes)
        }
        return attrString
        #endif
    }
}
