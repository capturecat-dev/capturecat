#!/usr/bin/env python3
"""Generate apps/ios/CaptureCat.xcodeproj (objectVersion 77, synchronized folders).

Why a generator: the project has three targets that share folders, plus a few
Swift files compiled straight out of the Mac tree (one source of truth for
PKCE, the loopback sign-in listener, the icon kit data, the still-movie writer
and the iPhone-over-Wi-Fi wire protocol). Hand-editing that pbxproj is how
targets silently drift; re-running this is not.

    python3 apps/ios/scripts/gen-xcodeproj.py

Folders (synchronized — new .swift files compile with no project edit):
  App/            CaptureCat (app)
  Kit/            app + share extension + StudioLab   UIKit design kit (extension-safe)
  Core/           app + both extensions      API, sync, uploads (extension-safe)
  Broadcast/      CaptureCatBroadcast        ReplayKit broadcast upload extension
  ShareExtension/ CaptureCatShare            "Save to CaptureCat" share extension
  ../macos/CaptureCat/Shared/   all three        files that MUST build on iOS
  ../macos/CaptureCat/Studio/   CaptureCat (app) the studio core, shared with the Mac app

Resources (explicit file references, copied into the app and StudioLab):
  StudioResources/Cursors/   the Mac's NSCursor.pointingHand bitmap reps as the Mac
                             rasterizes them (premultiplied RGBA8) — iOS has no
                             system cursors (Studio/Platform/CursorArt.swift)

Swift packages: WhisperKit (transcription, Studio 4e) for the app and
StudioLab, pinned to the exact version the Mac app resolves; the transitive
pins are copied from the Mac's Package.resolved so both apps build the same
engine.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "CaptureCat.xcodeproj")

TEAM = "E52HU87CX9"
IOS = "18.0"
APP_GROUP = "group.so.capturecat.ios"

# Version + build (docs/ios-app-store.md, "Versions"). One pair for the app AND
# its extensions — App Store Connect rejects an extension whose
# CFBundleShortVersionString / CFBundleVersion differ from the app's.
#   MARKETING_VERSION: what the store shows (1.0, 1.1, 2.0 …), bumped per release.
#   BUILD: a plain integer, +1 for EVERY upload (TestFlight included); never reused.
# A release build may override both on the command line
# (`MARKETING_VERSION=1.1 CURRENT_PROJECT_VERSION=7`) without regenerating.
MARKETING_VERSION = "1.0"
BUILD = "1"

# Universal links (the in-app share viewer, App/ShareViewer): the app claims
# capturecat.so's SHARE paths only — apps/web/public/.well-known/
# apple-app-site-association lists `E52HU87CX9.so.capturecat.ios` with
# `/share/*` (minus the `.md` twins). Written into Config/App.entitlements on
# every run. OWNER: the App ID needs the Associated Domains capability in the
# Apple Developer portal before a signed device build will provision, and the
# AASA must be live on both hosts before a tapped link opens the app.
ASSOCIATED_DOMAINS = ["applinks:capturecat.so", "applinks:www.capturecat.so"]

# Privacy manifests (PrivacyInfo.xcprivacy), one per shipping bundle, copied
# into the bundle root by that target's Resources phase. Checked against the
# Release binaries by scripts/ios-release-check.sh.
PRIVACY = {
    "App": "Config/Privacy/App/PrivacyInfo.xcprivacy",
    "Broadcast": "Config/Privacy/Broadcast/PrivacyInfo.xcprivacy",
    "Share": "Config/Privacy/Share/PrivacyInfo.xcprivacy",
}


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


# Synchronized folders: key -> (path, display name)
SYNC = {
    "App": ("App", None),
    "Kit": ("Kit", None),
    "Core": ("Core", None),
    "Broadcast": ("Broadcast", None),
    "ShareExtension": ("ShareExtension", None),
    "MacShared": ("../macos/CaptureCat/Shared", "MacShared"),
    # The studio core, shared with the Mac app (docs/ios-studio-plan.md).
    # App target only — the extensions take just the files they need below.
    "Studio": ("../macos/CaptureCat/Studio", "Studio"),
    # The studio's UIKit surfaces (preview stage, …) — the app and StudioLab
    # share them, so the harness exercises the very views the app ships.
    "StudioUI": ("StudioUI", None),
    # Non-shipping harness app: --ios-preview-parity and friends.
    "StudioLab": ("StudioLab", None),
    # Harness code shared with the Mac (fixture formats, scoring) — StudioLab only.
    "StudioHarness": ("../macos/CaptureCat/StudioHarness", "StudioHarness"),
}

# Individual files compiled from the Mac tree: key -> path (relative to apps/ios)
MAC_FILES = {
    "OAuthPKCE": "../macos/CaptureCat/Services/OAuthPKCE.swift",
    "LoopbackAuthServer": "../macos/CaptureCat/Services/LoopbackAuthServer.swift",
    "StillMovieWriter": "../macos/CaptureCat/Studio/Services/StillMovieWriter.swift",
    "CCIconSet": "../macos/CaptureCat/Views/Shared/DesignKit/CCIconSet.swift",
}

# Resource files: key -> path (relative to apps/ios). Explicit references,
# not a synchronized folder: raw bytes that must be copied untouched.
RESOURCE_FILES = {
    # macOS's NSCursor.pointingHand (32 × 32 pt, hotspot 13, 8): its 32 px and
    # 64 px bitmap reps exactly as the Mac's CursorStyleProvider rasterizes
    # them at 1× / 2× — premultiplied RGBA8, rows top-down, the bytes
    # `CaptureCat --web-cursor-sprites` writes (the web ships the same:
    # apps/web/public/editor/cursors/manifest.json). Read by CursorArt on iOS.
    "CursorHand1x": "StudioResources/Cursors/hand@1x.rgba",
    "CursorHand2x": "StudioResources/Cursors/hand@2x.rgba",
}

# Swift packages: key -> (repository, exact version, product). The Mac app
# resolves WhisperKit 0.15.0 (apps/macos/…/Package.resolved); iOS pins the
# same so a recording transcribes identically on both (Studio 4e).
PACKAGES = {
    "WhisperKit": ("https://github.com/argmaxinc/WhisperKit.git", "0.15.0", "WhisperKit"),
}
MAC_RESOLVED = os.path.join(ROOT, "..", "macos", "CaptureCat.xcodeproj", "project.xcworkspace",
                            "xcshareddata", "swiftpm", "Package.resolved")

CONFIG_FILES = [
    "Config/App-Info.plist",
    "Config/App.entitlements",
    "Config/Broadcast-Info.plist",
    "Config/Broadcast.entitlements",
    "Config/Share-Info.plist",
    "Config/Share.entitlements",
    "Config/Lab-Info.plist",
]

TARGETS = [
    {
        "key": "App",
        "name": "CaptureCat",
        "product": "CaptureCat.app",
        "type": "com.apple.product-type.application",
        "filetype": "wrapper.application",
        "bundle": "so.capturecat.ios",
        "sync": ["App", "Kit", "Core", "MacShared", "Studio", "StudioUI"],
        # StillMovieWriter comes with Studio/ for the app; the extensions still
        # reference it on its own.
        "mac": ["OAuthPKCE", "LoopbackAuthServer", "CCIconSet"],
        "resources": ["CursorHand1x", "CursorHand2x"],
        "packages": ["WhisperKit"],
        "plist": "Config/App-Info.plist",
        "entitlements": "Config/App.entitlements",
        "extra": {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": "CaptureCat",
            "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.productivity"',
            "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
            "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
        },
    },
    {
        "key": "Broadcast",
        "name": "CaptureCatBroadcast",
        "product": "CaptureCatBroadcast.appex",
        "type": "com.apple.product-type.app-extension",
        "filetype": '"wrapper.app-extension"',
        "bundle": "so.capturecat.ios.broadcast",
        "sync": ["Broadcast", "Core", "MacShared"],
        "mac": ["StillMovieWriter"],
        "plist": "Config/Broadcast-Info.plist",
        "entitlements": "Config/Broadcast.entitlements",
        "extra": {
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": "CaptureCat",
            "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"', '"@executable_path/../../Frameworks"'],
        },
    },
    {
        "key": "Share",
        "name": "CaptureCatShare",
        "product": "CaptureCatShare.appex",
        "type": "com.apple.product-type.app-extension",
        "filetype": '"wrapper.app-extension"',
        "bundle": "so.capturecat.ios.share",
        "sync": ["ShareExtension", "Kit", "Core", "MacShared"],
        "mac": ["StillMovieWriter", "CCIconSet"],
        "plist": "Config/Share-Info.plist",
        "entitlements": "Config/Share.entitlements",
        "extra": {
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": '"Save to CaptureCat"',
            "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"', '"@executable_path/../../Frameworks"'],
        },
    },
]

# StudioLab: the studio harness app. A separate, non-shipping application —
# never embedded in the app, never archived — that hosts the shipping
# StudioUI views in a real UIWindow for the parity gates.
TARGETS.append({
    "key": "Lab",
    "name": "StudioLab",
    "product": "StudioLab.app",
    "type": "com.apple.product-type.application",
    "filetype": "wrapper.application",
    "bundle": "so.capturecat.ios.studiolab",
    # Kit/ too: --kit-gallery renders the house controls in this real window,
    # and the StudioUI views (the timeline's menus, motion, icons) use the kit.
    "sync": ["StudioLab", "StudioUI", "Studio", "StudioHarness", "Kit"],
    "mac": ["CCIconSet"],
    "resources": ["CursorHand1x", "CursorHand2x"],
    "packages": ["WhisperKit"],
    "plist": "Config/Lab-Info.plist",
    "entitlements": None,
    "extra": {
        "INFOPLIST_KEY_CFBundleDisplayName": "StudioLab",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
        "SKIP_INSTALL": "YES",
    },
})

COMMON_PROJECT = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "COPY_PHASE_STRIP": "NO",
    "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": IOS,
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "SWIFT_VERSION": "5.0",
}
DEBUG_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ['"DEBUG=1"', '"$(inherited)"'],
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}
RELEASE_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}
COMMON_TARGET = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_PREVIEWS": "NO",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}


def settings_block(d, indent):
    pad = "\t" * indent
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            lines.append(f"{pad}{k} = (")
            for item in v:
                lines.append(f"{pad}\t{item},")
            lines.append(f"{pad});")
        else:
            lines.append(f"{pad}{k} = {v};")
    return "\n".join(lines)


def main():
    o = []  # (section, text)

    def add(section, text):
        o.append((section, text))

    project = oid("project")
    main_group = oid("group.main")
    products_group = oid("group.products")
    macsrc_group = oid("group.macsources")
    config_group = oid("group.config")
    res_group = oid("group.resources")

    # File references
    for t in TARGETS:
        add("PBXFileReference", f'\t\t{oid("product." + t["key"])} /* {t["product"]} */ = {{isa = PBXFileReference; explicitFileType = {t["filetype"]}; includeInIndex = 0; path = {t["product"]}; sourceTree = BUILT_PRODUCTS_DIR; }};')
    for key, path in MAC_FILES.items():
        base = os.path.basename(path)
        add("PBXFileReference", f'\t\t{oid("macfile." + key)} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {base}; path = "{path}"; sourceTree = SOURCE_ROOT; }};')
    for key, path in RESOURCE_FILES.items():
        base = os.path.basename(path)
        add("PBXFileReference", f'\t\t{oid("resfile." + key)} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = file; name = "{base}"; path = "{path}"; sourceTree = SOURCE_ROOT; }};')
    for path in CONFIG_FILES:
        base = os.path.basename(path)
        ftype = "text.plist.xml" if base.endswith(".plist") else "text.plist.entitlements"
        add("PBXFileReference", f'\t\t{oid("config." + path)} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{base}"; sourceTree = "<group>"; }};')
    for key, path in PRIVACY.items():
        rel = os.path.relpath(path, "Config")
        add("PBXFileReference", f'\t\t{oid("privacy." + key)} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; name = "{key}-PrivacyInfo.xcprivacy"; path = "{rel}"; sourceTree = "<group>"; }};')
        add("PBXBuildFile", f'\t\t{oid("bf.privacy." + key)} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {oid("privacy." + key)} /* {rel} */; }};')

    # Synchronized root groups
    for key, (path, name) in SYNC.items():
        name_line = f"\n\t\t\tname = {name};" if name else ""
        add("PBXFileSystemSynchronizedRootGroup", f'\t\t{oid("sync." + key)} /* {name or path} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;{name_line}\n\t\t\tpath = "{path}";\n\t\t\tsourceTree = "<group>";\n\t\t}};')

    # Build files (Mac sources per target, embedded extensions)
    for t in TARGETS:
        for key in t["mac"]:
            base = os.path.basename(MAC_FILES[key])
            add("PBXBuildFile", f'\t\t{oid("bf." + t["key"] + "." + key)} /* {base} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid("macfile." + key)} /* {base} */; }};')
    for t in TARGETS:
        for key in t.get("resources", []):
            base = os.path.basename(RESOURCE_FILES[key])
            add("PBXBuildFile", f'\t\t{oid("bf.res." + t["key"] + "." + key)} /* {base} in Resources */ = {{isa = PBXBuildFile; fileRef = {oid("resfile." + key)} /* {base} */; }};')
    for t in TARGETS:
        for key in t.get("packages", []):
            add("PBXBuildFile", f'\t\t{oid("bf.pkg." + t["key"] + "." + key)} /* {key} in Frameworks */ = {{isa = PBXBuildFile; productRef = {oid("pkgprod." + t["key"] + "." + key)} /* {key} */; }};')
            add("XCSwiftPackageProductDependency", f'\t\t{oid("pkgprod." + t["key"] + "." + key)} /* {key} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {oid("pkg." + key)} /* XCRemoteSwiftPackageReference "{key}" */;\n\t\t\tproductName = {PACKAGES[key][2]};\n\t\t}};')
    for key, (repo, version, _) in PACKAGES.items():
        add("XCRemoteSwiftPackageReference", f'\t\t{oid("pkg." + key)} /* XCRemoteSwiftPackageReference "{key}" */ = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = "{repo}";\n\t\t\trequirement = {{\n\t\t\t\tkind = exactVersion;\n\t\t\t\tversion = {version};\n\t\t\t}};\n\t\t}};')
    extensions = [t for t in TARGETS if "app-extension" in t["type"]]
    for t in extensions:
        add("PBXBuildFile", f'\t\t{oid("embed." + t["key"])} /* {t["product"]} in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {oid("product." + t["key"])} /* {t["product"]} */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')

    # Container proxies + dependencies
    for t in extensions:
        add("PBXContainerItemProxy", f'\t\t{oid("proxy." + t["key"])} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {project} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {oid("target." + t["key"])};\n\t\t\tremoteInfo = {t["name"]};\n\t\t}};')
        add("PBXTargetDependency", f'\t\t{oid("dep." + t["key"])} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {oid("target." + t["key"])} /* {t["name"]} */;\n\t\t\ttargetProxy = {oid("proxy." + t["key"])} /* PBXContainerItemProxy */;\n\t\t}};')

    # Copy phase (embed extensions)
    files = "\n".join(f'\t\t\t\t{oid("embed." + t["key"])} /* {t["product"]} in Embed Foundation Extensions */,' for t in extensions)
    add("PBXCopyFilesBuildPhase", f'\t\t{oid("phase.embed")} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n{files}\n\t\t\t);\n\t\t\tname = "Embed Foundation Extensions";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

    # Phases per target
    for t in TARGETS:
        k = t["key"]
        src = "\n".join(f'\t\t\t\t{oid("bf." + k + "." + m)} /* {os.path.basename(MAC_FILES[m])} in Sources */,' for m in t["mac"])
        add("PBXSourcesBuildPhase", f'\t\t{oid("phase.sources." + k)} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{src}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};'.replace("(\n\n", "(\n"))
        fw = "".join(f'\t\t\t\t{oid("bf.pkg." + k + "." + key)} /* {key} in Frameworks */,\n' for key in t.get("packages", []))
        add("PBXFrameworksBuildPhase", f'\t\t{oid("phase.frameworks." + k)} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{fw}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
        res = "".join(f'\t\t\t\t{oid("bf.res." + k + "." + key)} /* {os.path.basename(RESOURCE_FILES[key])} in Resources */,\n' for key in t.get("resources", []))
        if k in PRIVACY:
            res += f'\t\t\t\t{oid("bf.privacy." + k)} /* PrivacyInfo.xcprivacy in Resources */,\n'
        add("PBXResourcesBuildPhase", f'\t\t{oid("phase.resources." + k)} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{res}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

    # Groups
    sync_children = "\n".join(f'\t\t\t\t{oid("sync." + key)} /* {name or path} */,' for key, (path, name) in SYNC.items())
    add("PBXGroup", f'\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{sync_children}\n\t\t\t\t{macsrc_group} /* MacSources */,\n\t\t\t\t{res_group} /* StudioResources */,\n\t\t\t\t{config_group} /* Config */,\n\t\t\t\t{products_group} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    prods = "\n".join(f'\t\t\t\t{oid("product." + t["key"])} /* {t["product"]} */,' for t in TARGETS)
    add("PBXGroup", f'\t\t{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{prods}\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    macs = "\n".join(f'\t\t\t\t{oid("macfile." + key)} /* {os.path.basename(p)} */,' for key, p in MAC_FILES.items())
    add("PBXGroup", f'\t\t{macsrc_group} /* MacSources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{macs}\n\t\t\t);\n\t\t\tname = MacSources;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    ress = "\n".join(f'\t\t\t\t{oid("resfile." + key)} /* {os.path.basename(p)} */,' for key, p in RESOURCE_FILES.items())
    add("PBXGroup", f'\t\t{res_group} /* StudioResources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{ress}\n\t\t\t);\n\t\t\tname = StudioResources;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    cfgs = "\n".join(f'\t\t\t\t{oid("config." + p)} /* {os.path.basename(p)} */,' for p in CONFIG_FILES)
    cfgs += "".join(f'\n\t\t\t\t{oid("privacy." + key)} /* {os.path.relpath(p, "Config")} */,' for key, p in PRIVACY.items())
    add("PBXGroup", f'\t\t{config_group} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{cfgs}\n\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = "<group>";\n\t\t}};')

    # Targets
    for t in TARGETS:
        k = t["key"]
        phases = [f'{oid("phase.sources." + k)} /* Sources */', f'{oid("phase.frameworks." + k)} /* Frameworks */', f'{oid("phase.resources." + k)} /* Resources */']
        deps = ""
        if k == "App":
            phases.append(f'{oid("phase.embed")} /* Embed Foundation Extensions */')
            deps = "\n".join(f'\t\t\t\t{oid("dep." + e["key"])} /* PBXTargetDependency */,' for e in extensions)
        phase_lines = "\n".join(f"\t\t\t\t{p}," for p in phases)
        syncs = "\n".join(f'\t\t\t\t{oid("sync." + s)} /* {SYNC[s][1] or SYNC[s][0]} */,' for s in t["sync"])
        pkgdeps = ""
        if t.get("packages"):
            items = "".join(f'\n\t\t\t\t{oid("pkgprod." + k + "." + key)} /* {key} */,' for key in t["packages"])
            pkgdeps = f"\n\t\t\tpackageProductDependencies = ({items}\n\t\t\t);"
        add("PBXNativeTarget", f'\t\t{oid("target." + k)} /* {t["name"]} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {oid("cfglist." + k)} /* Build configuration list for PBXNativeTarget "{t["name"]}" */;\n\t\t\tbuildPhases = (\n{phase_lines}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{deps}\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n{syncs}\n\t\t\t);\n\t\t\tname = {t["name"]};{pkgdeps}\n\t\t\tproductName = {t["name"]};\n\t\t\tproductReference = {oid("product." + k)} /* {t["product"]} */;\n\t\t\tproductType = "{t["type"]}";\n\t\t}};'.replace("(\n\n", "(\n"))

    # Project
    target_attrs = "\n".join(f'\t\t\t\t\t{oid("target." + t["key"])} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t}};' for t in TARGETS)
    target_list = "\n".join(f'\t\t\t\t{oid("target." + t["key"])} /* {t["name"]} */,' for t in TARGETS)
    pkgrefs = ""
    if PACKAGES:
        items = "".join(f'\n\t\t\t\t{oid("pkg." + key)} /* XCRemoteSwiftPackageReference "{key}" */,' for key in PACKAGES)
        pkgrefs = f"\n\t\t\tpackageReferences = ({items}\n\t\t\t);"
    add("PBXProject", f'\t\t{project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t\tTargetAttributes = {{\n{target_attrs}\n\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {oid("cfglist.project")} /* Build configuration list for PBXProject "CaptureCat" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n\t\t\tminimizedProjectReferenceProxies = 1;{pkgrefs}\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {products_group} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n{target_list}\n\t\t\t);\n\t\t}};')

    # Build configurations
    def config(id_, name, settings):
        add("XCBuildConfiguration", f'\t\t{id_} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(settings, 4)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};')

    config(oid("cfg.project.Debug"), "Debug", {**COMMON_PROJECT, **DEBUG_PROJECT})
    config(oid("cfg.project.Release"), "Release", {**COMMON_PROJECT, **RELEASE_PROJECT})
    for t in TARGETS:
        base = {
            **COMMON_TARGET,
            **t["extra"],
            "INFOPLIST_FILE": t["plist"],
            "PRODUCT_BUNDLE_IDENTIFIER": t["bundle"],
        }
        if t["entitlements"]:
            base["CODE_SIGN_ENTITLEMENTS"] = t["entitlements"]
        config(oid(f"cfg.{t['key']}.Debug"), "Debug", base)
        config(oid(f"cfg.{t['key']}.Release"), "Release", base)

    def cfglist(id_, label, key):
        add("XCConfigurationList", f'\t\t{id_} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{oid("cfg." + key + ".Debug")} /* Debug */,\n\t\t\t\t{oid("cfg." + key + ".Release")} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')

    cfglist(oid("cfglist.project"), 'PBXProject "CaptureCat"', "project")
    for t in TARGETS:
        cfglist(oid("cfglist." + t["key"]), f'PBXNativeTarget "{t["name"]}"', t["key"])

    order = [
        "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
        "PBXFileSystemSynchronizedRootGroup", "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget",
        "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency",
        "XCBuildConfiguration", "XCConfigurationList",
        "XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency",
    ]
    body = []
    for section in order:
        items = [text for s, text in o if s == section]
        if not items:
            continue
        body.append(f"/* Begin {section} section */")
        body.extend(items)
        body.append(f"/* End {section} section */\n")

    text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n" + "\n".join(body) + f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n"
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "project.pbxproj"), "w") as f:
        f.write(text)

    # Shared schemes: the app (builds the extensions through its dependencies)
    # and StudioLab (the harness app).
    def write_scheme(key, name, product):
        scheme_dir = os.path.join(OUT, "xcshareddata", "xcschemes")
        os.makedirs(scheme_dir, exist_ok=True)
        app = oid("target." + key)
        ref = f'''<BuildableReference
                   BuildableIdentifier = "primary"
                   BlueprintIdentifier = "{app}"
                   BuildableName = "{product}"
                   BlueprintName = "{name}"
                   ReferencedContainer = "container:CaptureCat.xcodeproj">
                </BuildableReference>'''
        scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
    <Scheme
       LastUpgradeVersion = "2700"
       version = "1.7">
       <BuildAction
          parallelizeBuildables = "YES"
          buildImplicitDependencies = "YES">
          <BuildActionEntries>
             <BuildActionEntry
                buildForTesting = "YES"
                buildForRunning = "YES"
                buildForProfiling = "YES"
                buildForArchiving = "YES"
                buildForAnalyzing = "YES">
                {ref}
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
       <TestAction
          buildConfiguration = "Debug"
          selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
          selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
          shouldUseLaunchSchemeArgsEnv = "YES">
       </TestAction>
       <LaunchAction
          buildConfiguration = "Debug"
          selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
          selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
          launchStyle = "0"
          useCustomWorkingDirectory = "NO"
          ignoresPersistentStateOnLaunch = "NO"
          debugDocumentVersioning = "YES"
          debugServiceExtension = "internal"
          allowLocationSimulation = "YES">
          <BuildableProductRunnable
             runnableDebuggingMode = "0">
             {ref}
          </BuildableProductRunnable>
       </LaunchAction>
       <ProfileAction
          buildConfiguration = "Release"
          shouldUseLaunchSchemeArgsEnv = "YES"
          savedToolIdentifier = ""
          useCustomWorkingDirectory = "NO"
          debugDocumentVersioning = "YES">
          <BuildableProductRunnable
             runnableDebuggingMode = "0">
             {ref}
          </BuildableProductRunnable>
       </ProfileAction>
       <AnalyzeAction
          buildConfiguration = "Debug">
       </AnalyzeAction>
       <ArchiveAction
          buildConfiguration = "Release"
          revealArchiveInOrganizer = "YES">
       </ArchiveAction>
    </Scheme>
    '''
        # (The XML above sits one level deeper in this function; drop that.)
        scheme = "\n".join(l[4:] if l.startswith("    ") else l for l in scheme.split("\n"))
        with open(os.path.join(scheme_dir, name + ".xcscheme"), "w") as f:
            f.write(scheme)

    # The Mac app's package pins (WhisperKit and everything it pulls in),
    # minus the Mac-only ones — so both apps build the same engine.
    import json
    with open(MAC_RESOLVED) as f:
        resolved = json.load(f)
    resolved["pins"] = [p for p in resolved["pins"] if p["identity"] != "sparkle"]
    resolved.pop("originHash", None)
    swiftpm = os.path.join(OUT, "project.xcworkspace", "xcshareddata", "swiftpm")
    os.makedirs(swiftpm, exist_ok=True)
    with open(os.path.join(swiftpm, "Package.resolved"), "w") as f:
        f.write(json.dumps(resolved, indent=2, separators=(",", " : ")) + "\n")

    write_scheme("App", "CaptureCat", "CaptureCat.app")
    write_scheme("Lab", "StudioLab", "StudioLab.app")
    write_associated_domains()
    print("wrote", OUT)


def write_associated_domains():
    """Keep the app's Associated Domains entitlement equal to ASSOCIATED_DOMAINS."""
    import plistlib
    path = os.path.join(ROOT, "Config", "App.entitlements")
    with open(path, "rb") as f:
        ents = plistlib.load(f)
    key = "com.apple.developer.associated-domains"
    if ents.get(key) == ASSOCIATED_DOMAINS:
        return
    ents[key] = list(ASSOCIATED_DOMAINS)
    with open(path, "wb") as f:
        plistlib.dump(ents, f, sort_keys=False)


if __name__ == "__main__":
    main()
