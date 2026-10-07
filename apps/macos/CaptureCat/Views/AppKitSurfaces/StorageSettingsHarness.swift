import AppKit

/// Canned StorageBucketClient for `--settings-shot`: the gate renders every
/// Storage screen without touching the network or the Keychain.
nonisolated final class FakeStorageBucketClient: StorageBucketClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _hasSession = true
    private var _status = FakeStorageBucketClient.disconnected()
    private var _saveResult: Result<StorageBucketStatus, StorageBucketAPIError> = .success(FakeStorageBucketClient.connected())
    private var _saveDelay: TimeInterval = 0
    private var _disconnectResult: Result<StorageDisconnectResult, StorageBucketAPIError> =
        .success(StorageDisconnectResult(disconnected: true, retained: true, videoCount: 3))
    private var _drafts: [StorageBucketDraft] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var hasSession: Bool {
        get { locked { _hasSession } }
        set { locked { _hasSession = newValue } }
    }
    var status: StorageBucketStatus {
        get { locked { _status } }
        set { locked { _status = newValue } }
    }
    var saveResult: Result<StorageBucketStatus, StorageBucketAPIError> {
        get { locked { _saveResult } }
        set { locked { _saveResult = newValue } }
    }
    var saveDelay: TimeInterval {
        get { locked { _saveDelay } }
        set { locked { _saveDelay = newValue } }
    }
    var disconnectResult: Result<StorageDisconnectResult, StorageBucketAPIError> {
        get { locked { _disconnectResult } }
        set { locked { _disconnectResult = newValue } }
    }
    var drafts: [StorageBucketDraft] { locked { _drafts } }

    func fetchStatus() async throws -> StorageBucketStatus { status }

    func save(_ draft: StorageBucketDraft) async throws -> StorageBucketStatus {
        locked { _drafts.append(draft) }
        let delay = saveDelay
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return try saveResult.get()
    }

    func disconnect() async throws -> StorageDisconnectResult {
        try disconnectResult.get()
    }

    static func disconnected(enabled: Bool = true, available: Bool = true, retained: Int = 0) -> StorageBucketStatus {
        StorageBucketStatus(enabled: enabled, available: available, bucket: nil, retainedCount: retained)
    }

    static func connected(enabled: Bool = true) -> StorageBucketStatus {
        StorageBucketStatus(
            enabled: enabled,
            available: true,
            bucket: ConnectedStorageBucket(
                id: "bkt_fixture",
                provider: .r2,
                endpoint: "https://0123456789abcdef.r2.cloudflarestorage.com",
                region: "auto",
                bucket: "my-videos",
                pathPrefix: "capturecat/",
                forcePathStyle: false,
                publicBaseUrl: nil,
                accessKeyIdHint: "AKIA…WXYZ",
                verifiedAt: StorageBucketAPI.parseDate("2026-10-07T09:30:00.000Z"),
                videoCount: 3
            ),
            retainedCount: 0
        )
    }
}

/// The Storage half of `--settings-shot`. Runs inside the SAME
/// SettingsViewController + NSWindow chain as the rest of the gate (and the
/// app). Motion is sampled before each state's capture (CARenderer captures
/// can orphan live presentation layers).
@MainActor
enum StorageSettingsStage {
    private static var failures: [String] = []

