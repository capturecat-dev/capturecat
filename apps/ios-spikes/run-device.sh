#!/usr/bin/env bash
set -euo pipefail
# Builds CCSpikes (Release), installs it on a physical device and runs the
# Phase 0 spikes one configuration per launch (a fresh process each time, so
# the process-lifetime peak footprint is per configuration). Results land in
# results/<device-label>/ as JSON plus the raw console log.
#
#   apps/ios-spikes/run-device.sh <device-udid> <label> [spike-filter]
#
# e.g. run-device.sh <udid> iphone15promax   # udid: xcrun devicectl list devices
#      run-device.sh <udid> ipad "b c"          # only spikes b and c
#      (groups: a b c d e f g, plus "ar" = repeat runs of the a/timer and
#      a/displaylink drivers)
#
# Unlock the device before starting. The app disables the idle timer and
# does its thermal cool-down in the foreground, so the screen stays awake
# between launches (≈25 min in all).
# Spike g backgrounds CCSpikes by launching Settings a few seconds in.
cd "$(dirname "$0")"
udid="$1"; label="$2"; filter="${3:-a b c d e f g}"
out="results/$label"; mkdir -p "$out"
dd="${DERIVED_DATA:-${TMPDIR:-/tmp}/ccspikes-dd}"
bundle=so.capturecat.spikes

[[ -d Spikes/Media ]] || mac/make-media.sh
echo "== build (Release, device)"
xcodebuild -project CCSpikes.xcodeproj -scheme CCSpikes -configuration Release \
  -derivedDataPath "$dd" -destination "id=$udid" -allowProvisioningUpdates build >"$out/build.log" 2>&1 \
  || { tail -30 "$out/build.log"; exit 1; }
app="$dd/Build/Products/Release-iphoneos/CCSpikes.app"
echo "== install"
xcrun devicectl device install app --device "$udid" "$app" >/dev/null

# Blocks until the device reports no passcode required (i.e. unlocked).
wait_unlocked() {
  local said=""
  until xcrun devicectl device info lockState --device "$udid" 2>/dev/null | grep -q 'passcodeRequired: false'; do
    if [[ -z "$said" ]]; then echo "   waiting for the device to be unlocked…"; said=1; fi
    sleep 5
  done
}

launch() { # [TAG=x] launch <spike> <variant> [extra args…]
  local spike="$1" variant="$2"; shift 2
  local name="$spike-$variant${TAG:+-$TAG}"
  echo "== $name $*"
  local attempt
  for attempt in 1 2 3; do
    wait_unlocked
    xcrun devicectl device process launch --device "$udid" --console --terminate-existing \
      "$bundle" --spike "$spike" --variant "$variant" --cooldown "${COOLDOWN:-20}" "$@" --exit >"$out/$name.log" 2>&1 || true
    grep -q 'BSErrorCodeDescription = Locked' "$out/$name.log" || break
    echo "   launch refused: device locked (attempt $attempt)"
  done
  grep -o 'SPIKE-RESULT .*' "$out/$name.log" | sed 's/^SPIKE-RESULT //' >"$out/$name.json" || true
  [[ -s "$out/$name.json" ]] || echo "   (no result — see $out/$name.log)"
  sleep 1   # the cool-down runs inside the app (--cooldown), idle timer off
}
wants() { [[ " $filter " == *" $1 "* ]]; }

if wants e; then launch e default; fi
if wants d; then launch d behaviour; launch d cost; fi
if wants a; then
  for v in timer displaylink sbdl metal; do launch a "$v" --seconds 10; done
  TAG=5k launch a timer --seconds 10 --file screen-5120x2880-60.mov
fi
if wants b; then
  for f in 3456x2234 5120x2880; do
    for v in reader-nv12 reader-bgra player; do TAG="$f" launch b "$v" --file "screen-$f-60.mov"; done
  done
fi
if wants c; then for d in 2 3 5 8; do COOLDOWN=60 launch c "depth$d" --frames 300; done; fi
if wants f; then TAG=first launch f default; TAG=second launch f default; fi  # download + specialization, then cached
# Repeat the video-surface drivers: one cold run can stall on decoder warm-up.
if wants ar; then
  for r in r2 r3; do for v in timer displaylink; do TAG=$r launch a "$v" --seconds 10; done; done
fi
if wants g; then
  launch g probe
  echo "== g/export (backgrounding after 8 s)"
  ( sleep 8; xcrun devicectl device process launch --device "$udid" com.apple.Preferences >/dev/null 2>&1 || true ) &
  COOLDOWN=5 launch g export --frames 900
  wait
fi
echo "== results in $out"
