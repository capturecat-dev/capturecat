#!/usr/bin/env python3
"""ios-release-check: App Store readiness of a Release archive (Studio 6c).

    ios-release-check.py <CaptureCat.xcarchive> <build.log>

Reads the SHIPPED bundle (the archive's stripped binaries, compiled Info.plists,
Assets.car, privacy manifests) — never the sources alone — and prints one
`RELEASECHECK <check> PASS|FAIL <detail>` line per assertion, then
`RELEASECHECK SUMMARY PASS|FAIL`. Driven by ios-release-check.sh, which builds
the archive and runs the injected-defect self-tests.

What it asserts (docs/ios-app-store.md has the why):
  privacy     every bundle carries a valid PrivacyInfo.xcprivacy; no tracking;
              every required-reason API found in a bundle's binary (nm / the
              ObjC selector table) is declared with an allowed reason code;
              collected types are known Apple identifiers and match the store
              answers in docs/ios-app-store.md
  usage       a usage string exists for every privacy-sensitive API a binary
              links, and none exists for one it doesn't; strings are real
              sentences that name CaptureCat
  plist       version/build set and identical across the app and extensions,
              iOS 18 floor, display name, launch screen, orientations + iPad
              multitasking, ATS not weakened, encryption key present and
              consistent with the crypto the binaries carry, background modes
              and BGTask identifiers only as used
  icons       AppIcon: Any / Dark / Tinted renditions for iPhone and iPad, the
              Liquid Glass stack, the legacy loose PNGs; not placeholder art
  hygiene     no DEBUG harness entry points, probe seams, dev URLs or test keys
              in any shipped binary; StudioLab not embedded; only the two
              extensions; every entitlement used; dSYMs archived
  warnings    zero packaging warnings (asset catalog, Info.plist, entitlements,
              privacy manifest, validation) in the build log
"""
import os
import plistlib
import re
import subprocess
import sys

if sys.argv[1] == "--inject-string":
    # Self-test helper (ios-release-check.sh SELFTEST): plant <text> INSIDE a
    # binary's scanned region by overwriting the start of an existing string
    # that is long enough — as if the code carried it.
    path, text = sys.argv[2], sys.argv[3].encode()
    with open(path, "rb") as f:
        blob = bytearray(f.read())
    import struct
    end = len(blob)
    if blob[:4] == b"\xcf\xfa\xed\xfe":
        ncmds, off = struct.unpack_from("<I", blob, 16)[0], 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", blob, off)
            if cmd == 0x1D:
                end = struct.unpack_from("<I", blob, off + 8)[0]
            off += size
    m = re.search(rb"\x00([\x20-\x7e]{%d,})\x00" % (len(text) + 1), bytes(blob[:end]))
    assert m, "no string long enough to overwrite"
    blob[m.start(1):m.start(1) + len(text) + 1] = text + b"\x00"
    with open(path, "wb") as f:
        f.write(blob)
    sys.exit(0)

ARCHIVE, BUILD_LOG = sys.argv[1], sys.argv[2]
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
IOS = os.path.join(REPO, "apps", "ios")
APP = os.path.join(ARCHIVE, "Products", "Applications", "CaptureCat.app")

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"RELEASECHECK {name} {'PASS' if ok else 'FAIL'}{(' ' + detail) if detail else ''}", flush=True)


def plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


# ---------------------------------------------------------------- bundles

BUNDLES = {
    # name: (bundle dir, executable, entitlements source, expected display name)
    "App": (APP, "CaptureCat", "Config/App.entitlements", "CaptureCat"),
    "Broadcast": (os.path.join(APP, "PlugIns", "CaptureCatBroadcast.appex"), "CaptureCatBroadcast",
                  "Config/Broadcast.entitlements", "CaptureCat"),
    "Share": (os.path.join(APP, "PlugIns", "CaptureCatShare.appex"), "CaptureCatShare",
              "Config/Share.entitlements", "Save to CaptureCat"),
}

if not os.path.isdir(APP):
    check("archive", False, f"no CaptureCat.app in {ARCHIVE}")
    print("RELEASECHECK SUMMARY FAIL")
    sys.exit(1)

