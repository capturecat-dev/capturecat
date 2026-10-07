import AppKit
import Observation

// Settings › Storage — connect your own S3-compatible bucket for share-link
// videos. The server verifies (write/read/delete) and stores the bucket; new
// uploads then presign into it with no client change. This pane only shows
// the state and edits the record (StorageBucketAPI).
//
// State flows in through StorageSettingsModel (@Observable) and two
// SurfaceObservation loops: one re-renders the pane when the SCREEN changes
// (signed out / loading / summary / form …), the other pushes busy + error
// into the mounted form without rebuilding it, so typed values survive a
// failed save. Everything is CCKit (CLAUDE.md §1).

// MARK: - Model

@MainActor
@Observable
final class StorageSettingsModel {
    enum Load: Equatable {
        case signedOut
        case loading
        case loaded(StorageBucketStatus)
        case failed(String)
    }

    private(set) var load: Load = .loading
    /// True while the connected bucket is being edited (form instead of summary).
    var isEditing = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    /// Bumped per failure so the same message twice re-announces.
    private(set) var saveErrorRevision = 0
    private(set) var isDisconnecting = false
    private(set) var disconnectError: String?

    let client: StorageBucketClient

    init(client: StorageBucketClient) {
        self.client = client
    }

    func refresh() {
        guard client.hasSession else {
            load = .signedOut
            return
        }
        if case .loaded = load {} else { load = .loading }
        Task { [weak self, client] in
            do {
                let status = try await client.fetchStatus()
                self?.load = .loaded(status)
            } catch {
                guard let self else { return }
                if (error as? StorageBucketAPIError) == .notSignedIn {
                    self.load = .signedOut
                } else {
                    self.load = .failed(error.localizedDescription)
                }
            }
        }
    }

    func save(_ draft: StorageBucketDraft) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task { [weak self, client] in
            do {
                let status = try await client.save(draft)
                guard let self else { return }
                self.isSaving = false
                self.isEditing = false
                self.load = .loaded(status)
            } catch {
                guard let self else { return }
                self.isSaving = false
                self.reportSaveError(error.localizedDescription)
            }
        }
    }

    /// Client-side validation failures land on the same inline error line.
    func reportSaveError(_ message: String) {
        saveError = message
        saveErrorRevision += 1
    }

    func clearSaveError() {
        guard saveError != nil else { return }
        saveError = nil
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        disconnectError = nil
        Task { [weak self, client] in
            do {
                _ = try await client.disconnect()
                guard let self else { return }
                self.isDisconnecting = false
                self.refresh()
            } catch {
                guard let self else { return }
                self.isDisconnecting = false
                self.disconnectError = error.localizedDescription
            }
        }
    }

    // MARK: Screen

    enum Screen: Equatable {
        case signedOut
        case loading
        case failed(String)
        case unavailable
        /// Bucket connected; `onPlan` false = plan lapsed (edit locked).
        case summary(StorageBucketStatus, onPlan: Bool)
        /// The connect/edit form. `editing` prefills from the connected
        /// bucket; `locked` = plan doesn't include custom storage.
        case form(StorageBucketStatus, editing: ConnectedStorageBucket?, locked: Bool)
    }

    var screen: Screen {
        switch load {
        case .signedOut: return .signedOut
        case .loading: return .loading
        case .failed(let message): return .failed(message)
        case .loaded(let status):
            guard status.available else { return .unavailable }
            if let bucket = status.bucket {
                if isEditing && status.enabled {
                    return .form(status, editing: bucket, locked: false)
                }
                return .summary(status, onPlan: status.enabled)
            }
            return .form(status, editing: nil, locked: !status.enabled)
        }
    }
}

// MARK: - Pane

@MainActor
final class StorageSettingsPane: NSView {
    let model: StorageSettingsModel
    private let onSignIn: () -> Void

    private let titleField = NSTextField(labelWithString: "Storage")
    private let introField = CCWrappingLabel(
        "Keep share-link videos in your own S3-compatible bucket. New uploads go straight to it."
    )
    private let scroll = NSScrollView()
    private let content = NSStackView()

