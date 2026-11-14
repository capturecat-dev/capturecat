#!/usr/bin/env bash
# Studio canary: typecheck the Mac studio core against the iOS SDK.
#
# The iOS studio renders through the Mac's own code (docs/ios-studio-plan.md),
# so every file the core is made of must compile for iOS. This typechecks the
# extracted set — no app, no simulator — with the Mac target's Swift settings
# (Swift 5 mode, default MainActor isolation, member import visibility).
#
# Phase 1 grows the set slice by slice; Phase 1g replaces this with the iOS
# App target compiling apps/macos/CaptureCat/Studio/ directly.
#
#   apps/ios/scripts/studio-canary.sh            # PASS / FAIL
set -euo pipefail

MAC="$(cd "$(dirname "$0")/../../macos/CaptureCat" && pwd)"
cd "$MAC"

# The rest of the core that lives elsewhere today; it moves into Studio/ with
# the rest of the core in Phase 1f.
DEPS=(
  # Pure dependencies of the models (1b-i).
  Services/OklabGradient.swift          # SRGBA (CodableColor.srgba)
  Services/FocusMath.swift              # FocusRegion
  Services/CurtainUnveilMath.swift      # CurtainUnveilCorner (ProjectSettings)
  Services/ContinuousRoundedRect.swift  # used by CurtainUnveilMath
  Services/IntroSlideMath.swift         # IntroSlideStyle (ProjectSettings)
  Services/StillMovieWriter.swift       # Project (still captures)
  Services/ClickSoundPlayer.swift       # ClickSoundStyle (ProjectSettings)
  Services/KeySoundPlayer.swift         # KeySoundStyle (ProjectSettings)

  # Renderers + exporter, through Studio/Platform (1b-ii).
  Services/AnnotationRenderer.swift     # every annotation type, drawn in CG
  Services/KeystrokeOverlay.swift       # shortcut pill math + renderer
  Services/CameraStyleMath.swift        # camera adjustments, shapes, ring, name tag
  Services/MenuBarRenderer.swift        # replacement menu bar (guard + cache)
  Services/CursorStyleProvider.swift    # cursor styles, hotspots, rasters
  Services/FontCatalog.swift            # typeface resolution (table, then live)
  Services/FontFaceTable.swift          # frozen family x weight -> face table
  Services/StillImageExporter.swift     # PNG export through the video exporter
  Services/VideoExporter.swift          # the exporter

  # Pure dependencies of the renderers + exporter (1b-ii).
  Views/Editor/ClickRippleOverlay.swift # TapRippleMath, discreteClickTimes (pure; already AppKit-free)
  Services/SwiftUIShadow.swift          # SwiftUI-equivalent CG shadows
  Services/CameraLayoutMath.swift       # camera layout regions / card geometry
  Services/DeviceFrameLayout.swift      # device frame geometry, continuous paths
  Services/DeviceFrameRenderer.swift    # device frame for the exporter
  Services/DeviceBezelRenderer.swift    # iPhone bezel, drawn in CG
  Services/DeviceSegmentDip.swift       # segment-cut dip timing
  Services/ZoomFocalMath.swift          # zoom focal clamping
  Services/TiltMath.swift               # tilt transform math
  Services/ReactiveCameraLayout.swift   # camera bubble layout
  Services/CameraCutoutMath.swift       # cutout/pop-out look math
  Services/CameraCardStyle.swift        # pop-out card style
  Services/CameraMaskTrack.swift        # .ccmask codec, Project.usesCameraLook
  Services/CameraMaskEdge.swift         # mask edge treatment
  Services/PlacementMath.swift          # video placement math
  Services/ProjectAudioMix.swift        # export audio mix
  Services/VideoColorTags.swift         # output colour tagging
  Services/ExportFormats.swift          # GIF sink/policy, StaticSpanCollapse
  Services/MotionBlurMath.swift         # motion blur sampling
  Services/CursorSmoother.swift         # cursor interpolation
  Services/CursorPhysicsMath.swift      # cursor physics
  Services/CursorSpringMath.swift       # cursor spring + end behaviour
  Services/BlurStyleMath.swift          # blur region styles
  Services/BackgroundLook.swift         # shared background bitmap
  Services/BackgroundGradientRenderer.swift # background gradients
  Services/SpeedTimeMap.swift           # speed regions source<->output time
  Services/HighlightRenderLogger.swift  # highlight render diagnostics
  Services/EasingFunctions.swift        # Easing curves

  # Compositor core, split from its NSView host (1c).
  Views/Editor/PreviewCompositor/PreviewCompositorCore.swift  # layers, caches, render, springs, video driver
  Views/Editor/PreviewCompositor/PreviewCompositorDebug.swift # probe readbacks (cursor hotspot in canvas space)

  # Pure dependencies of the compositor core (1c).
  Services/PreviewMotionModel.swift     # zoom/focal/tilt springs the preview steps
  Services/SelectionChromeKit.swift     # selection outline + value pill (StudioChromeTheme, SymbolImage)
  Views/Editor/RegionHandleChrome.swift # pill geometry shared with the hit zones (pure)

  # Hit math + gesture state machine, split from the Mac interaction view (1d).
  Views/Editor/PreviewCompositor/PreviewHitMath.swift     # targets, drag mapping, clamps (pure)
  Views/Editor/PreviewCompositor/PreviewGestureCore.swift # press → drag → release cascade
)

# Mac-only files inside otherwise-shared folders.
EXCLUDE='^(Models/CaptureSource|Models/SubtitlePreset|Extensions/CodableColor\+AppKit)\.swift$'

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  { ls Studio/Platform/*.swift Models/*.swift Extensions/*.swift
    printf '%s\n' "${DEPS[@]}"
  } | grep -v '^$' | grep -vE "$EXCLUDE" | sort -u)

out="$(xcrun -sdk iphonesimulator swiftc -typecheck \
  -target arm64-apple-ios26.0-simulator \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  "${files[@]}" 2>&1)" || true

errors="$(printf '%s\n' "$out" | grep -c ' error: ' || true)"
echo "studio canary: ${#files[@]} files typechecked for iOS"
if [[ "$errors" != "0" ]]; then
  printf '%s\n' "$out" | grep ' error: ' | sed -E "s#^$MAC/##" | head -60
  echo "STUDIO CANARY: FAIL ($errors errors)"
  exit 1
fi
echo "STUDIO CANARY: PASS"