products = sorted(os.listdir(os.path.join(ARCHIVE, "Products", "Applications")))
check("archive-products", products == ["CaptureCat.app"], f"Applications/ = {products}")
plugins = sorted(os.listdir(os.path.join(APP, "PlugIns")))
check("extensions", plugins == ["CaptureCatBroadcast.appex", "CaptureCatShare.appex"], f"PlugIns/ = {plugins}")
embedded_apps = [d for d, _, _ in os.walk(APP) if d.endswith(".app") and d != APP]
check("studiolab-not-embedded", not embedded_apps and not any("StudioLab" in f for _, _, fs in os.walk(APP) for f in fs),
      f"nested apps: {embedded_apps}" if embedded_apps else "no StudioLab / nested app in the bundle")


def macho_files(bundle):
    """The bundle's own executable plus any embedded framework / dylib binaries
    (never descending into another .appex — each bundle answers for itself)."""
    out = []
    for root, dirs, files in os.walk(bundle):
        if root != bundle and (root.endswith(".appex") or "/PlugIns" in root[len(bundle):]):
            dirs[:] = []
            continue
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p) or not os.access(p, os.X_OK) and not f.endswith(".dylib"):
                continue
            with open(p, "rb") as fh:
                magic = fh.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                out.append(p)
    return out


class Binary:
    def __init__(self, path):
        self.path = path
        # Imports from the chained-fixups table (dyld_info): `nm -u` misses
        # most of them in a STRIPPED (archived) binary.
        self.undefined = set(run("nm", "-u", path).split())
        for line in run("xcrun", "dyld_info", "-imports", path).splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("0x"):
                self.undefined.add(parts[1])
        with open(path, "rb") as f:
            data = f.read()
        # Stop at the code signature: its certificates and entitlements are
        # Apple's / the signer's, not strings the code carries.
        data = data[:self.code_signature_offset(data)]
        self.strings = set(m.decode() for m in re.findall(rb"[\x20-\x7e]{4,}", data))

    @staticmethod
    def code_signature_offset(data):
        import struct
        if data[:4] != b"\xcf\xfa\xed\xfe":  # thin 64-bit little-endian only
            return len(data)
        ncmds = struct.unpack_from("<I", data, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if cmd == 0x1D:  # LC_CODE_SIGNATURE
                return struct.unpack_from("<I", data, off + 8)[0]
            off += size
        return len(data)

    def has_sym(self, *names):
        return any(n in self.undefined for n in names)

    def has_sym_re(self, pattern):
        r = re.compile(pattern)
        return any(r.search(s) for s in self.undefined)

    def has_str(self, *names):
        return any(n in self.strings for n in names)


binaries = {name: [Binary(p) for p in macho_files(b[0])] for name, b in BUNDLES.items()}
for name, bins in binaries.items():
    check(f"{name}-binaries", bool(bins), ", ".join(os.path.relpath(b.path, ARCHIVE) for b in bins))

# ---------------------------------------------------------------- privacy

REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}
DATA_TYPES = {
    "Name", "EmailAddress", "PhoneNumber", "PhysicalAddress", "OtherUserContactInfo", "Health", "Fitness",
    "PaymentInfo", "CreditInfo", "OtherFinancialInfo", "PreciseLocation", "CoarseLocation", "SensitiveInfo",
    "Contacts", "EmailsOrTextMessages", "PhotosorVideos", "AudioData", "GameplayContent", "CustomerSupport",
    "OtherUserContent", "BrowsingHistory", "SearchHistory", "UserID", "DeviceID", "PurchaseHistory",
    "ProductInteraction", "AdvertisingData", "OtherUsageData", "CrashData", "PerformanceData",
    "OtherDiagnosticData", "EnvironmentScanning", "Hands", "Head", "OtherDataTypes",
}
PURPOSES = {"ThirdPartyAdvertising", "DeveloperAdvertising", "Analytics", "ProductPersonalization",
            "AppFunctionality", "Other"}

STAT_SYMS = ("_stat", "_fstat", "_fstatat", "_lstat", "_stat$INODE64", "_fstat$INODE64", "_lstat$INODE64",
             "_getattrlist", "_fgetattrlist", "_getattrlistat", "_getattrlistbulk", "_setattrlist", "_setattrlistbulk")