    private var renderedScreen: StorageSettingsModel.Screen?
    private var form: StorageBucketForm?
    private var summaryCallout: CCCallout?
    private var disconnectButton: CCButton?
    private var screenObservation: SurfaceObservation?
    private var formObservation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?

    init(client: StorageBucketClient, onSignIn: @escaping () -> Void) {
        model = StorageSettingsModel(client: client)
        self.onSignIn = onSignIn
        super.init(frame: .zero)

        titleField.font = CCTheme.font.title

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = CCSpace.md
        content.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: CCSpace.xl, right: 0)

        // Same scroll recipe as CCDialog: a flipped document pinned to the
        // clip view's top and width, holding an (unflipped) stack.
        let document = StorageFlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .automatic

        for view in [titleField, introField, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            introField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: CCSpace.xs),
            introField.leadingAnchor.constraint(equalTo: leadingAnchor),
            introField.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: introField.bottomAnchor, constant: CCSpace.md),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.titleField.textColor = CCTheme.color.foreground
            self.introField.font = CCTheme.font.label
            self.introField.textColor = CCTheme.color.mutedForeground
        }
        screenObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let screen = self.model.screen
            guard screen != self.renderedScreen else { return }
            self.render(screen)
        }
        formObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let saving = self.model.isSaving
            let error = self.model.saveError
            let revision = self.model.saveErrorRevision
            let disconnecting = self.model.isDisconnecting
            let disconnectError = self.model.disconnectError
            self.form?.setBusy(saving)
            self.form?.showError(error, revision: revision)
            self.applyDisconnectState(busy: disconnecting, error: disconnectError)
        }
        model.refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Rendering

    private func render(_ screen: StorageSettingsModel.Screen) {
        let isFirstRender = renderedScreen == nil
        renderedScreen = screen
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        form = nil
        summaryCallout = nil
        disconnectButton = nil

        switch screen {
        case .signedOut:
            let signIn = CCButton(title: "Sign In…", style: .primary, size: .sm) { [weak self] in
                self?.onSignIn()
            }
            addCard([SettingsRow(
                title: "Not signed in",
                subtitle: "Sign in to store share videos in your own bucket.",
                control: signIn
            )])

        case .loading:
            let spinner = CCSpinner(diameter: 16)
            spinner.startAnimation(nil)
            addCard([SettingsRow(
                title: "Checking your storage…",
                subtitle: "Asking CaptureCat which bucket your share videos use.",
                control: spinner
            )])

        case .failed(let message):
            let callout = CCCallout(title: "Couldn't load storage settings", message: message,
                                    variant: .destructive)
            callout.setActions([CCButton(title: "Try Again", style: .secondary, size: .sm) { [weak self] in
                self?.model.refresh()
            }])
            addFullWidth(callout)

        case .unavailable:
            let callout = CCCallout(
                title: "Custom storage isn't available right now",
                message: "Share videos keep uploading to CaptureCat storage. Try again later.",
                variant: .warning
            )
            callout.setActions([CCButton(title: "Try Again", style: .secondary, size: .sm) { [weak self] in
                self?.model.refresh()
            }])
            addFullWidth(callout)

        case .summary(let status, let onPlan):
            if !onPlan { addFullWidth(upgradeCallout(connected: true)) }
            if let bucket = status.bucket { renderSummary(bucket, onPlan: onPlan) }
            addRetainedNote(status.retainedCount)

        case .form(let status, let editing, let locked):
            if locked { addFullWidth(upgradeCallout(connected: false)) }
            let form = StorageBucketForm(editing: editing, locked: locked)
            form.onSave = { [weak self] draft in self?.model.save(draft) }
            form.onValidationError = { [weak self] message in self?.model.reportSaveError(message) }
            form.onEdit = { [weak self] in self?.model.clearSaveError() }
            if editing != nil {
                form.onCancel = { [weak self] in
                    self?.model.clearSaveError()
                    self?.model.isEditing = false
                }
            }
            addFullWidth(form)
            self.form = form
            form.setBusy(model.isSaving)
            form.showError(model.saveError, revision: model.saveErrorRevision)
            addRetainedNote(status.retainedCount)
        }

        // Screen swaps arrive with the house stagger (fade + short rise);
        // the very first render rides the Settings pane's own fade-in.
        if !isFirstRender, window != nil {
            layoutSubtreeIfNeeded()
            CCMotion.stagger(content.arrangedSubviews)
        }
    }

    private func renderSummary(_ bucket: ConnectedStorageBucket, onPlan: Bool) {
        let badge = CCBadge("Connected", variant: .primary)
        var location = bucket.region.isEmpty ? [] : [bucket.region]
        if !bucket.pathPrefix.isEmpty { location.append("/\(bucket.pathPrefix)") }
        location.append("Key \(bucket.accessKeyIdHint)")

        var rows: [NSView] = [
            SettingsRow(
                title: "\(bucket.provider.shortTitle) · \(bucket.bucket)",
                subtitle: location.joined(separator: " · "),
                control: badge
            ),
        ]
        if let endpoint = bucket.endpoint {
            rows.append(SettingsRow(title: "Endpoint", subtitle: endpoint, control: StorageNoControl()))
        }
        rows.append(SettingsRow(
            title: "Delivery",
            subtitle: bucket.publicBaseUrl.map { "Public URL — \($0)" }
                ?? "Short-lived signed links (works with private buckets)",
            control: StorageNoControl()
        ))
        let count = bucket.videoCount
        rows.append(SettingsRow(
            title: count == 1 ? "1 share video" : "\(count) share videos",
            subtitle: "Stored in this bucket. "
                + (bucket.verifiedAt.map { "Verified \(Self.dateFormatter.string(from: $0))." } ?? ""),
            control: StorageNoControl()
        ))

        let edit = CCButton(title: "Edit…", style: .secondary, size: .sm) { [weak self] in
            self?.model.isEditing = true
        }
        edit.isEnabled = onPlan
        let disconnect = CCButton(title: "Disconnect…", style: .outline, size: .sm) { [weak self] in
            self?.confirmDisconnect(bucket)
        }
        disconnectButton = disconnect
        let actions = NSStackView(views: [edit, disconnect])
        actions.orientation = .horizontal
        actions.spacing = CCSpace.sm
        rows.append(SettingsRow(
            title: "Manage",
            subtitle: "Editing re-tests the bucket and needs both keys again.",
            control: actions
        ))
        addCard(rows)
        applyDisconnectState(busy: model.isDisconnecting, error: model.disconnectError)
    }

    private func upgradeCallout(connected: Bool) -> CCCallout {
        let callout = CCCallout(
            title: "Upgrade to CaptureCat Pro",
            message: "Storing videos in your own bucket is part of CaptureCat Pro."
                + (connected ? " Videos already in your bucket keep playing." : ""),
            variant: .info
        )
        callout.setActions([CCButton(title: "View Plans", style: .secondary, size: .sm) {
            if let url = URL(string: "https://capturecat.so/pricing") { NSWorkspace.shared.open(url) }
        }])
        return callout
    }

    private func addRetainedNote(_ retained: Int) {
        guard retained > 0 else { return }
        let note = CCWrappingLabel(retained == 1
            ? "1 video still plays from a previously disconnected bucket."
            : "\(retained) videos still play from previously disconnected buckets.")
        note.font = CCTheme.font.caption
        note.textColor = CCTheme.color.mutedForeground
        addFullWidth(note)
    }

    private func applyDisconnectState(busy: Bool, error: String?) {
        guard let disconnectButton else { return }
        disconnectButton.isEnabled = !busy
        disconnectButton.title = busy ? "Disconnecting…" : "Disconnect…"
        if let error {
            guard summaryCallout == nil else { return }
            let callout = CCCallout(title: "Couldn't disconnect", message: error,
                                    variant: .destructive, dismissible: true)
            callout.onDismiss = { [weak self] in self?.summaryCallout = nil }
            addFullWidth(callout)
            summaryCallout = callout
        } else if let callout = summaryCallout {
            summaryCallout = nil
            callout.dismiss()
        }
    }

    private func confirmDisconnect(_ bucket: ConnectedStorageBucket) {
        guard let window else { return }
        let count = bucket.videoCount
        let videos = count == 1 ? "The 1 video" : "The \(count) videos"
        let message = count > 0
            ? "New share videos will upload to CaptureCat storage. \(videos) already in “\(bucket.bucket)” "
                + "keep playing from your bucket, so CaptureCat keeps its access key until they're deleted."
            : "New share videos will upload to CaptureCat storage. Nothing is stored in “\(bucket.bucket)” yet."
        let alert = CCAlert(title: "Disconnect “\(bucket.bucket)”?", message: message)
        alert.addButton("Disconnect", role: .destructive)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] index in
            if index == 0 { self?.model.disconnect() }
        }
    }

    private func addCard(_ rows: [NSView]) {
        let card = CCCard()
        for (index, row) in rows.enumerated() {
            if index > 0 { card.addContent(CCDivider()) }
            card.addContent(row)
        }
        addFullWidth(card)
    }

    private func addFullWidth(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Harness seams

    var probeScreen: StorageSettingsModel.Screen? { renderedScreen }
    var probeForm: StorageBucketForm? { form }
    var probeScroll: NSScrollView { scroll }
    var probeContentViews: [NSView] { content.arrangedSubviews }
    var probeDisconnectButton: CCButton? { disconnectButton }
    var probeSummaryCallout: CCCallout? { summaryCallout }
}

