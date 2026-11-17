# CaptureCat for iPhone and iPad — App Store readiness (Studio 6c)

Status: **DRAFT for the owner.** Everything below stops short of anything that
contacts Apple: nothing has been uploaded, validated with Apple, submitted, or
created in App Store Connect. The listing copy is a draft to edit; the privacy
and export answers are derived from the code and checked against the shipped
binaries by `apps/ios/scripts/ios-release-check.sh`.

## What the owner must do to ship

In order. Items marked **blocker** would get the build rejected or block the
upload as things stand.

1. **Blocker — account deletion inside the app** (App Review Guideline 5.1.1(v)).
   The sign-in sheet opens the web sign-in page, where Google or Apple creates an
   account on first use, so accounts can be created from inside the app. Apple
   then requires a way to *start* deleting the account inside the app; today the
   only route is emailing contact@capturecat.so. Decide the flow (e.g. a
   "Delete account…" row on the Account screen that opens a web page that
   deletes the account and its cloud projects, or an API endpoint). This needs
   API work and a production deploy, so it is not done here.
2. **Likely review question — comments are user-generated content** (Guideline
   1.2). The Shares screen shows the comment thread viewers leave on a shared
   video and lets the owner reply. Apple asks UGC apps for a way to report or
   remove objectionable content and to block abusive users. Comments can be
   turned off per video on the web and admin moderation exists (migration
   0038), but there is no report / delete / block control in the iOS app.
   Either add one (delete a comment on your own video, block a commenter) or
   explain the owner-only scope in the review notes (draft below does).
3. **Create the App Store Connect record** (owner, in App Store Connect):
   platform iOS, name **CaptureCat**, primary language English (U.S.),
   bundle ID **so.capturecat.ios** (already registered: the development
   profiles on this Mac are for it), SKU e.g. `capturecat-ios`. Paste the
   listing, privacy and age-rating answers below.
4. **Distribution signing.** This Mac has an *Apple Development* and a
   *Developer ID Application* certificate but **no Apple Distribution
   certificate and no App Store profiles**, so `ios-archive.sh` stops after the
   (development-signed) archive. Either:
   - Xcode → Settings → Accounts → the team → Manage Certificates → + Apple
     Distribution (or let Xcode Organizer's *Distribute App → App Store Connect*
     create it with automatic signing), then re-run
     `apps/ios/scripts/ios-archive.sh` — the export step will produce the .ipa; or
   - archive in Xcode (Product → Archive with the CaptureCat scheme) and use
     Organizer → Distribute App → App Store Connect → Upload, which creates the
     distribution certificate and the three App Store profiles
     (`so.capturecat.ios`, `.broadcast`, `.share`) for you.
   The App IDs need the **App Groups** (`group.so.capturecat.ios`), **Push
   Notifications** and **Time Sensitive Notifications** capabilities — they
   already have them for development.
5. **APNs for production.** Release builds register with
   `apnsEnvironment: "production"`; the API's APNs secrets (`APNS_KEY`,
   `APNS_KEY_ID`, `APNS_TEAM_ID`) must work against the production APNs host
   for "use this iPhone" pushes from the Mac. (Owner-only secrets.)
6. **Deploy the API that knows `X-CC-Client: ios`** (on studio-phase1, 4d99ea3)
   so iOS saves show as "iOS" in History instead of "Other". Not a review
   blocker.
7. **Demo account for App Review** (owner). Sign-in is Google or Apple only, so
   the reviewer needs a Google account whose password can go in the review
   notes: create one just for review (a Gmail or Workspace address such as
   `appreview@capturecat.so`), sign in to CaptureCat with it once, and turn off
   2-step prompts that would need your phone. Seed it with 3–4 cloud projects
   (a Mac screen recording with cursor data, an iPhone recording, a
   screenshot) and one shared video with a couple of comments, so every screen
   has content; put it on Pro so nothing is gated.
