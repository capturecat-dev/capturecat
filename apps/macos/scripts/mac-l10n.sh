#!/usr/bin/env bash
# mac-l10n: the Mac app in every catalog language — nothing left in English,
# nothing cut off — through the REAL gates and window chains.
#
#   apps/macos/scripts/mac-l10n.sh
#
# 1. The String Catalog (scripts/l10n-catalog.py check): every key translated
#    into de fr es es-MX it pt-BR nl ja ko zh-Hans, placeholders intact.
# 2. Per locale (`-AppleLanguages (xx) -AppleLocale xx_YY`), each gate run
#    with `--l10n-audit <dir>` (Views/Shared/DesignKit/CCLocalizationAudit.swift
#    records every visible / spoken text, measures truncation and clipping,
#    writes JSON + PNG per screen):
#      --menu-shot             every custom menu (effects picker, context menu
#                              + submenu, combobox popup, wrap fixture)
#      --editor-shell-shot     the editor window with its in-content top bar
#      --recording-panel-shot  the recording panel per phase and tab, its
#                              menus and popups, the status-item menu
#      --inspector-probe       every inspector tab, top and scrolled to the
#                              end (plain, camera, annotate fixtures)
#      --onboarding-shot       every onboarding step, both topologies
#      --settings-shot         every Settings pane (Language picker included)
#      --agent-setup-shot      Connect AI Agents
#    A gate's own PASS/FAIL is reported too: localization must not break one.
# 3. scripts/mac-l10n-judge.py: a text identical to the English run is
#    untranslated (unless the catalog says it's the same word in that
#    language, or it's fixture content in mac-l10n-allow.txt); any truncated
#    or clipped text in any language fails.
# 4. Gate power (unless INJECT=none): the same run on German with an injected
#    hard-coded English label, and with a label squeezed to half its width —
#    both must be CAUGHT.
#
# Env: LOCALES="de ja …"   (default: all 12 + the en baseline)
#      GATES="menu inspector …" (default: all, names as in gate_args below)
#      OUT=<dir>            (default: $TMPDIR/capturecat-mac-l10n)
#      APP=<CaptureCat.app> use this (UNSANDBOXED) build instead of building
#      INJECT=none          skip step 4
#
# Build: an UNSANDBOXED Debug copy in its own DerivedData (like
# render-baseline.sh): a sandboxed build writes into its container, which
# another process can't read without a privacy prompt; and a separate
# DerivedData keeps clear of an Xcode-attached Debug app.
set -uo pipefail

MAC="$(cd "$(dirname "$0")/.." && pwd)"
LOCALES="${LOCALES:-en en-GB en-US de fr es es-MX it pt-BR nl ja ko zh-Hans}"
GATES="${GATES:-menu shell recording inspector inspector-camera inspector-annotate onboarding settings agents}"
OUT="${OUT:-${TMPDIR:-/tmp}/capturecat-mac-l10n}"
INJECT="${INJECT:-untranslated truncate}"
mkdir -p "$OUT"

status=0
echo "mac-l10n: static lint (scripts/l10n-lint.py)"
python3 "$MAC/scripts/l10n-lint.py" | tail -12 || status=1
# Gate power: a copy of a real view file with a raw literal and a raw value
# at UI sinks must FAIL the lint.
LINTINJ="$(mktemp -d)"
cp "$MAC/CaptureCat/Views/Editor/InspectorKit/InspectorColumnAppKit.swift" "$LINTINJ/Injected.swift"
printf '\nfunc l10nInjected(_ f: NSTextField, _ t: InspectorTab) {\n    f.stringValue = "Delete"\n    _ = RailButton(icon: t.icon, title: t.rawValue)\n}\n' >> "$LINTINJ/Injected.swift"
if python3 "$MAC/scripts/l10n-lint.py" "$LINTINJ" > "$LINTINJ/out.txt"; then
  echo "L10N-LINT inject: MISSED"; status=1
else
  echo "L10N-LINT inject: CAUGHT ($(grep -c 'raw “' "$LINTINJ/out.txt") finding(s): $(grep -o 'raw “[^”]*”' "$LINTINJ/out.txt" | tr '\n' ' '))"
fi
rm -rf "$LINTINJ"

echo "mac-l10n: catalog"
python3 "$MAC/scripts/l10n-catalog.py" check | tail -3 || status=1

if [[ -z "${APP:-}" ]]; then
  DD="${DERIVED_DATA:-${TMPDIR:-/tmp}/capturecat-mac-l10n-dd}"
  echo "mac-l10n: building unsandboxed Debug into $DD"
  (cd "$MAC" && xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug \
    -derivedDataPath "$DD" CODE_SIGN_ENTITLEMENTS=scripts/release.entitlements ENABLE_APP_SANDBOX=NO build > "$OUT/build.log" 2>&1) \
    || { grep -E '^/.*error:' "$OUT/build.log" | head -20; echo "MAC-L10N FAIL (build)"; exit 1; }
  APP="$DD/Build/Products/Debug/CaptureCat.app"