// MARK: - Form

/// The connect/edit form: one card of hairline-divided label|field rows, an
/// inline error that grows open from its top edge, and the Save footer.
@MainActor
final class StorageBucketForm: NSView {
    var onSave: ((StorageBucketDraft) -> Void)?
    var onValidationError: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Any edit (clears a stale error).
    var onEdit: (() -> Void)?

    private let editing: ConnectedStorageBucket?
    private let locked: Bool
    private var provider: StorageProvider

    private let providerSelect = CCSelect(placeholder: "Provider…")
    private let endpointField = CCField(placeholder: "")
    private let regionField = CCField(placeholder: "")
    private let bucketField = CCField(placeholder: "my-videos")
    private let prefixField = CCField(placeholder: "capturecat/")
    private let accessKeyField = CCField(placeholder: "Access key ID")
    private let secretField = CCSecureField(placeholder: "Secret access key")
    private let publicURLField = CCField(placeholder: "https://cdn.example.com")
    private let pathStyleToggle = CCToggle()
    private var endpointReveal: CCCollapsible!

    private let errorCallout = CCCallout(title: "Couldn't save this bucket", message: " ",
                                         variant: .destructive)
    private var errorReveal: CCCollapsible!
    private var shownErrorRevision = -1
    private(set) var errorMessage: String?