8. **Screenshots** (plan below) and the **App Preview** video if wanted.
9. **Upload** the build (Organizer or Transporter), add it to TestFlight
   internal testing first, then submit for review.

## Versions

- **MARKETING_VERSION** (`CFBundleShortVersionString`, what the store shows):
  `1.0` for the first release, then `1.1`, `1.2` … per release. The iOS app
  versions on its own; it does not follow the Mac app's 1.5.x.
- **BUILD** (`CFBundleVersion`): a plain integer, **+1 for every upload**,
  TestFlight included, never reused (App Store Connect refuses a duplicate).
- Both live at the top of `apps/ios/scripts/gen-xcodeproj.py` and apply to the
  app **and both extensions** (they must match or the upload is rejected — the
  gate checks it). For a one-off build, override without regenerating:
  `MARKETING_VERSION=1.1 BUILD=7 apps/ios/scripts/ios-archive.sh`.
- Minimum OS: **iOS 18.0** (the companion: library, shares, Wi-Fi streaming,
  record on iPhone, screenshots). The studio editor needs **iOS 26** and is
  gated with `#available(iOS 26, *)`; on iOS 18–25 a project opens to its
  detail screen with "Open in web editor".

## Listing (draft)

| Field | Limit | Draft |
|---|---|---|
| Name | 30 | CaptureCat |
| Subtitle | 30 | Edit and share screen videos |
| Promotional text | 170 | Edit your recordings on iPhone and iPad with the same editor as the Mac app. Stream your iPhone screen to your Mac over Wi-Fi, no cable needed. |
| Keywords | 100 | screen recorder,screen recording,video editor,zoom,captions,subtitles,tutorial,demo,walkthrough |
| Primary category | | Productivity (matches `LSApplicationCategoryType` and the Mac app) |
| Secondary category | | Photo & Video |
| Support URL | | https://capturecat.so/contact |
| Marketing URL | | https://capturecat.so |
| Privacy policy URL | | https://capturecat.so/privacy |
| Copyright | | 2026 CaptureCat |

Keep pricing and plan names out of the listing and the app: the app sells
nothing, and the store copy should not point at a web purchase.

**Description** (≤ 4000):

> CaptureCat turns screen recordings into finished videos. Record on your Mac or
> your iPhone, then edit on whichever device is in your hand. Projects stay in
> sync, so an edit made on the iPad is there when you open the Mac.
>
> EDIT ON IPHONE AND IPAD
> The editor uses the same rendering as CaptureCat for Mac, so a project looks
> the same on every device and the export matches the preview. Trim and cut,
> speed up quiet stretches, adjust zooms, add text, arrows and callouts, change
> the background, padding and device frame. Generate captions on the device,
> record a voice-over, or remove the background behind your camera. Every
> change can be undone, and History keeps earlier versions you can compare and
> restore.
>
> STREAM YOUR IPHONE TO YOUR MAC
> Start a broadcast and a Mac on the same Wi-Fi records your iPhone screen like
> any other source, with the phone frame added in the export. There is no
> pairing: devices signed in to the same account find each other.
>
> RECORD ON THE PHONE
> Record your iPhone screen with app audio and, if you turn it on, your
> microphone. The take uploads to your library when you are back online.
>
> SCREENSHOTS AND VIDEOS
> Use "Save to CaptureCat" in the share sheet, or import from Photos. Each one
> becomes a project you can frame and share.
>
> SHARE
> Copy a link to any shared video and read the comments people leave on it.
>
> CONTINUE ON MAC
> Send the project you are looking at to the Mac editor with one tap.
>
> The editor needs iOS 26 or later. Streaming to a Mac needs CaptureCat for Mac
> on the same Wi-Fi and account. A CaptureCat account is required.

**What's New (1.0):** First release.

## Age rating answers

Every content descriptor: **None** (no violence, sexual content, profanity,
drugs, gambling, horror, medical or mature themes). Additional questions:

