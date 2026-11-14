#!/usr/bin/env python3
"""Generate apps/ios-spikes/CCSpikes.xcodeproj — the Phase 0 throwaway spike app.

    python3 apps/ios-spikes/gen-xcodeproj.py

One UIKit app target (`CCSpikes`, bundle so.capturecat.spikes, iOS 26.0) over
one synchronized folder (`Spikes/`, so new files need no project edit), plus
WhisperKit pinned to the exact version the Mac app resolves (0.15.0) for
spike (f). Nothing here ships; nothing here is shared with apps/ios.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "CCSpikes.xcodeproj")
TEAM = "E52HU87CX9"
IOS = "26.0"
BUNDLE = "so.capturecat.spikes"
WHISPERKIT_VERSION = "0.15.0"


def oid(name):
    return hashlib.md5(("ccspikes." + name).encode()).hexdigest()[:24].upper()


P = {k: oid(k) for k in [
    "project", "main", "products", "sync", "config", "infoplist", "entitlements",
    "target", "product", "sources", "frameworks", "resources",
    "cfg.proj.debug", "cfg.proj.release", "cfg.tgt.debug", "cfg.tgt.release",
    "cfglist.proj", "cfglist.tgt", "pkg.whisper", "pkgprod.whisper", "bf.whisper",
]}

COMMON_PROJECT = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "DEVELOPMENT_TEAM": TEAM,
    "IPHONEOS_DEPLOYMENT_TARGET": IOS,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
}
DEBUG_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ONLY_ACTIVE_ARCH": "YES",
    # Spikes measure throughput: optimise even the Debug configuration so a
    # forgotten -configuration flag can't produce misleading numbers.
    "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
    "GCC_OPTIMIZATION_LEVEL": "s",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
}
RELEASE_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
    "SWIFT_COMPILATION_MODE": "wholemodule",
}
TARGET = {
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_ENTITLEMENTS": "Config/CCSpikes.entitlements",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": TEAM,
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "CCSpikes",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIFileSharingEnabled": "YES",
    "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}


def block(d, indent):
    pad = "\t" * indent
    out = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            out.append(f"{pad}{k} = (")
            out.extend(f"{pad}\t{i}," for i in v)
            out.append(f"{pad});")
        else:
            out.append(f"{pad}{k} = {v};")
    return "\n".join(out)


def config(key, name, settings):
    return f"""\t\t{P[key]} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{block(settings, 4)}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""


pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
\t\t{P["bf.whisper"]} /* WhisperKit in Frameworks */ = {{isa = PBXBuildFile; productRef = {P["pkgprod.whisper"]} /* WhisperKit */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{P["product"]} /* CCSpikes.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CCSpikes.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{P["infoplist"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{P["entitlements"]} /* CCSpikes.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = CCSpikes.entitlements; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{P["sync"]} /* Spikes */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Spikes;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{P["frameworks"]} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{P["bf.whisper"]} /* WhisperKit in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{P["main"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["sync"]} /* Spikes */,
\t\t\t\t{P["config"]} /* Config */,
\t\t\t\t{P["products"]} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{P["config"]} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["infoplist"]} /* Info.plist */,
\t\t\t\t{P["entitlements"]} /* CCSpikes.entitlements */,
\t\t\t);
\t\t\tpath = Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{P["products"]} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["product"]} /* CCSpikes.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{P["target"]} /* CCSpikes */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {P["cfglist.tgt"]};
\t\t\tbuildPhases = (
\t\t\t\t{P["sources"]} /* Sources */,
\t\t\t\t{P["frameworks"]} /* Frameworks */,
\t\t\t\t{P["resources"]} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{P["sync"]} /* Spikes */,
\t\t\t);
\t\t\tname = CCSpikes;
\t\t\tpackageProductDependencies = (
\t\t\t\t{P["pkgprod.whisper"]} /* WhisperKit */,
\t\t\t);
\t\t\tproductName = CCSpikes;
\t\t\tproductReference = {P["product"]} /* CCSpikes.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{P["project"]} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2600;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t}};
\t\t\tbuildConfigurationList = {P["cfglist.proj"]};
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {P["main"]};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = (
\t\t\t\t{P["pkg.whisper"]} /* XCRemoteSwiftPackageReference "WhisperKit" */,
\t\t\t);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {P["products"]} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{P["target"]} /* CCSpikes */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{P["resources"]} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{P["sources"]} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{config("cfg.proj.debug", "Debug", {**COMMON_PROJECT, **DEBUG_PROJECT})}
{config("cfg.proj.release", "Release", {**COMMON_PROJECT, **RELEASE_PROJECT})}
{config("cfg.tgt.debug", "Debug", TARGET)}
{config("cfg.tgt.release", "Release", TARGET)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{P["cfglist.proj"]} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{P["cfg.proj.debug"]} /* Debug */,
\t\t\t\t{P["cfg.proj.release"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{P["cfglist.tgt"]} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{P["cfg.tgt.debug"]} /* Debug */,
\t\t\t\t{P["cfg.tgt.release"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

/* Begin XCRemoteSwiftPackageReference section */
\t\t{P["pkg.whisper"]} /* XCRemoteSwiftPackageReference "WhisperKit" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/argmaxinc/WhisperKit.git";
\t\t\trequirement = {{
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = {WHISPERKIT_VERSION};
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{P["pkgprod.whisper"]} /* WhisperKit */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {P["pkg.whisper"]} /* XCRemoteSwiftPackageReference "WhisperKit" */;
\t\t\tproductName = WhisperKit;
\t\t}};
/* End XCSwiftPackageProductDependency section */
\t}};
\trootObject = {P["project"]} /* Project object */;
}}
"""

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "project.pbxproj"), "w") as f:
    f.write(pbx)

scheme_dir = os.path.join(OUT, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
with open(os.path.join(scheme_dir, "CCSpikes.xcscheme"), "w") as f:
    f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{P["target"]}" BuildableName = "CCSpikes.app" BlueprintName = "CCSpikes" ReferencedContainer = "container:CCSpikes.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Release" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{P["target"]}" BuildableName = "CCSpikes.app" BlueprintName = "CCSpikes" ReferencedContainer = "container:CCSpikes.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""")
print(f"wrote {OUT}")