    private let saveButton = CCButton(title: "Test & Save", style: .primary)
    private var cancelButton: CCButton?
    private let spinner = CCSpinner(diameter: 14)
    private let footnote = CCWrappingLabel(
        "CaptureCat writes, reads and deletes a small test file before saving."
    )
    private var themeObservation: CCThemeObservation?

    init(editing: ConnectedStorageBucket?, locked: Bool) {
        self.editing = editing
        self.locked = locked
        provider = editing?.provider ?? .aws
        super.init(frame: .zero)

        // Provider select + prefill.
        let providers = StorageProvider.allCases
        providerSelect.options = providers.map { .init(title: $0.title) }
        providerSelect.selectedIndex = providers.firstIndex(of: provider)
        providerSelect.onSelect = { [weak self] index in self?.pickProvider(providers[index]) }

        if let editing {
            endpointField.stringValue = editing.endpoint ?? ""
            regionField.stringValue = editing.region
            bucketField.stringValue = editing.bucket
            prefixField.stringValue = editing.pathPrefix
            publicURLField.stringValue = editing.publicBaseUrl ?? ""
            pathStyleToggle.isOn = editing.forcePathStyle
            accessKeyField.placeholderString = "Re-enter — currently \(editing.accessKeyIdHint)"
            secretField.placeholderString = "Re-enter the secret key"
        } else {
            regionField.stringValue = provider.defaultRegion
            pathStyleToggle.isOn = provider.defaultPathStyle
        }
        refreshPlaceholders()
        for field in allFields {
            field.onTextChange = { [weak self, weak field] _ in
                field?.isError = false
                self?.onEdit?()
                if field === self?.regionField { self?.refreshPlaceholders() }
            }
        }

        // Rows: one card, hairlines between, label column + filling field.
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        func add(_ view: NSView, divider: Bool = true) {
            if divider, !rows.arrangedSubviews.isEmpty {
                let line = CCDivider()
                rows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        add(StorageFieldRow(title: "Provider", control: providerSelect))
        // Endpoint (with its leading hairline) folds away for AWS; the
        // collapsible moves only its bottom edge, landing on the bounce.
        let endpointBlock = NSStackView()
        endpointBlock.orientation = .vertical
        endpointBlock.spacing = 0
        let endpointLine = CCDivider()
        let endpointRow = StorageFieldRow(title: "Endpoint", control: endpointField)
        endpointBlock.addArrangedSubview(endpointLine)
        endpointBlock.addArrangedSubview(endpointRow)
        endpointLine.widthAnchor.constraint(equalTo: endpointBlock.widthAnchor).isActive = true
        endpointRow.widthAnchor.constraint(equalTo: endpointBlock.widthAnchor).isActive = true
        endpointReveal = CCCollapsible(content: endpointBlock, expanded: provider.needsEndpoint)
        add(endpointReveal, divider: false)
        add(StorageFieldRow(title: "Region", control: regionField))
        add(StorageFieldRow(title: "Bucket", control: bucketField))
        add(StorageFieldRow(title: "Path prefix", control: prefixField,
                            caption: "Optional. Videos are stored under this folder."))
        add(StorageFieldRow(title: "Access key ID", control: accessKeyField))
        add(StorageFieldRow(
            title: "Secret key", control: secretField,
            caption: editing == nil ? nil : "Both keys are needed on every save — the secret is never sent back."
        ))
        add(StorageFieldRow(
            title: "Public base URL", control: publicURLField,
            caption: "Leave empty to serve through short-lived signed links — works with private buckets"
        ))
        let pathStyleRow = SettingsRow(
            title: "Path-style URLs",
            subtitle: "Advanced. Address the bucket as endpoint/bucket — MinIO and most self-hosted servers need this.",
            control: pathStyleToggle
        )
        add(StorageRowInset(pathStyleRow))

        let card = CCCard()
        card.addContent(rows)

        // Inline error: grows open beneath the card (bottom edge only).
        errorCallout.playsEntrance = false

        // Footer: footnote leading, [Cancel] [spinner] [Save] trailing.
        saveButton.onClick = { [weak self] in self?.submit() }
        var trailing: [NSView] = []
        if editing != nil {
            let cancel = CCButton(title: "Cancel", style: .ghost) { [weak self] in self?.onCancel?() }
            cancelButton = cancel
            trailing.append(cancel)
        }
        trailing.append(spinner)
        trailing.append(saveButton)
        let buttons = NSStackView(views: trailing)
        buttons.orientation = .horizontal
        buttons.spacing = CCSpace.sm
        let footer = NSView()
        for view in [footnote, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            footnote.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: CCSpace.xs),
            footnote.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footnote.topAnchor.constraint(greaterThanOrEqualTo: footer.topAnchor),
            footnote.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -CCSpace.md),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The error block carries its own top gap so a folded error adds
        // no space at all.
        let errorBlock = NSStackView()
        errorBlock.orientation = .vertical
        errorBlock.edgeInsets = NSEdgeInsets(top: CCSpace.md, left: 0, bottom: 0, right: 0)
        errorBlock.addArrangedSubview(errorCallout)
        errorCallout.widthAnchor.constraint(equalTo: errorBlock.widthAnchor).isActive = true
        errorReveal = CCCollapsible(content: errorBlock, expanded: false)

        for view in [card, errorReveal!, footer] as [NSView] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(CCSpace.md, after: errorReveal)

        if locked {
            for control in [providerSelect, pathStyleToggle, saveButton] as [NSControl] {
                control.isEnabled = false
            }
            for field in allFields {
                field.isEnabled = false
                field.alphaValue = CCTheme.current.disabledAlpha
            }
            footnote.stringValue = "Available on plans with custom storage."
        }

        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.footnote.font = CCTheme.font.caption
            self.footnote.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var allFields: [any CCTextWell] {
        [endpointField, regionField, bucketField, prefixField, accessKeyField, secretField, publicURLField]
    }

    // MARK: Provider presets

    func pickProvider(_ next: StorageProvider) {
        let previous = provider
        guard next != previous else { return }
        provider = next
        providerSelect.selectedIndex = StorageProvider.allCases.firstIndex(of: next)
        // Prefill the region unless the user typed their own.
        let region = regionField.stringValue.trimmingCharacters(in: .whitespaces)
        if region.isEmpty || region == previous.defaultRegion {
            regionField.stringValue = next.defaultRegion
        }
        // Path-style follows the preset unless the user flipped it.
        if pathStyleToggle.isOn == previous.defaultPathStyle {
            pathStyleToggle.isOn = next.defaultPathStyle
        }
        if !next.needsEndpoint { endpointField.isError = false }
        refreshPlaceholders()
        endpointReveal.setExpanded(next.needsEndpoint, animated: window != nil)
        onEdit?()
    }

    private func refreshPlaceholders() {
        endpointField.placeholderString = provider.endpointPlaceholder(region: regionField.stringValue)
        regionField.placeholderString = provider.regionPlaceholder
    }

    // MARK: Submit

    private func trimmed(_ field: any CCTextWell) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the draft, or flags the first missing field and returns nil.
    func makeDraft() -> StorageBucketDraft? {
        let region = trimmed(regionField)
        var endpoint: String? = nil
        if provider.needsEndpoint {
            let typed = trimmed(endpointField)
            endpoint = typed.isEmpty ? provider.derivedEndpoint(region: region) : typed
        }
        let checks: [(Bool, any CCTextWell, String)] = [
            (provider.needsEndpoint && endpoint == nil, endpointField,
             "Enter the endpoint URL for \(provider.title)."),
            (region.isEmpty, regionField, "Enter the bucket's region."),
            (trimmed(bucketField).isEmpty, bucketField, "Enter the bucket name."),
            (trimmed(accessKeyField).isEmpty, accessKeyField, "Enter the access key ID."),
            (secretField.stringValue.isEmpty, secretField, "Enter the secret access key."),
        ]
        for field in allFields { field.isError = false }
        for (missing, field, message) in checks where missing {
            field.isError = true
            onValidationError?(message)
            return nil
        }
        let publicURL = trimmed(publicURLField)
        return StorageBucketDraft(
            provider: provider,
            endpoint: endpoint,
            region: region,
            bucket: trimmed(bucketField),
            pathPrefix: trimmed(prefixField),
            forcePathStyle: pathStyleToggle.isOn,
            publicBaseUrl: publicURL.isEmpty ? nil : publicURL,
            accessKeyId: trimmed(accessKeyField),
            secretAccessKey: secretField.stringValue
        )
    }

    private func submit() {
        guard !locked else { return }
        window?.makeFirstResponder(nil)
        guard let draft = makeDraft() else { return }
        onSave?(draft)
    }

    // MARK: State in

    private(set) var isBusy = false

    func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        saveButton.title = busy ? "Testing bucket…" : "Test & Save"
        saveButton.isEnabled = !busy && !locked
        cancelButton?.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        guard !locked else { return }
        providerSelect.isEnabled = !busy
        pathStyleToggle.isEnabled = !busy
        for field in allFields { field.isEnabled = !busy }
    }

    func showError(_ message: String?, revision: Int) {
        if let message {
            guard revision != shownErrorRevision || message != errorMessage else { return }
            shownErrorRevision = revision
            let wasShown = errorMessage != nil
            errorMessage = message
            errorCallout.setMessage(message)
            if wasShown {
                // Same slot, new words: a small pop re-announces it.
                if window != nil { CCMotion.pop(errorCallout, from: 0.97) }
            } else {
                errorReveal.setExpanded(true, animated: window != nil)
            }
        } else if errorMessage != nil {
            errorMessage = nil
            errorReveal.setExpanded(false, animated: window != nil)
        }
    }

    // MARK: Harness seams

    var probeProvider: StorageProvider { provider }
    var probeEndpointReveal: CCCollapsible { endpointReveal }
    var probeErrorReveal: CCCollapsible { errorReveal }
    var probeErrorCallout: CCCallout { errorCallout }
    var probeSaveButton: CCButton { saveButton }
    var probeSpinner: CCSpinner { spinner }
    var probeSecretField: CCSecureField { secretField }
    var probeFields: (endpoint: CCField, region: CCField, bucket: CCField, prefix: CCField,
                      accessKey: CCField, secret: CCSecureField, publicURL: CCField) {
        (endpointField, regionField, bucketField, prefixField, accessKeyField, secretField, publicURLField)
    }
    func probeSubmit() { submit() }
    func probeCancel() { onCancel?() }
}

// MARK: - Rows

/// Form row: a fixed label column, the control filling the rest, and an
/// optional caption wrapping under the control. Carries its own vertical
/// padding so hairline rows can sit in a zero-spacing stack.
@MainActor
final class StorageFieldRow: NSView {
    static let labelWidth: CGFloat = 112
    static let verticalPad: CGFloat = 7

