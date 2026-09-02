import AppKit
import UserNotifications

/// Local "Remind me" notifications for captures (video projects AND notes).
///
/// Persistence is the capture record itself: `reminderDate` on Project/Note
/// is the single source of truth, and the pending UNNotificationRequests are
/// derived state — `resync` rebuilds them from disk on every launch, so a
/// relaunch (or a reminder set on another day) never strands or duplicates a
/// notification. Requests are keyed `capture-reminder-<uuid>`, so re-setting
/// a reminder replaces the old one and deleting a capture cancels it.
///
/// Sandbox note: UNUserNotificationCenter works inside the app sandbox with
/// no extra entitlement; the system permission prompt is requested lazily on
/// the first "Remind me".
@MainActor
final class ReminderCenter: NSObject {
    static let shared = ReminderCenter()

    private static let requestPrefix = "capture-reminder-"

    enum CaptureKind: String {
        case project
        case note
    }

    private var didBecomeDelegate = false

    /// Install as the notification-center delegate so clicks route back into
    /// the app. Must run early in launch (GUI instance only) — notification
    /// taps that relaunch the app are delivered right after launch.
    func activate() {
        guard !didBecomeDelegate else { return }
        didBecomeDelegate = true
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization (used by onboarding)

    /// Current authorization status, delivered on the main actor.
    func authorizationStatus(_ completion: @MainActor @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in completion(settings.authorizationStatus) }
        }
    }

    /// Bare authorization request (no notification scheduled) — the
    /// onboarding "Enable Notifications" step.
    func requestAuthorization(_ completion: @MainActor @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in completion(granted) }
            }
    }

    // MARK: - Scheduling

    /// Requests authorization on first use, then schedules (or replaces) the
    /// capture's notification. Calls `completion(false)` when the user has
    /// denied notifications.
    func scheduleReminder(
        id: UUID,
        title: String,
        kind: CaptureKind,
        date: Date,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                guard granted else {
                    completion?(false)
                    return
                }
                self.addRequest(id: id, title: title, kind: kind, date: date)
                completion?(true)
            }
        }
    }

    private func addRequest(id: UUID, title: String, kind: CaptureKind, date: Date) {
        let content = UNMutableNotificationContent()
        content.title = kind == .note ? "Note reminder" : "Capture reminder"
        content.body = title
        content.sound = .default
        content.userInfo = ["captureKind": kind.rawValue, "captureID": id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.requestPrefix + id.uuidString,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancelReminder(for id: UUID) {
        let identifier = Self.requestPrefix + id.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Rebuild pending requests from persisted reminder dates: clears every
    /// capture-reminder request, then re-schedules the future ones. Past-due
    /// dates are cleared off the records (their notification already fired,
    /// or the moment passed while the app was closed).
    func resync(projects: [Project], notes: [Note], projectStore: ProjectStore, noteStore: NoteStore) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            center.getPendingNotificationRequests { pending in
                let stale = pending
                    .map(\.identifier)
                    .filter { $0.hasPrefix(Self.requestPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: stale)
                Task { @MainActor in
                    let now = Date()
                    for project in projects {
                        guard let date = project.reminderDate else { continue }
                        if date > now {
                            self.addRequest(id: project.id, title: project.name, kind: .project, date: date)
                        } else {
                            project.reminderDate = nil
                            projectStore.save(project)
                        }
                    }
                    for note in notes {
                        guard let date = note.reminderDate else { continue }
                        if date > now {
                            self.addRequest(id: note.id, title: note.title, kind: .note, date: date)
                        } else {
                            note.reminderDate = nil
                            noteStore.save(note)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Badge text

    /// Short "in 3d" / "in 5h" style label for an active (future) reminder,
    /// nil when the date is absent or already past.
    nonisolated static func badgeText(for date: Date?, now: Date = Date()) -> String? {
        guard let date, date > now else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds < 3600 {
            return "in \(max(1, Int((seconds / 60).rounded())))m"
        }
        if seconds < 86400 {
            return "in \(Int((seconds / 3600).rounded()))h"
        }
        return "in \(Int((seconds / 86400).rounded()))d"
    }

    // MARK: - Shared "Remind Me" menu

    /// Quick presets + custom date + clear — shared by project cards, note
    /// cards, and the note viewer so all three offer the identical flow.
    static func reminderMenuItems(
        currentDate: Date?,
        makeItem: (String, @escaping () -> Void) -> NSMenuItem,
        set: @escaping (Date) -> Void,
        pickCustom: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> [NSMenuItem] {
        let submenu = NSMenu()
        for (label, days) in [("Tomorrow", 1), ("In 3 Days", 3), ("In 1 Week", 7), ("In 30 Days", 30)] {
            submenu.addItem(makeItem(label) {
                set(Self.reminderDate(daysFromNow: days))
            })
        }
        submenu.addItem(.separator())
        submenu.addItem(makeItem("Custom Date…") { pickCustom() })
        if currentDate != nil {
            submenu.addItem(.separator())
            submenu.addItem(makeItem("Clear Reminder") { clear() })
        }
        let title: String
        if let badge = badgeText(for: currentDate) {
            title = "Remind Me (\(badge))"
        } else {
            title = "Remind Me"
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = submenu
        return [root]
    }

    /// N days out at 9:00 — a morning nudge, not a 2am one.
    nonisolated static func reminderDate(daysFromNow days: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Sheet with an NSDatePicker for the custom-date path.
    static func promptCustomDate(
        in window: NSWindow?,
        current: Date?,
        completion: @escaping (Date?) -> Void
    ) {
        guard let window else { return }
        let alert = CCAlert(title: "Remind Me On…")
        // NSDatePicker is the one stock control still hosted inside the house
        // dialog — a CCKit date picker is its own project.
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 220, height: 27))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = current ?? reminderDate(daysFromNow: 1)
        picker.minDate = Date()
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.textColor = CCTheme.color.foreground
        alert.accessoryView = picker
        alert.addButton("Set Reminder", role: .primary)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { index in
            completion(index == 0 ? picker.dateValue : nil)
        }
    }
}

// MARK: - Click routing

extension ReminderCenter: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let kind = (userInfo["captureKind"] as? String).flatMap(CaptureKind.init(rawValue:))
        let id = (userInfo["captureID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            defer { completionHandler() }
            guard let kind, let id, let appState = AppState.current else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            switch kind {
            case .project:
                if let project = appState.projectStore.projects.first(where: { $0.id == id }) {
                    // The reminder fired — the record's date is now in the past.
                    project.reminderDate = nil
                    appState.projectStore.save(project)
                    appState.openEditor(with: project)
                } else {
                    appState.openProjectBrowser()
                }
            case .note:
                if let note = appState.noteStore.notes.first(where: { $0.id == id }) {
                    note.reminderDate = nil
                    appState.noteStore.save(note)
                    NoteViewerWindowController.present(note: note, appState: appState)
                } else {
                    appState.openProjectBrowser()
                }
            }
        }
    }
}
