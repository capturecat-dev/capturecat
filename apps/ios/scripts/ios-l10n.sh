#!/usr/bin/env bash
# ios-l10n: the iOS app in every App Store language — nothing left in English,
# nothing cut off — in the REAL window chains, on an iPhone and an iPad.
#
#   apps/ios/scripts/ios-l10n.sh
#
# 1. The String Catalog (scripts/l10n-catalog.py check): every key translated
#    into de fr es es-MX it pt-BR nl ja ko zh-Hans, placeholders intact; and the
#    static lint (scripts/ios-l10n-lint.py): no raw English literal reaches a
#    UIKit text sink, proved by its self-test (injected literals caught); and
#    no two different English labels on one surface read the same in a
#    language (Split/Share → "Teilen"), proved by an injected collision.
# 2. Per device and per locale (`-AppleLanguages (xx) -AppleLocale xx_YY`):
#    a. the app (`-uiFixtures -uiL10nAudit`, App/Fixtures/FixtureL10nAudit.swift):
#       library and its filters, a card's action sheet, a project, a share
#       (comments on / off), capture, account, the Language page, the delete-
#       account sheet, a toast, sign-in — and again in the EMPTY world
#       (`-uiFixtureEmpty`: the empty library, filters, capture and account);
#    b. StudioLab (`--l10n`, StudioLab/L10nLab.swift): the shipping editor and
#       every studio screen the a11y gate opens (nine inspector panes top and
#       scrolled to the end, lanes, selection, timeline menu, History, Merge
#       Review, feature sheets, tool bar sheets and panels, Export) plus each
#       object selected with its inspector open (every annotation type,
#       highlight, tilt, depth focus, blur, intro, curtain).
#    Each screen through Kit/CCLocalizationAudit.swift: every visible and
#    spoken text, truncation / clipping / overlap measured, a PNG.
# 3. scripts/ios-l10n-judge.py: a text identical to the English run is
#    untranslated (unless the catalog says it's the same word in that
#    language, or it's fixture content in ios-l10n-allow.txt); any text
#    problem in any language fails.
# 4. Gate power (unless INJECT=none): the same run on German with an injected
#    hard-coded English label, and with header titles pinned to 36 pt —
#    both must be CAUGHT.
#
# Env: DEVICES="<udid> <udid>"  (default: the "CaptureCat L10n" iPhone 17 + iPad Pro 13)
#      LOCALES="de ja …"        (default: all 12 + the en baseline)
#      OUT=<dir>                (default: $TMPDIR/capturecat-ios-l10n)
#      PARTS="app lab"          SKIP_BUILD=1   INJECT=none
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="${DEVICES:-F7A82ACA-54D9-4C21-8229-9AE68424428C 61C62FD3-CAFD-4727-8018-EEFCE994FEF9}"
LOCALES="${LOCALES:-en en-GB en-US de fr es es-MX it pt-BR nl ja ko zh-Hans}"
PARTS="${PARTS:-app lab}"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-ios-l10n}"
INJECT="${INJECT:-untranslated truncate}"
LAB=so.capturecat.ios.studiolab
APPID=so.capturecat.ios
mkdir -p "$OUT"

status=0
echo "ios-l10n: catalog"
python3 "$IOS/scripts/l10n-catalog.py" check | tail -3 || status=1
python3 "$IOS/scripts/l10n-catalog.py" collision-selftest || status=1
echo "ios-l10n: static lint (no raw literal reaches a UI sink)"
python3 "$IOS/scripts/ios-l10n-lint.py" | tail -12 || status=1
python3 "$IOS/scripts/ios-l10n-lint.py" --selftest | tail -1 || status=1

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "ios-l10n: building the app + StudioLab (Debug)"
  for scheme in CaptureCat StudioLab; do
    xcodebuild -project "$IOS/CaptureCat.xcodeproj" -scheme "$scheme" -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/dd" build > "$OUT/build-$scheme.log" 2>&1 \
      || { grep -E '^/.*error:' "$OUT/build-$scheme.log" | head -20; echo "IOS-L10N FAIL ($scheme build)"; exit 1; }
  done
fi
APPAPP="$OUT/dd/Build/Products/Debug-iphonesimulator/CaptureCat.app"
LABAPP="$OUT/dd/Build/Products/Debug-iphonesimulator/StudioLab.app"

region() {  # region <locale> — a plausible AppleLocale for it
  case "$1" in
    en) echo en_US ;; en-GB) echo en_GB ;; en-US) echo en_US ;; de) echo de_DE ;; fr) echo fr_FR ;;
    es) echo es_ES ;; es-MX) echo es_MX ;; it) echo it_IT ;; pt-BR) echo pt_BR ;; nl) echo nl_NL ;;
    ja) echo ja_JP ;; ko) echo ko_KR ;; zh-Hans) echo zh_CN ;; *) echo "$1" ;;
  esac
}