API_EVIDENCE = {
    # category: (description, predicate(binary))
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        "NSUserDefaults / CFPreferences",
        lambda b: b.has_sym("_OBJC_CLASS_$_NSUserDefaults") or b.has_sym_re(r"^_CFPreferences")),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "file timestamps (NSFile*Date, NSURL*DateKey, stat/getattrlist)",
        lambda b: b.has_sym("_NSFileModificationDate", "_NSFileCreationDate", "_NSURLContentModificationDateKey",
                            "_NSURLCreationDateKey", "_NSURLContentAccessDateKey",
                            "_NSURLAttributeModificationDateKey", *STAT_SYMS)
        or b.has_sym_re(r"URLResourceValuesV\d+(contentModificationDate|creationDate|contentAccessDate|attributeModificationDate)")),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        "systemUptime / mach_absolute_time",
        lambda b: b.has_sym("_mach_absolute_time") or b.has_str("systemUptime")
        or b.has_sym_re(r"ProcessInfoC12systemUptime")),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "disk space (statfs/statvfs, NSFileSystem*Size, volume capacity keys)",
        lambda b: b.has_sym("_statfs", "_fstatfs", "_statvfs", "_fstatvfs", "_statfs$INODE64", "_fstatfs$INODE64",
                            "_NSFileSystemFreeSize", "_NSFileSystemSize", "_NSURLVolumeAvailableCapacityKey",
                            "_NSURLVolumeAvailableCapacityForImportantUsageKey",
                            "_NSURLVolumeAvailableCapacityForOpportunisticUsageKey", "_NSURLVolumeTotalCapacityKey")
        or b.has_sym_re(r"URLResourceValuesV\d+volume(Available|Total)Capacity")),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        "UITextInputMode.activeInputModes",
        lambda b: b.has_str("activeInputModes")),
}

manifests = {}
for name, (bundle, _, _, _) in BUNDLES.items():
    path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    src = os.path.join(IOS, "Config", "Privacy", name, "PrivacyInfo.xcprivacy")
    if not os.path.exists(path):
        check(f"{name}-privacy-manifest", False, "PrivacyInfo.xcprivacy missing from the bundle root")
        continue
    try:
        m = plist(path)
    except Exception as e:  # noqa: BLE001
        check(f"{name}-privacy-manifest", False, f"not a valid plist: {e}")
        continue
    manifests[name] = m
    same = open(path, "rb").read() == open(src, "rb").read()
    problems = []
    if m.get("NSPrivacyTracking") is not False:
        problems.append("NSPrivacyTracking must be false")
    if m.get("NSPrivacyTrackingDomains"):
        problems.append("NSPrivacyTrackingDomains must be empty")
    for key in ("NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"):
        if key not in m:
            problems.append(f"missing {key}")
    for entry in m.get("NSPrivacyCollectedDataTypes", []):
        t = entry.get("NSPrivacyCollectedDataType", "")
        if t.replace("NSPrivacyCollectedDataType", "", 1) not in DATA_TYPES or not t.startswith("NSPrivacyCollectedDataType"):
            problems.append(f"unknown data type {t!r}")
        if not isinstance(entry.get("NSPrivacyCollectedDataTypeLinked"), bool):
            problems.append(f"{t}: Linked not a bool")
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            problems.append(f"{t}: Tracking must be false")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes") or []
        if not purposes or any(p.replace("NSPrivacyCollectedDataTypePurpose", "", 1) not in PURPOSES for p in purposes):
            problems.append(f"{t}: bad purposes {purposes}")
    for entry in m.get("NSPrivacyAccessedAPITypes", []):
        cat = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons") or []
        if cat not in REASONS:
            problems.append(f"unknown API category {cat!r}")
        elif not reasons or not set(reasons) <= REASONS[cat]:
            problems.append(f"{cat}: reasons {reasons} not in {sorted(REASONS[cat])}")
    check(f"{name}-privacy-manifest", not problems and same,
          "; ".join(problems) if problems else ("valid" + ("" if same else "; DIFFERS from Config/Privacy source")))

    declared = {e.get("NSPrivacyAccessedAPIType") for e in m.get("NSPrivacyAccessedAPITypes", [])}
    found = {cat: desc for cat, (desc, pred) in API_EVIDENCE.items() if any(pred(b) for b in binaries[name])}
    missing = sorted(set(found) - declared)
    unused = sorted(declared - set(found))
    check(f"{name}-required-reason-apis", not missing,
          (f"UNDECLARED: {', '.join(c.replace('NSPrivacyAccessedAPICategory', '') + ' (' + found[c] + ')' for c in missing)}"
           if missing else f"binary uses {sorted(c.replace('NSPrivacyAccessedAPICategory', '') for c in found) or 'none'}")
          + (f"; declared but not found (ok, informational): {[c.replace('NSPrivacyAccessedAPICategory', '') for c in unused]}" if unused else ""))