    private static func expect(_ ok: Bool, _ label: String) {
        print("STORAGE \(ok ? "ok  " : "FAIL") \(label)")
        if !ok { failures.append(label) }
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func run(
        controller: SettingsViewController,
        window: NSWindow,
        client: FakeStorageBucketClient
    ) async -> Bool {
        CCTheme.setMode(.dark, persist: false)
        await wait(0.2)

        decodingChecks()

        func show() async -> StorageSettingsPane? {
            controller.select(section: .storage, animated: false)
            controller.view.layoutSubtreeIfNeeded()
            await wait(0.35)
            controller.view.layoutSubtreeIfNeeded()
            return controller.probeCurrentPane as? StorageSettingsPane
        }

        func snapshot(_ suffix: String) {
            // Upright 2x capture (see CCKitExtrasHarness): CARenderer reads
            // back Y-mirrored at 1x, so pre-scale and flip for the render.
            guard let layer = controller.view.layer else { return }
            let size = controller.view.bounds.size
            let prior = layer.transform
            layer.transform = CATransform3DConcat(CATransform3DMakeScale(2, -2, 1),
                                                  CATransform3DMakeTranslation(0, size.height * 2, 0))
            let rendered = CARendererSnapshot.render(layer: layer, size: size, scale: 2)
            layer.transform = prior
            guard let img = rendered else {
                expect(false, "capture \(suffix)")
                return
            }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-settings-storage-\(suffix).png")
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out)
            print("SETTINGS capture \(out.path)")
        }

        /// Frame in the controller's root space; must sit inside the content
        /// column (right of the sidebar) with a real size.
        func framed(_ view: NSView?, minWidth: CGFloat = 40, minHeight: CGFloat = 16) -> Bool {
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
            let frame = view.convert(view.bounds, to: controller.view)
            return frame.width >= minWidth && frame.height >= minHeight
                && frame.minX >= 200 && frame.maxX <= controller.view.bounds.width + 0.5
        }

        // A. Disconnected → connect form, AWS preset.
        client.hasSession = true
        client.status = FakeStorageBucketClient.disconnected(retained: 2)
        guard let pane = await show() else {
            expect(false, "storage pane mounted")
            return false
        }
        let paneFrame = pane.convert(pane.bounds, to: controller.view)
        expect(paneFrame.height > 360, "pane fills the column height (\(Int(paneFrame.height))pt)")
        expect(framed(pane.probeScroll, minWidth: 300, minHeight: 250), "scroll view framed")
        guard case .form(_, nil, false) = pane.probeScreen, let form = pane.probeForm else {
            expect(false, "disconnected → connect form (got \(String(describing: pane.probeScreen)))")
            return false
        }
        let fields = form.probeFields
        expect(form.probeProvider == .aws, "default provider is AWS")
        expect(fields.region.stringValue == "us-east-1", "AWS prefills us-east-1")
        expect(form.probeEndpointReveal.probeHeightConstraint.constant < 0.5, "endpoint folded for AWS")
        for (name, field) in [("region", fields.region), ("bucket", fields.bucket), ("prefix", fields.prefix),
                              ("accessKey", fields.accessKey), ("secret", fields.secret),
                              ("publicURL", fields.publicURL)] {
            expect(framed(field, minWidth: 220, minHeight: 26), "field \(name) framed in window")
        }
        let documentHeight = pane.probeScroll.documentView?.frame.height ?? 0
        let visibleHeight = pane.probeScroll.contentView.bounds.height
        expect(documentHeight > visibleHeight, "form taller than the window scrolls (\(Int(documentHeight)) > \(Int(visibleHeight)))")
        // Scroll to the bottom: footer must resolve in the same chain.
        if let document = pane.probeScroll.documentView {
            document.scroll(NSPoint(x: 0, y: document.frame.height))
            controller.view.layoutSubtreeIfNeeded()
        }
        expect(framed(form.probeSaveButton, minWidth: 60, minHeight: 20), "Save button framed after scroll")
        expect(pane.probeContentViews.contains { ($0 as? NSTextField)?.stringValue.contains("2 videos still play") == true },
               "retained-count note shown")
        pane.probeScroll.documentView?.scroll(.zero)
        await wait(0.1)
        snapshot("form-aws")

        // B. R2 preset: endpoint row reveals (bottom edge, bounce) + region "auto".
        form.pickProvider(.r2)
        await wait(0.08)
        let reveal = form.probeEndpointReveal
        let midHeight = reveal.probeHeightConstraint.constant
        expect(reveal.probeIsAnimating && midHeight > 0.5 && midHeight < reveal.probeTargetHeight,
               "endpoint reveal mid-flight (\(String(format: "%.1f", midHeight)) of \(Int(reveal.probeTargetHeight)))")
        await wait(0.6)
        expect(abs(reveal.probeHeightConstraint.constant - reveal.probeTargetHeight) < 0.5
               && reveal.probeTargetHeight > 30, "endpoint revealed (\(Int(reveal.probeTargetHeight))pt)")
        expect(fields.region.stringValue == "auto", "R2 prefills region auto")
        expect(fields.endpoint.placeholderString?.contains("r2.cloudflarestorage.com") == true, "R2 endpoint placeholder")
        expect(framed(fields.endpoint, minWidth: 220, minHeight: 26), "endpoint field framed")
        form.pickProvider(.b2)
        expect(fields.region.stringValue == StorageProvider.b2.defaultRegion
               && fields.endpoint.placeholderString == "https://s3.us-west-004.backblazeb2.com",
               "B2 placeholder follows region")
        form.pickProvider(.minio)
        await wait(0.5)
        form.pickProvider(.r2)
        await wait(0.5)
        snapshot("form-r2")

        // C. Client-side validation → inline error, no request. (Endpoint
        // filled first: it is checked before the bucket.)
        fields.endpoint.stringValue = "https://0123456789abcdef.r2.cloudflarestorage.com"
        fields.bucket.stringValue = ""
        form.probeSubmit()
        await wait(0.5)
        expect(form.errorMessage == "Enter the bucket name." && fields.bucket.isError,
               "validation flags the missing bucket")
        expect(client.drafts.isEmpty, "invalid form sends nothing")

        // D. Busy → server error, verbatim.
        fields.endpoint.stringValue = "https://0123456789abcdef.r2.cloudflarestorage.com"
        fields.bucket.stringValue = "my-videos"
        fields.prefix.stringValue = "capturecat/"
        fields.accessKey.stringValue = "AKIAFIXTUREWXYZ"
        fields.secret.stringValue = "fixture-secret"
        // Clear the validation error first so the server error GROWS in.
        pane.model.clearSaveError()
        await wait(0.4)
        let serverMessage = "We wrote a test file to my-videos but couldn't read it back (403 Access Denied). Check the key's read permission."
        client.saveResult = .failure(.server(status: 422, message: serverMessage, code: "verify_failed", step: "read"))
        client.saveDelay = 0.8
        form.probeSubmit()
        await wait(0.15)
        expect(form.isBusy && form.probeSaveButton.title == "Testing bucket…" && !form.probeSaveButton.isEnabled,
               "busy: Save reads \"Testing bucket…\" and disables")
        expect(!form.probeSpinner.isHidden, "busy: spinner visible")
        snapshot("busy")
        var waited = 0.0
        while form.errorMessage == nil, waited < 2 {
            await wait(0.012)
            waited += 0.012
        }
        let errorReveal = form.probeErrorReveal
        expect(errorReveal.probeIsAnimating && errorReveal.probeHeightConstraint.constant < errorReveal.probeTargetHeight,
               "error grows open mid-flight")
        await wait(0.6)
        expect(form.errorMessage == serverMessage, "server error shown verbatim")
        expect(errorReveal.probeTargetHeight > 40
               && abs(errorReveal.probeHeightConstraint.constant - errorReveal.probeTargetHeight) < 0.5,
               "error callout open (\(Int(errorReveal.probeTargetHeight))pt)")
        expect(form.probeErrorCallout.probeMessageFits, "error text fits (no clipping)")
        expect(!form.isBusy && form.probeSaveButton.title == "Test & Save" && form.probeSaveButton.isEnabled,
               "busy cleared after failure")
        expect(fields.bucket.stringValue == "my-videos" && fields.secret.stringValue == "fixture-secret",
               "typed values survive a failed save")
        if let draft = client.drafts.last {
            expect(draft.provider == .r2 && draft.region == "auto" && draft.bucket == "my-videos"
                   && draft.endpoint == "https://0123456789abcdef.r2.cloudflarestorage.com"
                   && draft.accessKeyId == "AKIAFIXTUREWXYZ" && draft.secretAccessKey == "fixture-secret"
                   && draft.publicBaseUrl == nil && draft.pathPrefix == "capturecat/",
                   "draft wire values")
        } else {
            expect(false, "draft sent")
        }
        // Scroll so the error + footer are in view for the capture.
        if let document = pane.probeScroll.documentView {
            document.scroll(NSPoint(x: 0, y: document.frame.height))
        }
        await wait(0.15)
        snapshot("error")

        // E. Secure well: the secret field uses the secure cell + editor.
        expect(form.probeSecretField.cell is NSSecureTextFieldCell, "secret field has a secure cell")
        // Focus it for real: a secure CELL in a plain NSTextField throws an
        // assertion here (the editor's delegate must be NSSecureTextField).
        window.makeFirstResponder(form.probeSecretField)
        let editorClass = form.probeSecretField.currentEditor().map { String(describing: type(of: $0)) } ?? "none"
        expect(editorClass.contains("Secure"), "secret field edits through the secure editor (\(editorClass))")
        window.makeFirstResponder(nil)
        expect(form.probeSecretField.stringValue == "fixture-secret", "secret value intact after focus")

        // F. Successful save → summary.
        client.saveDelay = 0
        client.saveResult = .success(FakeStorageBucketClient.connected())
        form.probeSubmit()
        await wait(0.5)
        expect({ if case .summary(_, true) = pane.probeScreen { return true }; return false }(),
               "successful save → connected summary")

        // G. Connected summary from a fresh load.
        client.status = FakeStorageBucketClient.connected()
        guard let connectedPane = await show() else { return false }
        expect({ if case .summary(_, true) = connectedPane.probeScreen { return true }; return false }(),
               "connected status → summary")
        expect(framed(connectedPane.probeDisconnectButton, minWidth: 60, minHeight: 20), "Disconnect button framed")
        let summaryText = allText(in: connectedPane)
        for needle in ["R2 · my-videos", "AKIA…WXYZ", "3 share videos", "Verified", "Short-lived signed links"] {
            expect(summaryText.contains(needle), "summary shows \"\(needle)\"")
        }
        snapshot("connected")

        // H. Edit → prefilled form (keys blank), Cancel → summary.
        connectedPane.model.isEditing = true
        await wait(0.4)
        if case .form(_, let editing?, false) = connectedPane.probeScreen, let editForm = connectedPane.probeForm {
            let f = editForm.probeFields
            expect(editing.bucket == "my-videos" && f.bucket.stringValue == "my-videos"
                   && f.endpoint.stringValue.contains("r2.cloudflarestorage.com")
                   && f.region.stringValue == "auto" && f.prefix.stringValue == "capturecat/",
                   "edit form prefilled from the bucket")
            expect(f.accessKey.stringValue.isEmpty && f.secret.stringValue.isEmpty, "edit form keys blank")
            expect(editForm.probeProvider == .r2 && editForm.probeEndpointReveal.probeTargetHeight > 30,
                   "edit form keeps the R2 endpoint row")
            snapshot("edit")
            editForm.probeCancel()
            await wait(0.4)
            expect({ if case .summary = connectedPane.probeScreen { return true }; return false }(),
                   "Cancel returns to the summary")
        } else {
            expect(false, "Edit opens the prefilled form")
        }

        // I. Disconnect: failure shows inline, success reloads to the form.
        client.disconnectResult = .failure(.server(status: 503, message: "Custom storage isn't available right now.",
                                                   code: "storage_unavailable", step: nil))
        connectedPane.model.disconnect()
        await wait(0.5)
        expect(connectedPane.probeSummaryCallout != nil
               && allText(in: connectedPane).contains("Custom storage isn't available right now."),
               "disconnect failure shown inline")
        client.disconnectResult = .success(StorageDisconnectResult(disconnected: true, retained: true, videoCount: 3))
        client.status = FakeStorageBucketClient.disconnected(retained: 3)
        connectedPane.model.disconnect()
        await wait(0.6)
        expect({ if case .form(_, nil, false) = connectedPane.probeScreen { return true }; return false }(),
               "disconnect → connect form")
        expect(allText(in: connectedPane).contains("3 videos still play"), "retained videos noted after disconnect")

        // J. Signed out.
        client.hasSession = false
        if let signedOut = await show() {
            expect(signedOut.probeScreen == .signedOut, "no session → sign-in prompt")
            snapshot("signed-out")
        }
        client.hasSession = true

        // K. Plan without custom storage → locked form + upgrade note.
        client.status = FakeStorageBucketClient.disconnected(enabled: false)
        if let lockedPane = await show() {
            let isLocked: Bool = { if case .form(_, nil, true) = lockedPane.probeScreen { return true }; return false }()
            expect(isLocked, "plan without storage → locked form")
            expect(lockedPane.probeForm?.probeSaveButton.isEnabled == false, "locked: Save disabled")
            expect(allText(in: lockedPane).contains("Storing videos in your own bucket is part of CaptureCat Pro."),
                   "upgrade note shown (Pro copy)")
            snapshot("upgrade")
        }

        // L. Server not configured.
        client.status = FakeStorageBucketClient.disconnected(available: false)
        if let unavailable = await show() {
            expect(unavailable.probeScreen == .unavailable
                   && allText(in: unavailable).contains("Custom storage isn't available right now"),
                   "unavailable → notice")
        }

        // M. Light theme, connected.
        CCTheme.setMode(.light, persist: false)
        client.status = FakeStorageBucketClient.connected()
        if await show() != nil {
            await wait(0.2)
            snapshot("connected-light")
        }

        print(failures.isEmpty ? "STORAGE PASS" : "STORAGE FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    /// Every label's text under `view` (summary/callout assertions).
    private static func allText(in view: NSView) -> String {
        var parts: [String] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, !field.isHiddenOrHasHiddenAncestor { parts.append(field.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return parts.joined(separator: "\n")
    }

    /// Wire decoding against the documented contract.
    private static func decodingChecks() {
        let json = """
        {"enabled":true,"available":true,"retainedCount":1,"bucket":{"id":"b1","provider":"wasabi",
        "endpoint":"https://s3.eu-central-1.wasabisys.com","region":"eu-central-1","bucket":"clips",
        "pathPrefix":"","forcePathStyle":true,"publicBaseUrl":"https://cdn.example.com",
        "accessKeyIdHint":"AKIA…WXYZ","verifiedAt":"2026-10-07T09:30:00.000Z","videoCount":3}}
        """
        if let status = try? StorageBucketAPI.decodeStatus(Data(json.utf8)), let bucket = status.bucket {
            expect(status.enabled && status.available && status.retainedCount == 1
                   && bucket.provider == .wasabi && bucket.bucket == "clips" && bucket.forcePathStyle
                   && bucket.publicBaseUrl == "https://cdn.example.com" && bucket.videoCount == 3
                   && bucket.verifiedAt != nil && bucket.pathPrefix.isEmpty,
                   "decode GET status")
        } else {
            expect(false, "decode GET status")
        }
        let empty = try? StorageBucketAPI.decodeStatus(Data(#"{"enabled":false,"available":true,"bucket":null,"retainedCount":0}"#.utf8))
        expect(empty == StorageBucketStatus(enabled: false, available: true, bucket: nil, retainedCount: 0),
               "decode null bucket")
        let error = StorageBucketAPI.serverError(
            status: 422,
            data: Data(#"{"error":"Couldn't delete the test object.","code":"verify_failed","step":"delete"}"#.utf8)
        )
        expect(error == .server(status: 422, message: "Couldn't delete the test object.", code: "verify_failed", step: "delete")
               && error.errorDescription == "Couldn't delete the test object.",
               "decode verify_failed error verbatim")
        let draft = StorageBucketDraft(provider: .aws, endpoint: nil, region: "us-east-1", bucket: "b",
                                       pathPrefix: "", forcePathStyle: false, publicBaseUrl: nil,
                                       accessKeyId: "k", secretAccessKey: "s")
        let body = (try? JSONSerialization.data(withJSONObject: draft.jsonObject))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(body?["endpoint"] is NSNull && body?["publicBaseUrl"] is NSNull
               && body?["provider"] as? String == "aws" && body?["forcePathStyle"] as? Bool == false
               && body?.count == 9,
               "PUT body shape (explicit nulls, 9 keys)")
    }
}
