import AppKit

/// `CaptureCat --plan-gate-test` — the Free plan's recording cap (PlanGate):
/// the rule, the offline grace, AppState applying it to the REAL session
/// clock, a paid plan lifting it mid-take, and the pause/resume deep links
/// that used to restart the clock (and with it the cap). Timed checks run the
/// session's own 100 ms tick from a seeded elapsed time, so a 5-minute cap
/// lands in seconds — and each "does not fire" is paired with a "does fire"
/// so the gate can fail.
@MainActor
enum PlanGateHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures.append(label) }
        }

        let free = LicenceState.personal
        let pro = LicenceState.pro(planName: "CaptureCat Pro")
        let cap = PlanGate.freeRecordingSeconds

        // 1) The rule
        expect(cap == 300, "the Free cap is 5 minutes (= the API's FREE_RECORDING_SECONDS)")
        expect(PlanGate.effectiveLimit(userLimit: nil, licence: free) == cap, "no account / Free, No Limit → 5 min")
        expect(PlanGate.effectiveLimit(userLimit: 0, licence: free) == cap, "Free, limit 0 → 5 min")
        expect(PlanGate.effectiveLimit(userLimit: 600, licence: free) == cap, "Free, 10 min → 5 min")
        expect(PlanGate.effectiveLimit(userLimit: 60, licence: free) == 60, "Free, a shorter limit of the user's own stays (1 min)")
        expect(PlanGate.effectiveLimit(userLimit: 0, licence: pro) == nil, "Pro, No Limit → none")
        expect(PlanGate.effectiveLimit(userLimit: 600, licence: pro) == 600, "Pro, 10 min → 10 min")
        expect(PlanGate.cappedByPlan(userLimit: 0, licence: free), "Free, No Limit: the plan ends the take")
        expect(!PlanGate.cappedByPlan(userLimit: 60, licence: free), "Free, 1 min: the user's limit ends it")
        expect(!PlanGate.cappedByPlan(userLimit: cap, licence: free), "Free, exactly 5 min: the user's limit ends it")
        expect(!PlanGate.cappedByPlan(userLimit: 0, licence: pro), "Pro: never the plan")
        expect(PlanGate.isProOnlyLimit(0, licence: free) && PlanGate.isProOnlyLimit(600, licence: free)
               && !PlanGate.isProOnlyLimit(300, licence: free) && !PlanGate.isProOnlyLimit(0, licence: pro),
               "menus: No Limit and >5 min are Pro on Free, nothing is on Pro")

        // 2) The answer without the server (offline, a 5xx): the last
        //    confirmed paid plan for the SAME account, within 7 days.
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        expect(PlanGate.licenceWithoutServer(verifiedAt: now.addingTimeInterval(-6 * day), verifiedPlanName: "CaptureCat Pro",
                                             sameAccount: true, now: now) == pro, "grace: confirmed 6 days ago → Pro")
        expect(PlanGate.licenceWithoutServer(verifiedAt: now.addingTimeInterval(-8 * day), verifiedPlanName: "CaptureCat Pro",
                                             sameAccount: true, now: now) == free, "grace: confirmed 8 days ago → personal")
        expect(PlanGate.licenceWithoutServer(verifiedAt: now.addingTimeInterval(-day), verifiedPlanName: "CaptureCat Pro",
                                             sameAccount: false, now: now) == free, "grace: another account's stamp → personal")
        expect(PlanGate.licenceWithoutServer(verifiedAt: nil, verifiedPlanName: nil, sameAccount: true, now: now) == free,
               "grace: never confirmed (or a definite Free answer cleared it) → personal")
        expect(PlanGate.licenceWithoutServer(verifiedAt: now.addingTimeInterval(3 * day), verifiedPlanName: "CaptureCat Pro",
                                             sameAccount: true, now: now) == free, "grace: a stamp from the future → personal")
        expect(PlanGate.licenceWithoutServer(verifiedAt: now.addingTimeInterval(-day), verifiedPlanName: nil,
                                             sameAccount: true, now: now) == .pro(planName: "Pro"),
               "grace: a stamp saved before plan names were kept still reads as Pro")

        let appState = AppState()
        appState.hasCompletedOnboarding = true // deep links are ignored before onboarding
        let session = appState.recordingSession
        let savedLimit = appState.recordingDurationLimit

        // 3) AppState applies it to the session
        expect(appState.licence == free, "a harness run starts personal (no server, no Keychain)")
        appState.recordingDurationLimit = 0
        expect(session.durationLimit == cap, "Free, No Limit → the session stops at 5 min")
        appState.licence = pro
        expect(session.durationLimit == nil, "Pro lands → the session has no limit")
        appState.recordingDurationLimit = 60
        expect(session.durationLimit == 60, "Pro keeps a user limit (1 min)")
        appState.licence = free
        expect(session.durationLimit == 60, "Free keeps a shorter user limit (1 min)")
        appState.setRecordingDurationLimit(cap)
        expect(appState.recordingDurationLimit == 0 && session.durationLimit == cap,
               "Free: picking the 5-min cap itself stores No Limit, so Pro later lifts it")
        appState.licence = pro
        appState.setRecordingDurationLimit(cap)
        expect(appState.recordingDurationLimit == cap, "Pro: 5 min is a real choice")
        appState.recordingDurationLimit = 0
        appState.licence = free

        var fired = 0
        session.onDurationLimitReached = { fired += 1 }

        Task { @MainActor in
            // 4) The cap fires on the real tick (the gate can fail)…
            session.phase = .recording
            session.debugStartTimer(at: cap - 0.6)
            try? await Task.sleep(for: .milliseconds(1200))
            expect(fired == 1 && session.elapsedTime >= cap, "Free: the tick stops the take at 5:00, once (fired \(fired), clock \(String(format: "%.1f", session.elapsedTime)))")
            session.reset()

            // …and Pro landing mid-take lifts it.
            fired = 0
            session.phase = .recording
            session.debugStartTimer(at: cap - 1.0)
            try? await Task.sleep(for: .milliseconds(300))
            appState.licence = pro
            try? await Task.sleep(for: .milliseconds(1500))
            expect(fired == 0 && session.elapsedTime > cap, "Pro landing mid-take lifts the cap (fired \(fired), clock \(String(format: "%.1f", session.elapsedTime)))")
            session.reset()
            appState.licence = free

            // 5) Pause/resume by deep link keeps the clock (it used to
            //    restart it from zero — and the cap with it).
            let links = DeepLinkHandler(appState: appState)
            session.phase = .recording
            session.debugStartTimer(at: 120)
            try? await Task.sleep(for: .milliseconds(300))
            links.handle(URL(string: "capturecat://pause-recording")!)
            let atPause = session.elapsedTime
            try? await Task.sleep(for: .milliseconds(600))
            expect(session.isPaused && abs(session.elapsedTime - atPause) < 0.15,
                   "pause link: the clock stops (\(String(format: "%.2f", atPause)) → \(String(format: "%.2f", session.elapsedTime)))")
            links.handle(URL(string: "capturecat://resume-recording")!)
            try? await Task.sleep(for: .milliseconds(400))
            expect(session.isRecording && session.elapsedTime >= atPause && session.elapsedTime < atPause + 1,
                   "resume link: the clock carries on from \(String(format: "%.1f", atPause)), not 0 (\(String(format: "%.2f", session.elapsedTime)))")
            session.reset()

            appState.recordingDurationLimit = savedLimit
            let passed = checks - failures.count
            print("\(passed)/\(checks) checks passed")
            if failures.isEmpty {
                print("PLAN-GATE PASS")
                exit(0)
            }
            print("PLAN-GATE FAIL — \(failures.joined(separator: "; "))")
            exit(1)
        }
        NSApplication.shared.run()
        exit(1)
    }
}