# Embedded frameworks must carry their own manifest when they call
# required-reason APIs (statically linked packages are covered by the app's).
fw_dir = os.path.join(APP, "Frameworks")
if os.path.isdir(fw_dir):
    for fw in sorted(os.listdir(fw_dir)):
        p = os.path.join(fw_dir, fw)
        bins = [Binary(x) for x in macho_files(p)] if os.path.isdir(p) else [Binary(p)]
        uses = [c for c, (_, pred) in API_EVIDENCE.items() if any(pred(b) for b in bins)]
        has = os.path.exists(os.path.join(p, "PrivacyInfo.xcprivacy"))
        check(f"framework-{fw}-privacy", not uses or has, f"uses {uses}, manifest {'present' if has else 'MISSING'}")
else:
    check("frameworks", True, "none embedded (WhisperKit and its packages are statically linked into the app: the app manifest covers them)")
for root, dirs, files in os.walk(APP):
    if root.endswith(".bundle") and "PrivacyInfo.xcprivacy" in files:
        try:
            plist(os.path.join(root, "PrivacyInfo.xcprivacy"))
            check(f"resource-bundle-{os.path.basename(root)}-privacy", True, "package-provided manifest parses")
        except Exception as e:  # noqa: BLE001
            check(f"resource-bundle-{os.path.basename(root)}-privacy", False, str(e))

# The store answers (docs/ios-app-store.md) list the same collected types.
doc_path = os.path.join(REPO, "docs", "ios-app-store.md")
declared_types = {e["NSPrivacyCollectedDataType"] for m in manifests.values() for e in m.get("NSPrivacyCollectedDataTypes", [])}
if os.path.exists(doc_path):
    doc = open(doc_path).read()
    section = doc.split("<!-- privacy-label:start -->", 1)[-1].split("<!-- privacy-label:end -->", 1)[0] \
        if "<!-- privacy-label:start -->" in doc else ""
    doc_types = set(re.findall(r"NSPrivacyCollectedDataType[A-Za-z]+", section))
    check("store-privacy-answers", bool(section) and doc_types == declared_types,
          f"doc {sorted(t.replace('NSPrivacyCollectedDataType', '') for t in doc_types)} vs manifests "
          f"{sorted(t.replace('NSPrivacyCollectedDataType', '') for t in declared_types)}")
else:
    check("store-privacy-answers", False, "docs/ios-app-store.md missing")

# ---------------------------------------------------------------- usage strings

