import Photos
import UIKit
import UniformTypeIdentifiers

/// Where a finished export goes on iOS (Studio 3d): the photo library, the
/// Files app, or the system share sheet — all system UI, nothing custom to
/// dress. Shared by the app and StudioLab (`--ios-delivery-test` saves real
/// assets into the Simulator's library and presents both controllers in a real
/// window).
///
/// Photos uses ADD-ONLY access (`NSPhotoLibraryAddUsageDescription`): saving an
/// export never asks to read the library. Movies are added as video resources;
/// PNG stills and animated GIFs as photo resources (Photos keeps a GIF's
/// animation when the original file is the photo resource).
@MainActor
enum ExportDelivery {
    enum Kind: Equatable {
        case movie, gif, png
    }

    enum DeliveryError: LocalizedError {
        case photosAccessDenied
        case photosSaveFailed(String)

        var errorDescription: String? {
            switch self {
            case .photosAccessDenied:
                return "CaptureCat can't save to Photos. Allow adding photos in Settings › Privacy & Security › Photos."
            case .photosSaveFailed(let reason):
                return "Couldn't save to Photos: \(reason)"
            }
        }
    }

    static func kind(for url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "gif": return .gif
        case "png": return .png
        default: return .movie
        }
    }

    /// Saves `url` to the photo library; returns the new asset's local
    /// identifier.
    static func saveToPhotos(_ url: URL) async throws -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw DeliveryError.photosAccessDenied }
        let kind = kind(for: url)
        return try await withCheckedThrowingContinuation { continuation in
            let created = IdentifierBox()
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: kind == .movie ? .video : .photo, fileURL: url, options: options)
                created.value = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success, let id = created.value {
                    continuation.resume(returning: id)
                } else {
                    continuation.resume(throwing: DeliveryError.photosSaveFailed(error?.localizedDescription ?? "unknown error"))
                }
            })
        }
    }

    /// The Files app: a picker that exports (copies) the file to a location
    /// the user chooses.
    static func filesPicker(for url: URL) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }

    /// The system share sheet (AirDrop, Messages, Mail, Save to Files, …).
    static func shareSheet(for url: URL, from source: UIView) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = source
        controller.popoverPresentationController?.sourceRect = source.bounds
        return controller
    }

    /// `performChanges` runs its block on a private queue; the placeholder's
    /// identifier comes back through this box.
    private final class IdentifierBox: @unchecked Sendable {
        var value: String?
    }
}