    let control: NSView
    private let titleField: NSTextField
    private let captionField = CCWrappingLabel()
    private var themeObservation: CCThemeObservation?

    init(title: String, control: NSView, caption: String? = nil) {
        self.control = control
        titleField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleField.lineBreakMode = .byTruncatingTail
        captionField.stringValue = caption ?? ""
        captionField.isHidden = caption == nil

        for view in [titleField, control, captionField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = Self.verticalPad
        let controlLeading = Self.labelWidth + CCSpace.md
        var constraints: [NSLayoutConstraint] = [
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.widthAnchor.constraint(equalToConstant: Self.labelWidth),
            titleField.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            control.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: controlLeading),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if caption != nil {
            constraints += [
                captionField.topAnchor.constraint(equalTo: control.bottomAnchor, constant: CCSpace.xs),
                captionField.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: CCSpace.xxs),
                captionField.trailingAnchor.constraint(equalTo: trailingAnchor),
                captionField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            ]
        } else {
            constraints.append(control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad))
        }
        NSLayoutConstraint.activate(constraints)
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.titleField.font = CCTheme.font.chip
            self.titleField.textColor = CCTheme.color.foreground
            self.captionField.font = CCTheme.font.caption
            self.captionField.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Gives a SettingsRow the same vertical padding as StorageFieldRow.
@MainActor
private final class StorageRowInset: NSView {
    init(_ row: NSView) {
        super.init(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: StorageFieldRow.verticalPad),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -StorageFieldRow.verticalPad),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// SettingsRow's control slot for read-only rows: a zero-size spacer.
@MainActor
private final class StorageNoControl: NSView {
    override var intrinsicContentSize: NSSize { .zero }
}

private final class StorageFlippedView: NSView {
    override var isFlipped: Bool { true }
}
