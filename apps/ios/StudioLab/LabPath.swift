import Foundation

/// Paths given to StudioLab on its command line. In the Simulator they are
/// host paths; on a device the host can't name the app's container, so a
/// path written `@home/<rest>` resolves inside it (`NSHomeDirectory()`) —
/// copy inputs there with `xcrun devicectl device copy to --domain-type
/// appDataContainer` (apps/ios/scripts/ios-device-features.sh).
enum LabPath {
    static func url(_ argument: String, isDirectory: Bool = true) -> URL {
        let prefix = "@home/"
        if argument.hasPrefix(prefix) {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(String(argument.dropFirst(prefix.count)), isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: argument, isDirectory: isDirectory)
    }
}