capture() {  # capture <device> <locale> <dest> [extra app args…] — one locale on one device
  local device="$1" loc="$2" dest="$3"; shift 3
  local lang=(-AppleLanguages "($loc)" -AppleLocale "$(region "$loc")")
  rm -rf "$dest" && mkdir -p "$dest"
  if [[ " $PARTS " == *" app "* ]]; then
    xcrun simctl launch --console-pty --terminate-running-process "$device" "$APPID" \
      -uiFixtures -uiL10nAudit "${lang[@]}" "$@" > "$dest/app.log" 2>&1 || true
    local data; data="$(xcrun simctl get_app_container "$device" "$APPID" data)"
    if [[ -d "$data/Documents/l10n" ]]; then cp -R "$data/Documents/l10n" "$dest/app"; fi
    grep -aE '^L10NAUDIT-DONE' "$dest/app.log" | tr -d '\r' | sed "s/^/    $loc app: /" || echo "    $loc app: (no result)"
    if [[ $# -eq 0 ]]; then  # the empty states: empty library and filters, capture, account
      xcrun simctl launch --console-pty --terminate-running-process "$device" "$APPID" \
        -uiFixtures -uiFixtureEmpty -uiL10nAudit -uiL10nOnly library,library-recordings,library-screenshots,library-shares,capture,account \
        "${lang[@]}" > "$dest/app-empty.log" 2>&1 || true
      if [[ -d "$data/Documents/l10n-empty" ]]; then mkdir -p "$dest/app"; cp "$data/Documents/l10n-empty/"* "$dest/app/"; fi
      grep -aE '^L10NAUDIT-DONE' "$dest/app-empty.log" | tr -d '\r' | sed "s/^/    $loc app (empty): /" || echo "    $loc app (empty): (no result)"
    fi
  fi
  if [[ " $PARTS " == *" lab "* && $# -eq 0 ]]; then
    xcrun simctl launch --console-pty --terminate-running-process "$device" "$LAB" \
      --l10n "$dest/labrun" "${lang[@]}" > "$dest/lab.log" 2>&1 || true
    if [[ -d "$dest/labrun/screens" ]]; then mv "$dest/labrun/screens" "$dest/lab"; fi
    rm -rf "$dest/labrun"
    grep -aE '^L10NLAB-DONE' "$dest/lab.log" | tr -d '\r' | sed "s/^/    $loc lab: /" || echo "    $loc lab: (no result)"
  fi
}

run_device() {  # run_device <udid>
  local device="$1"
  local name; name="$(xcrun simctl list devices | grep "$device" | sed -E 's/^ *(.*) \(.*/\1/' | head -1)"
  local tag; tag="$(echo "$name" | grep -qi ipad && echo ipad || echo iphone)"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" > /dev/null
  xcrun simctl install "$device" "$APPAPP"
  xcrun simctl install "$device" "$LABAPP"
  # UIKit's accessibility answers (what VoiceOver would read) — as ios-a11y.sh.
  xcrun simctl spawn "$device" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
  xcrun simctl ui "$device" appearance light >/dev/null 2>&1 || true
  echo "ios-l10n: $name ($tag)"
  for loc in $LOCALES; do capture "$device" "$loc" "$OUT/run/$tag/$loc"; done
  if [[ "$INJECT" != none ]]; then
    for defect in $INJECT; do
      capture "$device" en "$OUT/inject-$defect/$tag/en" -uiL10nOnly account,library -uiL10nInject "$defect"
      capture "$device" de "$OUT/inject-$defect/$tag/de" -uiL10nOnly account,library -uiL10nInject "$defect"
    done
  fi
  xcrun simctl spawn "$device" defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled 2>/dev/null || true
}

rm -rf "$OUT/run" "$OUT"/inject-*
pids=()
for device in $DEVICES; do
  run_device "$device" > "$OUT/device-$device.log" 2>&1 &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
cat "$OUT"/device-*.log

echo "ios-l10n: judging $OUT/run"
python3 "$IOS/scripts/ios-l10n-judge.py" "$OUT/run" || status=1
if [[ "$INJECT" != none ]]; then
  for defect in $INJECT; do
    python3 "$IOS/scripts/ios-l10n-judge.py" "$OUT/inject-$defect" --expect "$defect" || status=1
  done
  python3 "$IOS/scripts/ios-l10n-judge.py" "$OUT/run" --collision-selftest | grep -E 'selftest|CAUGHT|MISSED' || status=1
fi

echo "ios-l10n: screenshots under $OUT/run/<device>/<locale>/{app,lab}/*.png"
if [[ $status -eq 0 ]]; then echo "IOS-L10N PASS"; else echo "IOS-L10N FAIL"; fi
exit $status