| Question | Answer |
|---|---|
| Unrestricted web access | No — the only web view is the system sign-in sheet; "Open in web editor" leaves for Safari |
| User-generated content | **Yes** — comments on the user's own shared videos (see owner item 2) |
| Messaging and chat | No |
| Advertising | No |
| Contests, gambling, loot boxes | No |
| Parental controls / age assurance | No |
| Health or wellness | No |

Expected rating: **4+** (UGC may move it to 9+ / 12+ under the 2025 questionnaire — accept what App Store Connect computes).

## App Privacy ("nutrition label") answers

Source of truth: the three privacy manifests in `apps/ios/Config/Privacy/`
(the gate fails if this table and the manifests disagree). **Tracking: No** —
CaptureCat does not track, has no advertising, analytics or crash SDKs, and
shares nothing with data brokers. Everything below is **linked to the user's
identity** and used **only for App Functionality**.

<!-- privacy-label:start -->
| App Store data type | Manifest identifier | Why |
|---|---|---|
| Contact Info → Name | `NSPrivacyCollectedDataTypeName` | Account name from sign-up (Google / Apple), shown on the Account screen |
| Contact Info → Email Address | `NSPrivacyCollectedDataTypeEmailAddress` | Account email: sign-in and the Account screen |
| Identifiers → User ID | `NSPrivacyCollectedDataTypeUserID` | Every API call is made as the signed-in user (app and share extension) |
| Identifiers → Device ID | `NSPrivacyCollectedDataTypeDeviceID` | A random per-install id and the push token, so the user's Mac can list this device and ask it to stream |
| User Content → Photos or Videos | `NSPrivacyCollectedDataTypePhotosorVideos` | Recordings, screenshots and imported videos the user uploads as cloud projects (app and share extension) |
| User Content → Audio Data | `NSPrivacyCollectedDataTypeAudioData` | Microphone audio inside uploaded recordings and editor voice-overs that sync to the user's cloud project |
| User Content → Other User Content | `NSPrivacyCollectedDataTypeOtherUserContent` | Project edits, names, share links and comments |
| Other Data → Other Data Types | `NSPrivacyCollectedDataTypeOtherDataTypes` | Device name, model and OS / app version sent with the device registration, so the Mac shows which device it is |
<!-- privacy-label:end -->

