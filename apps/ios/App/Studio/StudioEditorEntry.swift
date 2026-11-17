import UIKit

/// The companion app's way into the studio editor. Since Phase 5 a studio
/// project is a LOCAL project kept in sync with the cloud by the Mac's own
/// engine (`StudioCloudSync` over Studio/Sync): opening clones a project this
/// device does not have, or pulls the cloud's newer revision into the one it
/// has (edits made here merge three-way); every edit autosaves here and is
/// pushed like the Mac pushes (debounced, If-Match, media uploads); offline
/// edits wait and push later. The studio needs iOS 26 (docs/ios-studio-plan.md,
/// decision 2); the companion stays iOS 18+, so every entry is
/// `#available`-gated.
///
/// Local folders: Application Support/Studio/Projects/<ID>/.
enum StudioEditorEntry {
    static var isAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    static var projectsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio/Projects", isDirectory: true)
    }

    static func directory(for projectID: String) -> URL {
        projectsRoot.appendingPathComponent(projectID.uppercased(), isDirectory: true)
    }

    // MARK: - The live environment

    /// The signed-in session's sync environment: the shared HTTP transport
    /// with this app's bearer token, against this app's API.
    @available(iOS 26, *)
    @MainActor
    static func adoptLiveEnvironment() {
        guard SessionStore.load()?.token != nil else {
            StudioCloudSync.environment = nil
            return
        }
        let base = CaptureCatAPI.baseURL
        if let current = StudioCloudSync.environment, current.apiBaseURL == base { return }
        let transport = HTTPCloudProjectTransport(baseURL: base, token: { SessionStore.load()?.token })
        StudioCloudSync.environment = StudioCloudSync.Environment(
            transport: transport, apiBaseURL: base, clientID: CloudClientIdentity.installID)
    }

    /// The app came forward: push studio projects holding edits made offline.
    @available(iOS 26, *)
    @MainActor
    static func resumePending() {
        adoptLiveEnvironment()
        guard let environment = StudioCloudSync.environment else { return }
        // Inbox takes the studio owns (5c): gone from the inbox once their
        // first push landed; otherwise their next push removes them.
        for take in TakeInbox.all() where take.openedInStudio == true {
            guard let id = UUID(uuidString: take.id) else { continue }
            let dir = directory(for: take.id)
            if CloudSyncState.load(from: dir, projectID: id, apiBaseURL: environment.apiBaseURL) != nil {
                TakeInbox.remove(take.id)
            } else {
                StudioCloudSync.session(projectID: id, directory: dir)?.onPushed = { _ in
                    TakeInbox.remove(take.id)
                    UploadCenter.shared.reload()
                }
            }
        }
        UploadCenter.shared.reload()
        StudioCloudSync.resumePending(in: projectsRoot)
    }

    // MARK: - Open a cloud project

    @available(iOS 26, *)
    @MainActor
    static func open(projectID: String, from presenter: UIViewController) {
        guard let id = UUID(uuidString: projectID) else { return }
        open(id: id, directory: directory(for: projectID), from: presenter)
    }

    @available(iOS 26, *)
    @MainActor
    private static func open(id: UUID, directory: URL, from presenter: UIViewController,
                             onPushed: ((Int) -> Void)? = nil) {
        adoptLiveEnvironment()
        // Already current here: open now, check the cloud once it's up
        // (measured: the pull-first open waited ~0.8 s on the network).
        if let local = StudioCloudSync.openCurrentLocal(
            projectID: id, directory: directory,
            listedRevision: LibraryStore.shared.project(id.uuidString)?.revision) {
            let sync = local.sync
            if let onPushed { sync.onPushed = onPushed }
            let editor = EditorViewController(folder: local.folder)
            CCAlert.topmost(from: presenter).present(editor, animated: true) {
                sync.attach(editor)
                Task { @MainActor in await sync.checkRemote() }
            }
            return
        }
        let progress = AppToaster.shared.show(title: "Preparing the editor…", symbol: "film")
        Task { @MainActor in
            do {
                adoptLiveEnvironment()
                let (folder, sync) = try await StudioCloudSync.open(projectID: id, directory: directory)
                progress?.dismiss()
                if let onPushed { sync?.onPushed = onPushed }
                let editor = EditorViewController(folder: folder)
                CCAlert.topmost(from: presenter).present(editor, animated: true) {
                    sync?.attach(editor)
                }
            } catch is CancellationError {
                progress?.dismiss()
            } catch {
                progress?.dismiss()
                AppToaster.shared.show(title: "Couldn't open the editor", message: error.localizedDescription,
                                       variant: .destructive)
            }
        }
    }

    // MARK: - Open an inbox take (5c)

    /// A capture still in the inbox (recorded or imported on this device,
    /// not uploaded yet — offline, or its upload failed) becomes a studio
    /// project: its media and a project.json (the same document its upload
    /// would publish) in a studio folder. From then the studio's sync owns
    /// it — its first push uploads it as the cloud project (the take's id),
    /// and the take leaves the inbox once that lands.
    @available(iOS 26, *)
    @MainActor
    static func open(take: PendingTake, from presenter: UIViewController) {
        switch take.state {
        case .recording:
            AppToaster.shared.show(title: "Still recording", message: "Open it once the recording has finished.")
            return
        case .uploading:
            AppToaster.shared.show(title: "Uploading…", message: "It opens from your library as soon as it's there.")
            return
        case .pending, .failed:
            break
        }
        guard let id = UUID(uuidString: take.id) else { return }
        let dir = directory(for: take.id)
        do {
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(StudioProjectFolder.documentName).path) {
                let isPhone = take.sourceKind == "device"
                let document = try ProjectDocument.make(ProjectDocument.NewProject(
                    id: take.id, name: take.name, createdAt: take.createdAt, videoFileName: take.mediaFile,
                    duration: take.duration, sourceKind: take.sourceKind,
                    isStillCapture: take.kind == .screenshot, showDeviceFrame: isPhone))
                try StudioInboxImport.makeProject(in: dir, document: document,
                                                  media: [(TakeInbox.mediaURL(of: take), take.mediaFile)])
            }
            // The studio uploads it from here on (UploadCenter leaves it be).
            TakeInbox.update(take.id) { $0.openedInStudio = true; $0.state = .pending; $0.error = nil }
            UploadCenter.shared.reload()
        } catch {
            AppToaster.shared.show(title: "Couldn't open the editor", message: error.localizedDescription,
                                   variant: .destructive)
            return
        }
        open(id: id, directory: dir, from: presenter) { _ in
            TakeInbox.remove(take.id)
            UploadCenter.shared.reload()
            NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
        }
    }
}