fi
BIN="$APP/Contents/MacOS/CaptureCat"
[[ -x "$BIN" ]] || { echo "MAC-L10N FAIL (no binary at $BIN)"; exit 1; }

region() {  # region <locale> — a plausible AppleLocale for it
  case "$1" in
    en) echo en_US ;; en-GB) echo en_GB ;; en-US) echo en_US ;; de) echo de_DE ;; fr) echo fr_FR ;;
    es) echo es_ES ;; es-MX) echo es_MX ;; it) echo it_IT ;; pt-BR) echo pt_BR ;; nl) echo nl_NL ;;
    ja) echo ja_JP ;; ko) echo ko_KR ;; zh-Hans) echo zh_CN ;; *) echo "$1" ;;
  esac
}

gate_args() {  # gate_args <gate> <scratch-dir> — the gate's own flags
  case "$1" in
    menu) echo "--menu-shot $2" ;;
    shell) echo "--editor-shell-shot $2" ;;
    recording) echo "--recording-panel-shot $2" ;;
    inspector) echo "--inspector-probe" ;;
    inspector-camera) echo "--inspector-probe camera" ;;
    inspector-annotate) echo "--inspector-probe annotate" ;;
    onboarding) echo "--onboarding-shot" ;;
    settings) echo "--settings-shot" ;;
    agents) echo "--agent-setup-shot" ;;
  esac
}

run_limited() {  # run_limited <seconds> <cmd…> — macOS has no timeout(1)
  local limit="$1"; shift
  "$@" & local pid=$!
  ( sleep "$limit"; kill -9 "$pid" 2>/dev/null ) & local watchdog=$!
  wait "$pid"; local code=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  return $code
}

GATE_PASS_RE='(MENUSHOT|ONBOARDING|SETTINGS|AGENTS) (PASS|FAIL)$|^PANEL-CLICKS|SHELLSHOT FAIL'

capture() {  # capture <locale> <run-dir> [extra args…] — every gate in one locale
  local loc="$1" run="$2"; shift 2
  local lang=(-AppleLanguages "($loc)" -AppleLocale "$(region "$loc")")
  for gate in $GATES; do
    local dest="$run/$loc/$gate" scratch="$run/.scratch/$loc-$gate"
    rm -rf "$dest" "$scratch" && mkdir -p "$dest" "$scratch"
    # shellcheck disable=SC2046
    run_limited 300 "$BIN" $(gate_args "$gate" "$scratch") --l10n-audit "$dest" "${lang[@]}" "$@" \
      > "$run/.scratch/$loc-$gate.log" 2>&1
    local code=$?
    local n; n=$(find "$dest" -name '*.json' | wc -l | tr -d ' ')
    local verdict; verdict=$(grep -aE "$GATE_PASS_RE" "$run/.scratch/$loc-$gate.log" | tail -1)
    printf "    %-8s %-20s exit=%-3s screens=%-3s %s\n" "$loc" "$gate" "$code" "$n" "$verdict"
    if [[ "$n" == "0" ]]; then echo "    ! $loc $gate wrote no audit (log: $run/.scratch/$loc-$gate.log)"; status=1; fi
  done
}

RUN="$OUT/run"
echo "mac-l10n: capturing ($LOCALES)"
for loc in $LOCALES; do capture "$loc" "$RUN"; done
echo "mac-l10n: judging"
python3 "$MAC/scripts/mac-l10n-judge.py" "$RUN" || status=1

# Collision power: a catalog copy where German "Tilt" takes "Skew"'s word —
# both labels sit on the Tilt inspector, so the judge must call it out.
if [[ "$INJECT" != none && -d "$RUN/de" ]]; then
  COLL="$(mktemp -d)"
  python3 - "$MAC/CaptureCat/Resources/Localizable.xcstrings" "$COLL/cat.xcstrings" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
s = c["strings"]
s["Tilt"]["localizations"]["de"] = s["Skew"]["localizations"]["de"]
json.dump(c, open(sys.argv[2], "w"), ensure_ascii=False)
PY
  echo "mac-l10n: gate power — injected collision (German Tilt = Skew)"
  L10N_CATALOG="$COLL/cat.xcstrings" python3 "$MAC/scripts/mac-l10n-judge.py" "$RUN" --expect collision | grep -A6 'L10N-JUDGE' || status=1
  rm -rf "$COLL"
fi

for defect in $INJECT; do
  [[ "$defect" == none ]] && continue
  INJ="$OUT/inject-$defect"
  echo "mac-l10n: gate power — injected $defect (German)"
  rm -rf "$INJ" && mkdir -p "$INJ"
  cp -R "$RUN/en" "$INJ/en"
  capture de "$INJ" --l10n-inject "$defect"
  python3 "$MAC/scripts/mac-l10n-judge.py" "$INJ" --expect "$defect" || status=1
done

echo "mac-l10n: output in $OUT"
echo "MAC-L10N $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit $status
