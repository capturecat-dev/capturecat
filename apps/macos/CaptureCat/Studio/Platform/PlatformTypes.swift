// The studio's platform seam. Studio code names these types and calls the
// helpers in this folder; it never imports AppKit or UIKit itself. This folder
// is the only place with `#if canImport(AppKit)`.
//
// On the Mac every alias and helper resolves to exactly the AppKit call the
// code made before it existed, so Mac output is unchanged by construction
// (proven by apps/macos/scripts/render-baseline.sh). iOS output is gated
// separately (--ios-vectors, --ios-preview-parity, --ios-export-parity).

#if canImport(AppKit)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
/// Nested types are members, so studio code can't spell `PlatformFont.Weight`.
typealias PlatformFontWeight = NSFont.Weight
#else
import UIKit

typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
typealias PlatformFontWeight = UIFont.Weight
#endif
