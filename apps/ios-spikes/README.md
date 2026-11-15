# iOS studio — Phase 0 spikes (throwaway)

Feasibility spikes for the iOS/iPadOS studio plan (`docs/ios-studio-plan.md`).
Results and decisions: `docs/ios-studio-phase0.md`. **Nothing here ships**, and
nothing here is shared with the companion app in `apps/ios/`.

UIKit only (no SwiftUI), like the rest of CaptureCat.

## Layout

| Path | What |
|---|---|
| `gen-xcodeproj.py` | Generates `CCSpikes.xcodeproj` (one app target over the synchronized `Spikes/` folder, iOS 26.0, WhisperKit 0.15.0 exact — the version the Mac resolves). |
| `Spikes/` | The app. `Harness.swift` runs one spike per launch from launch arguments and writes `Documents/results/<spike>-<variant>.json` plus a `SPIKE-RESULT {json}` console line. |
| `Spikes/Media/` | Synthetic media from `mac/make-media.sh` (gitignored). Never user media. |
| `run-device.sh` | Build, install and run every spike on a physical device: `./run-device.sh <udid> <label>`. |
| `mac/make-hevc.swift`, `mac/make-media.sh` | Synthetic screen-like HEVC (3456×2234 and 5120×2880 at 60 fps) and 60 s of `say` speech. |
| `mac/font-report-mac.sh` | Spike (e), Mac side: compiles the REAL `Studio/Services/FontCatalog.swift` and records what the Mac resolves. |
| `mac/merge-font-report.py` | Spike (e): diff the Mac and iOS resolutions. |
| `mac/scratch/scratch.patch`, `mac/run-scratch-spikes.sh` | Spikes (d) and (h) on the REAL Mac compositor / editor shell: applied to a `git archive` scratch copy of `apps/macos`, never to the product tree. |
| `results/` | Measured outputs, one folder per device. |

## The spikes

| | Question | Code |
|---|---|---|
| a | `CALayer.contents = IOSurface` from `AVPlayerItemVideoOutput` at 60 fps (the Mac's exact path) vs `AVSampleBufferDisplayLayer` vs `CAMetalLayer` | `SpikeA_VideoSurface.swift` |
| b | HEVC decode at 3456×2234 and 5120×2880, `AVAssetReader` (NV12/BGRA) and `AVPlayer` 1× | `SpikeB_Decode.swift` |
| c | 4K CoreImage → HEVC throughput and peak memory at pipeline depths 2/3/5/8 (graph shaped like `VideoExporter`'s) | `SpikeC_ExportCost.swift` |
| d | What iOS CA does with `CALayer.filters` / `compositingFilter`; cost of the CI replacements. Visual deltas vs the Mac: `mac/scratch` | `SpikeD_Filters.swift` |
| e | Every `FontCatalog.curated` family × `SubtitleWeight` on iOS | `SpikeE_Fonts.swift` |
| f | WhisperKit `base.en` time and memory | `SpikeF_Whisper.swift` |
| g | `BGContinuedProcessingTask` with `.gpu` (iOS 26) | `SpikeG_BackgroundExport.swift` |
| h | The virtual canvas the Mac's 1100×700 editor letterboxes | `mac/scratch` (`--editor-shell-shot`) |

## Running

```bash
python3 apps/ios-spikes/gen-xcodeproj.py
apps/ios-spikes/mac/make-media.sh
apps/ios-spikes/run-device.sh <udid> <label>
```

In the Simulator (functionality only; its numbers are the Mac's):

```bash
xcrun simctl launch --console-pty <sim-udid> so.capturecat.spikes --spike e --variant default --exit
```