Not collected: location, contacts, health, financial info, browsing or search
history, purchases, usage data / analytics, diagnostics (no crash or
performance reporting beyond Apple's own opt-in reports), advertising data.
Transcription runs on the device (WhisperKit); its model is downloaded once
from Hugging Face with no account or user data attached. The broadcast
extension sends nothing to CaptureCat's servers: it streams to the user's own
Mac over the local network or hands the take to the app.

**Required-reason APIs** (declared in the manifests, verified in the binaries):

| Bundle | Category | Reasons |
|---|---|---|
| App | UserDefaults | CA92.1 (app-only settings), 1C8F.1 (the App Group suite shared with the extensions) |
| App | File timestamp | C617.1 (files inside the app container: sync conflict order, stale partial downloads, a cache key) |
| Broadcast | UserDefaults | CA92.1, 1C8F.1 (the per-install device id in the App Group) |
| Share | — | none in its binary |

WhisperKit and its packages are statically linked into the app binary, so the
app's manifest covers them (the gate scans that merged binary); swift-crypto
ships its own (empty) manifest in its resource bundle. None of the packages is
on Apple's list of SDKs that need their own signed manifest.

## Export compliance

`ITSAppUsesNonExemptEncryption` = **NO**. App Store Connect answers: *Does your
app use encryption?* **Yes** → *only standard encryption within Apple's
operating system* → exempt, no documentation upload.

Why: every cipher the app runs is Apple's own implementation —
- HTTPS to api.capturecat.so, app.capturecat.so and the storage hosts through
  `URLSession` (TLS);
- the iPhone-over-Wi-Fi link: TLS 1.2 with a pre-shared key
  (`TLS_PSK_WITH_AES_128_GCM_SHA256`, RFC 5487 — an IETF standard suite) run by
  **Network.framework**; the app supplies only the key and the suite id
  (`WirelessDeviceProtocol.swift`);
- SHA-256 from **CryptoKit** for content hashes, PKCE and the link-key
  fingerprint — hashing for integrity/authentication, not encryption.

No proprietary algorithm, no bundled crypto library (no OpenSSL/BoringSSL —
swift-crypto re-exports CryptoKit on Apple platforms). The gate re-checks this
on every build and fails if a non-OS crypto library appears in a binary, at
which point the answer must be revisited. (If App Store Connect asks about
distribution in France, the same "OS encryption only" answer applies.)

## App Review notes (draft)

> **Sign in:** use the demo account below (the sign-in sheet offers Google and
> Apple; please choose Google). Email: `<owner fills>` · Password: `<owner fills>`.
>
> **What to look at:**
> - **Library** — the account's cloud projects. Tap a project to play it.
> - **Editor** (iOS 26 or later) — open a project and tap **Edit on iPhone**
>   (or **Edit on iPad**). Try the timeline (drag the playhead, pinch to zoom),
>   the inspector tabs, Undo, and **History** at the end of the inspector's
>   tab rail. On iPad the inspector is a side column.
> - **Shares** (the Library filter) — a shared video with its comments. Comments come from people
>   the account owner shared a link with; the owner can turn comments off per
>   video.
> - **Capture → Record this screen** — starts a ReplayKit broadcast that
>   records the screen locally and uploads it to the library.
> - **Share sheet** — from Photos, share a screenshot to "Save to CaptureCat".
>
> **The Mac app is optional.** "Stream to Mac" and "Continue on Mac" need
> CaptureCat for Mac on the same Wi-Fi and account; without a Mac the app
> explains that and offers the web editor. Everything else works on its own.
>
> **Permissions:** local network (finding the user's Mac), microphone
> (voice-over, and the broadcast's mic toggle), add-only Photos access (saving
> exports), notifications (the Mac asks the phone to start streaming).

## Screenshot plan

App Store Connect needs **iPhone 6.9"** (1320 × 2868 portrait) and, because the
app runs on iPad, **iPad 13"** (2064 × 2752 portrait); smaller sizes are scaled
from these. Use the demo account's content, light appearance, real data — no
mock frames. Up to 10 per size; plan 6:

| # | iPhone 6.9" | iPad 13" |
|---|---|---|
| 1 | Editor on a Mac recording: stage + timeline, a zoom block selected | Editor: stage, timeline and the inspector column side by side |
| 2 | Inspector sheet raised: Background pane (wallpaper + padding) | Inspector: Camera pane with background removal |
| 3 | Captions generated on the device (Subtitles pane + text on the stage) | Captions on the stage |
| 4 | Library with mixed projects (Mac, iPhone, screenshot) | Library grid |
| 5 | Capture tab: "Stream to Mac" with a Mac found | History with a Compare open |
| 6 | Share detail with comments | Share detail with comments |

Capture them from the Simulator (iPhone 17 Pro Max / iPad Pro 13" (M5)) with
the demo account signed in; caption overlays, if any, in the marketing site's
voice ("Record your screen. Skip the editing.").

## TestFlight

**Beta App Description:** CaptureCat for iPhone and iPad: your CaptureCat
library, the full editor (iOS 26+), recording on the phone, and streaming the
phone's screen to CaptureCat for Mac over Wi-Fi.

**What to Test (build 1):**
- Sign in, then open a project made on the Mac: does the editor's preview match
  the Mac's? Export it and compare.
- Edit on the iPad, then open the same project on the Mac (and the reverse):
  edits should appear without a conflict; edit both at once to see a merge.
- Stream to Mac: Mac and phone on the same Wi-Fi and account, start from the
  Capture tab and from Control Center.
- Record on iPhone with the microphone on; check the take uploads.
- Share a screenshot from Photos to "Save to CaptureCat" while signed out, then
  sign in: it should upload.
- iPad: rotate, use Split View / Stage Manager, resize the window mid-edit.
- Anything that looks different from the Mac, crashes, or loses an edit.

**Beta review** (external testers) needs the same demo account and notes as
App Review.

## Shipping a build

    apps/ios/scripts/ios-release-check.sh            # Release archive (unsigned) + every check above
    SELFTEST=1 apps/ios/scripts/ios-release-check.sh # + 16 injected defects, each must FAIL
    apps/ios/scripts/ios-archive.sh                  # signed archive → check → App Store export (destination: export)

`ios-archive.sh` never uploads and never lets xcodebuild talk to the developer
portal (no `-allowProvisioningUpdates`). With an Apple Distribution
certificate on the Mac it writes `export/CaptureCat.ipa` and confirms the
exported `aps-environment` is `production`; without one it stops after the
archive and says so (exit 2). Upload is the owner's: Xcode Organizer →
Distribute App, or Transporter.

## Info.plist decisions (6c audit)

| Key | Decision |
|---|---|
| `NSMicrophoneUsageDescription` | Kept: editor voice-over (`VoiceOverSession`, AVAudioRecorder) and the broadcast's microphone toggle. Reworded — there are no camera takes on iOS. |
| `NSCameraUsageDescription` | **Removed**: no iOS code opens a camera (camera footage comes from the Mac). |
| `NSPhotoLibraryUsageDescription` | **Removed**: imports use the system photo picker, which needs no permission; nothing reads the library. |
| `NSPhotoLibraryAddUsageDescription` | Kept: the Export sheet saves to Photos with add-only access (`StudioUI/ExportDelivery`, Studio 3d). |
| `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_ccwireless._tcp`) | Kept in the app and the broadcast extension (both browse for the Mac). Reworded for iPad ("this screen"). The share extension has neither. |
| `NSAppTransportSecurity` | Only `NSAllowsLocalNetworking` (the 127.0.0.1 sign-in listener and Debug's loopback API); no arbitrary loads, no exception domains. |
| `ITSAppUsesNonExemptEncryption` | NO (above). |
| `UIBackgroundModes` | None. Uploads and sync use `beginBackgroundTask`. |
| `BGTaskSchedulerPermittedIdentifiers` | `so.capturecat.ios.export.*` — background export (`BGContinuedProcessingTaskRequest`, `StudioExportBackground`, Studio 3d; ids are `<bundle id>.export.<uuid>`). Keep it. If GPU export in the background is wanted later, add the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement (the gate accepts it when the binary uses `BGContinuedProcessingTask`). |
| Orientations | iPhone: portrait + both landscapes; iPad: all four, no `UIRequiresFullScreen` → Split View, Slide Over and Stage Manager. |
| Launch screen | `UILaunchScreen` (empty: the system background in the current appearance, no art). |
| Display names | App and broadcast: "CaptureCat"; share extension: "Save to CaptureCat". |
| Entitlements | App: App Groups, `aps-environment`, Time Sensitive Notifications (the API sends `interruption-level: time-sensitive`); extensions: App Groups. All used; Xcode rewrites `aps-environment` to `production` at App Store export. |

**App icon:** `apps/ios/App/AppIcon.icon` is the Mac app's own Icon Composer
document (byte-identical image) — no new art. Xcode compiles it to Any / Dark /
Tinted renditions for iPhone and iPad, the iOS 26 glass stack, and legacy PNGs
for iOS 18–25; all six appearances render cleanly (checked with `ictool`). The
art is one flattened layer (cat on its own dark background): if a designer
later splits the cat from the background in Icon Composer, the tinted and
clear appearances get proper depth.