USAGE = {
    # key: (what, evidence predicate)
    "NSMicrophoneUsageDescription": (
        "microphone (AVAudioRecorder / AVCaptureDevice audio access / record permission)",
        lambda b: b.has_sym("_OBJC_CLASS_$_AVAudioRecorder") or b.has_str("requestRecordPermission:")
        or (b.has_str("requestAccessForMediaType:completionHandler:") and b.has_sym("_AVMediaTypeAudio"))),
    "NSCameraUsageDescription": (
        "camera (AVCaptureDeviceInput / AVCaptureSession / photo output)",
        lambda b: b.has_sym("_OBJC_CLASS_$_AVCaptureDeviceInput", "_OBJC_CLASS_$_AVCaptureSession",
                            "_OBJC_CLASS_$_AVCapturePhotoOutput", "_OBJC_CLASS_$_AVCaptureMultiCamSession")),
    "NSPhotoLibraryAddUsageDescription": (
        "saving to Photos (PHAssetCreationRequest / UISave*ToSavedPhotosAlbum)",
        lambda b: b.has_sym("_OBJC_CLASS_$_PHAssetCreationRequest", "_OBJC_CLASS_$_PHAssetChangeRequest",
                            "_UIImageWriteToSavedPhotosAlbum", "_UISaveVideoAtPathToSavedPhotosAlbum")),
    "NSPhotoLibraryUsageDescription": (
        "reading the photo library (PHAsset fetches / PHImageManager / read-write authorization)",
        lambda b: b.has_sym("_OBJC_CLASS_$_PHImageManager", "_OBJC_CLASS_$_PHCachingImageManager",
                            "_OBJC_CLASS_$_PHAssetResourceManager")
        or b.has_str("fetchAssetsWithLocalIdentifiers:options:", "fetchAssetsWithOptions:",
                     "fetchAssetsWithMediaType:options:", "requestAuthorization:")),
    "NSLocalNetworkUsageDescription": (
        "local network (NWBrowser / NWListener / NetService / Bonjour)",
        # Browsing / advertising — what triggers the local network prompt. A
        # type descriptor alone (Core compiled into the share extension) or a
        # listener on 127.0.0.1 (the sign-in callback) is not.
        lambda b: b.has_sym_re(r"7Network9NWBrowserC(3for|5start)") or b.has_sym("_nw_browser_create", "_nw_browser_start")
        or b.has_sym_re(r"7Network10NWListenerC7service") or b.has_sym("_nw_listener_set_advertise_descriptor")
        or b.has_sym("_OBJC_CLASS_$_NSNetServiceBrowser", "_OBJC_CLASS_$_NSNetService", "_DNSServiceBrowse")),
    "NSSpeechRecognitionUsageDescription": (
        "speech recognition (SFSpeechRecognizer)",
        lambda b: b.has_sym("_OBJC_CLASS_$_SFSpeechRecognizer")),
    "NSLocationWhenInUseUsageDescription": ("location", lambda b: b.has_sym("_OBJC_CLASS_$_CLLocationManager")),
    "NSContactsUsageDescription": ("contacts", lambda b: b.has_sym("_OBJC_CLASS_$_CNContactStore")),
    "NSCalendarsUsageDescription": ("calendars", lambda b: b.has_sym("_OBJC_CLASS_$_EKEventStore")),
    "NSBluetoothAlwaysUsageDescription": ("Bluetooth", lambda b: b.has_sym("_OBJC_CLASS_$_CBCentralManager", "_OBJC_CLASS_$_CBPeripheralManager")),
    "NSMotionUsageDescription": ("motion", lambda b: b.has_sym("_OBJC_CLASS_$_CMMotionActivityManager", "_OBJC_CLASS_$_CMPedometer")),
    "NSFaceIDUsageDescription": ("Face ID", lambda b: b.has_sym("_OBJC_CLASS_$_LAContext")),
    "NSUserTrackingUsageDescription": ("tracking", lambda b: b.has_sym("_OBJC_CLASS_$_ATTrackingManager")),
    "NSHealthShareUsageDescription": ("Health", lambda b: b.has_sym("_OBJC_CLASS_$_HKHealthStore")),
}
# Strings declared AHEAD of the code that uses them, each naming the work that
# links it. Without this the gate would demand removing a key the next merge
# needs (iOS terminates an app that touches Photos with no usage string).
PENDING = {
    ("App", "NSPhotoLibraryAddUsageDescription"):
        "StudioUI/ExportDelivery (save to Photos, add-only) — reached by the in-flight Export sheet; StudioLab only today",
}
infos = {}
for name, (bundle, exe, _, _) in BUNDLES.items():
    info = plist(os.path.join(bundle, "Info.plist"))
    infos[name] = info
    for key, (what, pred) in USAGE.items():
        used = any(pred(b) for b in binaries[name])
        text = info.get(key)
        if used and not text:
            check(f"{name}-usage-{key}", False, f"binary uses {what} but Info.plist has no {key}")
        elif text and not used and (name, key) in PENDING:
            check(f"{name}-usage-{key}", "CaptureCat" in text, f"{text!r} — PENDING: {PENDING[(name, key)]}")
        elif text and not used:
            check(f"{name}-usage-{key}", False, f"{key} present but the binary uses no {what} — remove the unused string")
        elif text:
            bad = [w for w in ("TODO", "TBD", "placeholder", "lorem", "StudioLab", "Cappd") if w.lower() in text.lower()]
            good = len(text) >= 30 and "CaptureCat" in text and text.rstrip().endswith(".") and not bad
            check(f"{name}-usage-{key}", good, repr(text) + (f" bad words {bad}" if bad else ""))
    # Bonjour: the local-network key needs the service types it browses.
    if info.get("NSLocalNetworkUsageDescription"):
        services = info.get("NSBonjourServices") or []
        ok = bool(services) and all(re.fullmatch(r"_[a-z0-9-]+\._(tcp|udp)", s) for s in services)
        check(f"{name}-bonjour-services", ok, f"{services}")

