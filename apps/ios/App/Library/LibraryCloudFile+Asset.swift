import AVFoundation
import UniformTypeIdentifiers

extension LibraryCloudFile {
    /// What the bytes are, for AVFoundation. R2 object keys carry no file
    /// extension, so without this the player knows the format only from the
    /// response's Content-Type, and a generic one ("application/octet-stream")
    /// fails with "Cannot Open". Say it up front, as the Mac's
    /// `CloudThumbnailer` does: the stored type when it names audio or video,
    /// else the type of the file name's extension.
    var avMIMEType: String? {
        let stored = contentType.lowercased()
        if stored.hasPrefix("video/") || stored.hasPrefix("audio/") { return contentType }
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    /// An asset that reads this file over HTTP with byte-range requests.
    func avAsset() -> AVURLAsset {
        guard let mime = avMIMEType else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
    }
}