# ---------------------------------------------------------------- Info.plist

app = infos["App"]
ver, build = app.get("CFBundleShortVersionString"), app.get("CFBundleVersion")
check("version", bool(ver) and re.fullmatch(r"\d+(\.\d+){0,2}", ver or "") is not None
      and bool(build) and re.fullmatch(r"\d+(\.\d+){0,2}", build or "") is not None, f"{ver} ({build})")
for name in ("Broadcast", "Share"):
    i = infos[name]
    check(f"{name}-version-matches-app",
          (i.get("CFBundleShortVersionString"), i.get("CFBundleVersion")) == (ver, build),
          f"{i.get('CFBundleShortVersionString')} ({i.get('CFBundleVersion')}) vs app {ver} ({build})")
for name, info in infos.items():
    check(f"{name}-minimum-os", info.get("MinimumOSVersion") == "18.0", f"MinimumOSVersion {info.get('MinimumOSVersion')}")
    want = BUNDLES[name][3]
    shown = info.get("CFBundleDisplayName")
    check(f"{name}-display-name", shown == want and "cappd" not in str(info).lower(), f"{shown!r}")
    ats = info.get("NSAppTransportSecurity") or {}
    weak = [k for k in ats if k != "NSAllowsLocalNetworking"]
    check(f"{name}-ats", not weak, f"keys {sorted(ats)}" + (f" — weakening: {weak}" if weak else ""))
check("bundle-ids", (infos["App"]["CFBundleIdentifier"], infos["Broadcast"]["CFBundleIdentifier"], infos["Share"]["CFBundleIdentifier"])
      == ("so.capturecat.ios", "so.capturecat.ios.broadcast", "so.capturecat.ios.share"),
      f"{[i['CFBundleIdentifier'] for i in infos.values()]}")
check("device-family", app.get("UIDeviceFamily") == [1, 2], f"{app.get('UIDeviceFamily')}")
check("launch-screen", isinstance(app.get("UILaunchScreen"), dict) or bool(app.get("UILaunchStoryboardName")),
      "UILaunchScreen" if "UILaunchScreen" in app else str(app.get("UILaunchStoryboardName")))
pad = set(app.get("UISupportedInterfaceOrientations~ipad") or [])
all4 = {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
check("ipad-multitasking", pad == all4 and not app.get("UIRequiresFullScreen"),
      f"iPad orientations {len(pad)}/4, UIRequiresFullScreen={app.get('UIRequiresFullScreen')}")
check("iphone-orientations", "UIInterfaceOrientationPortrait" in (app.get("UISupportedInterfaceOrientations~iphone") or []),
      f"{app.get('UISupportedInterfaceOrientations~iphone')}")
check("category", app.get("LSApplicationCategoryType") == "public.app-category.productivity", f"{app.get('LSApplicationCategoryType')}")

# Encryption: the key must be present, and NO is only honest while every
# cipher the binaries use is Apple's (URLSession / Network.framework TLS,
# CryptoKit hashing). A bundled TLS / crypto library changes the answer.
enc = app.get("ITSAppUsesNonExemptEncryption")
own_crypto = [b.path for bins in binaries.values() for b in bins
              if any(re.search(r"BoringSSL|OPENSSL_|_EVP_EncryptInit|_SSL_CTX_new|_mbedtls_|_wolfSSL_", s) for s in b.undefined)
              or b.has_str("OpenSSL 1.", "OpenSSL 3.", "BoringSSL")]
check("encryption-key", enc is False and not own_crypto,
      f"ITSAppUsesNonExemptEncryption={enc}" + (f"; non-OS crypto found in {own_crypto} — re-answer export compliance" if own_crypto else
                                                 "; only OS-provided TLS/HTTPS + hashing found"))

# Background work only as used. (BGContinuedProcessingTask for export lands
# separately: its identifier must then be in BGTaskSchedulerPermittedIdentifiers
# and referenced by the binary.)
modes = app.get("UIBackgroundModes") or []
MODE_EVIDENCE = {
    "processing": lambda b: b.has_sym("_OBJC_CLASS_$_BGProcessingTaskRequest", "_OBJC_CLASS_$_BGContinuedProcessingTaskRequest"),
    "fetch": lambda b: b.has_sym("_OBJC_CLASS_$_BGAppRefreshTaskRequest"),
    "remote-notification": lambda b: b.has_str("application:didReceiveRemoteNotification:fetchCompletionHandler:"),
    "audio": lambda b: b.has_sym("_OBJC_CLASS_$_AVAudioSession"),
}
bad_modes = [m for m in modes if m not in MODE_EVIDENCE or not any(MODE_EVIDENCE[m](b) for b in binaries["App"])]
check("background-modes", not bad_modes, f"{modes or 'none'}" + (f" — unused/unknown: {bad_modes}" if bad_modes else ""))
bg_ids = app.get("BGTaskSchedulerPermittedIdentifiers") or []
uses_scheduler = any(b.has_sym("_OBJC_CLASS_$_BGTaskScheduler") for b in binaries["App"])
unreferenced = [i for i in bg_ids if not any(any(s.startswith(i.rstrip("*").rstrip(".")) for s in b.strings) for b in binaries["App"])]
check("bgtask-identifiers", (bool(bg_ids) == uses_scheduler) and not unreferenced,
      f"identifiers {bg_ids or 'none'}, BGTaskScheduler {'used' if uses_scheduler else 'unused'}"
      + (f"; not referenced by the binary: {unreferenced}" if unreferenced else ""))

# ---------------------------------------------------------------- icons

icons = app.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
icons_pad = app.get("CFBundleIcons~ipad", {}).get("CFBundlePrimaryIcon", {})
check("icon-plist", icons.get("CFBundleIconName") == "AppIcon" and icons_pad.get("CFBundleIconName") == "AppIcon",
      f"CFBundleIconName {icons.get('CFBundleIconName')} / ~ipad {icons_pad.get('CFBundleIconName')}")
import json  # noqa: E402
info_json = json.loads(subprocess.run(["xcrun", "--sdk", "iphoneos", "assetutil", "--info", os.path.join(APP, "Assets.car")],
                                      capture_output=True, text=True).stdout or "[]")
renditions = {(r.get("Idiom"), r.get("Appearance") or "Any", r.get("PixelWidth"))
              for r in info_json[1:] if r.get("Name") == "AppIcon" and r.get("AssetType") == "Icon Image"}
stacks = {r.get("Appearance") for r in info_json[1:] if r.get("Name") == "AppIcon" and r.get("AssetType") == "IconImageStack"}
need = {(idiom, app_, 1024) for idiom in ("phone", "pad") for app_ in ("Any", "UIAppearanceDark", "ISAppearanceTintable")}
check("icon-appearances", need <= renditions, f"missing {sorted(need - renditions)}" if not need <= renditions
      else "Any + Dark + Tinted at 1024 for iPhone and iPad")
check("icon-glass-stack", {"UIAppearanceLight", "UIAppearanceDark", "ISAppearanceTintable"} <= stacks, f"{sorted(s for s in stacks if s)}")
loose = {"AppIcon60x60@2x.png": 120, "AppIcon76x76@2x~ipad.png": 152}
for f, px in loose.items():
    p = os.path.join(APP, f)
    w = run("sips", "-g", "pixelWidth", p).split()[-1] if os.path.exists(p) else "missing"
    ok = w == str(px)
    detail = f"{f} {w}" + ("px" if w != "missing" else "")
    if ok:
        try:
            from PIL import Image, ImageStat
            # The bundle's PNGs are Apple-optimised (CgBI): decode via sips.
            plain = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"releasecheck-{os.getpid()}-{f}")
            run("sips", "-s", "format", "png", p, "--out", plain)
            img = Image.open(plain).convert("RGB")
            os.remove(plain)
            spread = max(ImageStat.Stat(img).stddev)
            colours = len(img.getcolors(1 << 16) or range(1 << 16))
            ok = spread > 12 and colours > 64
            detail += f", stddev {spread:.0f}, {colours} colours" + ("" if ok else " — looks like placeholder art")
        except ImportError:
            detail += " (PIL absent: art not inspected)"
    check(f"icon-{f}", ok, detail)

# ---------------------------------------------------------------- hygiene

FORBIDDEN = [
    (r"^--(editor-shell|features|kit-gallery|inspector|history|ios-|fold-probe|whisper-probe|timeline|preview|export|cloud-sync|inject)", "harness launch flag"),
    (r"^-(uiFixtures|kitGallery|kitGallerySnapshot|uiSnapshotDebug|apiBaseURL)$", "DEBUG launch argument"),
    (r"probe[A-Z]|creaseOverride|FixtureWorld|FixtureDirector|KitGallery|StudioLab|StudioHarness|so\.capturecat\.ios\.studiolab", "probe seam / harness symbol"),
    (r"localhost|0\.0\.0\.0|\.local:|:(3000|3200|8787|8788|8791|8799)\b|workers\.dev|staging\.|\bngrok", "dev host / port"),
    (r"http://(?!127\.0\.0\.1(:|/|$))", "plain-HTTP URL (only the loopback sign-in listener may use http)"),
    (r"sk_(test|live)_|pk_(test|live)_|rk_(test|live)_|whsec_|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[bp]-", "secret / test key"),
    (r"Cappd", "old product name"),
]
for name, bins in binaries.items():
    hits = []
    for b in bins:
        for s in b.strings:
            for pattern, why in FORBIDDEN:
                if re.search(pattern, s):
                    hits.append(f"{why}: {s[:80]!r}")
    check(f"{name}-no-harness-strings", not hits, "; ".join(sorted(set(hits))[:12]) if hits else
          f"{sum(len(b.strings) for b in bins)} strings scanned")

# Entitlements: every key known and used.
ENTITLEMENT_EVIDENCE = {
    "com.apple.security.application-groups": lambda bs: any(
        b.has_str("containerURLForSecurityApplicationGroupIdentifier:", "initWithSuiteName:") for b in bs),
    "aps-environment": lambda bs: any(b.has_str("registerForRemoteNotifications") for b in bs),
    # Time-sensitive pushes are sent by the API (interruption-level
    # time-sensitive, apps/api/src/routes/devices.ts) to a push-registered app.
    "com.apple.developer.usernotifications.time-sensitive": lambda bs: any(b.has_str("registerForRemoteNotifications") for b in bs),
    "keychain-access-groups": lambda bs: any(b.has_sym("_SecItemCopyMatching", "_SecItemAdd") for b in bs),
    "com.apple.developer.background-tasks.continued-processing.gpu": lambda bs: any(
        b.has_sym("_OBJC_CLASS_$_BGContinuedProcessingTask", "_OBJC_CLASS_$_BGContinuedProcessingTaskRequest") for b in bs),
}
for name, (_, _, ent_src, _) in BUNDLES.items():
    ents = plist(os.path.join(os.environ.get("ENTITLEMENTS_DIR") or os.path.join(IOS, "Config"), os.path.basename(ent_src)))
    dead = [k for k in ents if k not in ENTITLEMENT_EVIDENCE or not ENTITLEMENT_EVIDENCE[k](binaries[name])]
    groups = ents.get("com.apple.security.application-groups", [])
    check(f"{name}-entitlements", not dead and groups in ([], ["group.so.capturecat.ios"]),
          f"{sorted(ents)}" + (f" — unused/unknown: {dead}" if dead else ""))

dsyms = sorted(os.listdir(os.path.join(ARCHIVE, "dSYMs"))) if os.path.isdir(os.path.join(ARCHIVE, "dSYMs")) else []
check("dsyms", {"CaptureCat.app.dSYM", "CaptureCatBroadcast.appex.dSYM", "CaptureCatShare.appex.dSYM"} <= set(dsyms), f"{dsyms}")

# ---------------------------------------------------------------- warnings

log = open(BUILD_LOG, errors="replace").read().splitlines()
# Real diagnostics only: `<file>:<line>:<col>: warning:` or a bare
# `warning:` line — not the indented source excerpts Swift prints under them.
warnings = sorted(set(l for l in log if re.match(r"^(/\S.*?: |\S+: )?warning: ", l)))
packaging = [w for w in warnings
             if not re.search(r"\.swift:\d+", w)
             and "Metadata extraction skipped, no AppIntents.framework dependency found" not in w]
swift = [w for w in warnings if re.search(r"\.swift:\d+", w)]
check("packaging-warnings", not packaging, "; ".join(w[-160:] for w in packaging[:6]) if packaging else
      f"0 (Swift source warnings, pre-existing and reported only: {len(swift)})")

failed = [n for n, ok in results if not ok]
print(f"RELEASECHECK SUMMARY {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}"
      + (f" failed: {', '.join(failed)}" if failed else ""))
sys.exit(1 if failed else 0)
