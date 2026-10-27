# CCKit — CaptureCat's AppKit design kit

Token-driven, 100% AppKit (no SwiftUI — see the repo's CLAUDE.md §1), in the
**2026 look** (2026-10-27): soft, airy, floating surfaces and our own icon kit.
Everything in this folder is self-contained: **DesignKit files must not import
app code** (the kit is meant to lift into a standalone package).

## Material (the 2026 floating/well look — replaced skeuomorphism 2026-10-27)

Every surface is dressed by `CCMaterial`, derived from the live theme tokens
(no assets). Mike's brief: "a more 2026 style like macOS apps" — soft,
airy, floating surfaces, in our own drawing. It REPLACES the 2026-09-01 skeuomorphic keys
(extruded under-edge, inner top light, bevel lines) — none of that is drawn
any more:

- **raised** — a FLOATING surface: the tint with a whisper of top light
  (2–3.5% toward white, only so big panels don't look printed), a 0.5pt
  hairline that follows the corners, and a soft cast shadow scaled to the
  surface height (`floatShadow`: tight contact shadow under a 20pt chip,
  airy 14pt blur under a 160pt card).
- **raisedMatte** — the same floating face without the cast shadow (cards,
  dialogs — their window/container supplies depth).
- **recessed** — a flat WELL: the tint and a quieter hairline. No inner
  shadow; depth comes from the floating surfaces around it.

Pressing TINTS in place (see Press below) — never movement or a restyle.
**No glass sheen, ever** (vetoed on sight), and never system Liquid Glass.
Toolbar icon buttons are **ghost** buttons: no surface at rest, a recessed
wash on hover, a raised chip when active.

```swift
CCMaterial.dress(layer, as: .raised(tint: fill), radius: r)      // buttons, chips, thumbs
CCMaterial.dress(layer, as: .raisedMatte(tint: fill), radius: r) // cards, dialogs
CCMaterial.dress(layer, as: .recessed(tint: fill), radius: r)    // fields, tracks, wells
CCMaterial.refit(layer, radius: r)   // from layout(): re-frame only
CCMaterial.strip(layer)              // ghost/link/clear surfaces
CCMaterial.suppressShadow(layer)     // packed bars / translucent hosts
```

Rules: `dress` from applyTheme (colors+frames), `refit` from layout (frames);
inputs are recessed wells, touchable things are raised. The material
sublayers are named `ccmat.*` and sit BELOW all content — **never probe a
component with `sublayers.first`**; use its `probe*` seams (a material layer
reads as a plausible-but-wrong answer and passes vacuously). The 2026 look
keeps every `ccmat.*` layer (base, under, bevelTop/Bottom, innerTop) and just
hides the unused ones, so indices and the self-heal are unchanged.

Quality guard: the hairline is dropped on surfaces under 10pt in either
dimension (it would read as an outline, not an edge).

The style also covers the editor surfaces: InspectorKit chips/knob/buttons,
the timeline's `drawBlockSurface` (CG twin of the raised material), and the
recording bar via `GlassCompatView.fillColor` — the one choke point that
dresses every filled chip on the bar.

## Icons — `CCIcon` (our own kit; SF Symbols only for content)

Chrome icons are CaptureCat's own line-icon kit, not SF Symbols: 24-unit
grid, live area 2–22, 1.75 stroke with round caps/joins, solid parts filled
(knockouts are reverse-wound subpaths). The renderer (`CCIcon.swift`) turns
a small SVG subset (`path` M L H V C S Q T A Z abs+rel, `circle`, `rect rx`,
`line`) into images sized like an SF Symbol of the same point size
(a `1.32 × pt` square on the half-point grid — `CCIcon.side(for:)`, calibrated
against SF over every alias to ~0.92–0.98× its extent), with the stroke
thickened on SF's own weight curve (`strokeScale`: semibold ≈ 1.25× regular).

```swift
CCIcon.image("sparkles", pointSize: 13, weight: .semibold)        // TEMPLATE — tint with contentTintColor
CCIcon.image("link", pointSize: 12, weight: .semibold, color: c) // painted — CALayer contents, CG canvases
CCIcon.draw("scissors", in: ctx, rect: r, color: c)              // straight into a Y-down context
CCIcon.has("book.pages")                                         // existence check (replaces NSImage(systemSymbolName:) != nil)
```

Call sites ask by the old **SF Symbol name** (or a kit name); the generated
alias table maps it to a kit glyph. An unknown name falls back to the SF
Symbol, so a missing icon degrades instead of vanishing — but the fallback is
off-style, which is why the gates below assert every name is drawn.
`symbolConfiguration` on an `NSImageView` does NOT apply to kit images: pass
the size and weight to `CCIcon.image`. To fill a fixed icon slot exactly,
pick the point size whose `CCIcon.side(for:)` equals it (12pt → a 16pt box —
the browser sidebar's slot); a mismatch rescales the glyph and softens it.

**Adding or changing an icon:**

1. Edit `apps/macos/IconKit/icons.json` — the glyph under `icons` (kit name →
   markup) and, if a call site will ask by SF name, an entry under `aliases`.
   Keep inside the 2–22 live area: the stroke must not leave the 24 grid.
2. `python3 apps/macos/IconKit/gen-iconset.py` → regenerates
   `CCIconSet.swift` (GENERATED — never hand-edit it; the script rejects
   markup outside the supported subset).
3. Build, then run `CaptureCat --iconkit-test` and `--notes-test` (append any
   new call-site name to the chrome-icon audit in `main.swift`).

**SF Symbols stay ONLY where the glyph is content or frozen as content:**
`MenuBarRenderer` (battery/wifi drawn into exported video, measured by the
web parity oracle), `SelectionChromeKit` (selection-pill slider glyphs,
frozen in `--raster-golden`), and `Services/WebVectors/**` (oracles). Never
use `NSImage(systemSymbolName:)` for chrome.

## Hard rules

- **Never use stock AppKit chrome.** `NSAlert`, `NSProgressIndicator`, default
  `NSButton`/`NSSlider` bezels are banned; use the CC components below. The one
  tolerated stock control is `NSDatePicker` (hosted inside a `CCAlert`).
- **Every color goes through `applyTheme()`.** Each component holds a
  `CCThemeObservation` (fires at init + on every theme change) and re-applies
  ALL colors there. Never bake a `cgColor` at init only.
- **Never hardcode a corner radius.** Use the `CCRadius` scale (law:
  `.sm` menu-row highlights, `.md` buttons, `.lg` menus/popovers/cards,
  `.xl` dialog cards, `.full` pills). `radius.resolved(for: height)` resolves
  `.full` to height/2.
- **State flows in via `withObservationTracking` re-arm loops, out via
  callback closures.** No bindings.
- **Hover in floating panels is POLLED** (`CCHoverPoller`, 30 Hz,
  `NSEvent.mouseLocation`) — tracking areas and mouse-moved monitors drop out
  over borderless child panels that overhang their parent. In-window controls
  may use tracking areas.

## Tokens — `CCTheme`

```swift
CCTheme.color.background / .foreground / .card / .elevated / .border
CCTheme.color.primary / .primaryForeground / .destructive / .muted…
CCTheme.color.hover / .active / .overlay        // washes + scrim
CCTheme.font.title / .header / .button / .label / .chip / .caption
CCTheme.radius(.md)   CCSpace.xs…lg             // radius + spacing scales
CCTheme.isDark                                   // hard-contrast literals only
CCTheme.setMode(.dark / .light / .system)        // persists; .system tracks OS
CCTheme.apply { $0.radii.md = 8 }                // CSS-variables-style override
CCThemeObservation { applyTheme() }              // keep a strong reference!
```

## Components

| Component | What | Knobs |
|---|---|---|
| `CCButton` | shadcn Button | `style:` primary/secondary/outline/ghost/link/destructive · `size:` sm/regular/lg · `symbol:` (a CCIcon name; alone = square icon button) · `radius:` |
| `CCToggle` | switch | `isOn` (spring thumb) |
| `CCCheckbox` | checkbox | `title`, stroke-animated check |
| `CCSegmented` | tabs / segments | `size:` sm/regular · `chrome:` elevated/plain · `radius:` (`.full` = pill, chip stays concentric) · `hoverWash:` glide hover · `setTitle(_:at:)` for live counts |
| `CCSlider` | pill slider | `title`, normalized 0–100% readout (never px/pt) |
| `CCField` | text input | `placeholder`, `isError`, `onCommit/onTextChange`; real padded cell |
| `CCFormRow` | label + control + hint | `setError("…")` glides an error line in; tints a CCField border |
| `CCSelect` / `CCCombobox` | popup select (searchless / searchable) | `options`, `selectedIndex`, `onSelect`; keyboard ↑/↓/↩/⎋; the popup is the house menu (CCMenuStage + CCMenuList), opens with the current value highlighted |
| `CCSearchField` | loupe + field | `radius:` (`.full` default), `onQueryChange`, `onCommand` (moveUp/moveDown/commit/cancel) |
| `CCBadge` | status pill | variant subtle/primary/destructive/outline · live `text` changes crossfade + spring pop + width glide |
| `CCDivider` | 1pt hairline | `vertical:` pins width instead of height |
| `CCCard` | surface container | `init(title:)`, `addContent(_:fullWidth:)` |
| `CCProgressBar` / `CCSpinner` | progress | replaces NSProgressIndicator · bar fill SPRINGS to each value, `isIndeterminate` sweep · spinner is a breathing arc on a faint track |
| `CCPreviewPad` | recessed demo well | `showsGridDots:`, draw inside `contentRect` |
| `CCGlideHighlight` | wash that glides between rows | `update(row:active:)`, `pulse()` (the pick blink), `crossfadesInsteadOfGliding` (Reduce Motion); wash rides its own subview, flipped like its host |
| `CCAlert` | NSAlert replacement | `addButton(_:role:)`, `beginSheet`/`runModal`, `accessoryView`, `entrance` |
| `CCDialog` | form dialog (header/scroll/footer) | `addContent`, `addFooter`, `setMaxContentHeight`, `onEscape`, `entrance` |
| `CCToaster` / `CCToast` | Sonner toasts (in-window overlay) | `CCToaster(in: view)`, `show(title:message:variant:symbol:action:duration:)`, `maxVisible`, `dismissAll()`; variants default/success/warning/destructive; stack compresses behind the front toast, fans out on hover (countdowns pause), countdown hairline, `.init(title:){…}` action |
| `CCTooltip` | hover tooltip for any view | `CCTooltip.attach(to:text:shortcut:placement:)`, `detach(from:)`; 0.5s delay, instant hand-off, flips at window edges, scale-in from the target-facing edge |
| `CCAccordion` | shadcn Accordion | `init(mode: .single/.multiple, chrome: .card/.plain)`, `addItem(title:text:)` / `addItem(title:content:)`, `setExpanded(_:at:)`, `onChange`; space/return toggle, ↑/↓ focus |
| `CCCollapsible` | reveal container | `init(content:expanded:)`, `toggle()`, `setExpanded(_:animated:)`, `onToggle`; bottom edge only, growth bounce |
| `CCTabs` | tab list + panes | `init([(title, pane)], selectedIndex:listFillsWidth:size:)`, `selectedIndex`, `onChange`; CCSegmented list, directional crossfade |
| `CCRadioGroup` | radio group | `init(options:selectedIndex:orientation:onChange:)`, `Option(title:detail:)`; bead springs in, arrows move |
| `CCAvatar` / `CCAvatarGroup` | avatar(s) | `CCAvatar(name:image:size:status:)` (deterministic hue initials, `.live` pulse), `CCAvatarGroup(names:maxVisible:size:)` (ring gap, "+N", hover spread) |
| `CCSkeleton` / `CCSkeletonReveal` | loading placeholders | `.line/.block/.circle`, `CCSkeleton.lines(n)`, synced opacity pulse (no sheen); `CCSkeletonReveal(placeholder:content:).reveal()` |
| `CCStepper` | −/+ numeric stepper | `init(value:min:max:step:)`, `format`, `onChange`; rolling digits, hold-to-repeat with acceleration, ↑/↓ |
| `CCRollingLabel` | odometer text | `setText(_:direction: .up/.down/.none)` — only changed glyphs roll |
| `CCTextArea` | multi-line input | `init(placeholder:minLines:maxLines:)`, `text`, `onTextChange`; auto-grows (bounce, bottom edge), scrolls past `maxLines` |
| `CCCallout` | inline alert | `init(title:message:variant:dismissible:)`, info/success/warning/destructive, `onDismiss`, `playEntrance()`, `setActions([CCButton])` (a button row under the text — "[Restore] [Back to Current]") |
| `CCEmptyState` | empty state | `init(symbol:title:message:primary:secondary:)`, staggered entrance |
| `CCProgressRing` | circular progress | `init(diameter:lineWidth:)`, `doubleValue`, `labelFormat`, `isIndeterminate`; arc springs, label counts |
| `CCWrappingLabel` | multi-line label | re-wraps in its OWN layout; yields width below the window's resize priority |
| `CCKbd` | shadcn Kbd keycap | `CCKbd("⌘", size: .sm/.regular/.lg, tone: .standard/.quiet)`, `CCKbd.group(["⇧","⌘","4"])`, `tap()` / `isPressed` (tints in place — never travels); `.quiet` = flat well in faint ink (menu shortcuts) |
| `CCMenuStage` / `CCMenuList` / `CCMenuRow` | THE menu (every custom menu: context menus, dropdowns, pickers, combobox popups) | see **Menus** below |
| `CCStepIndicator` | wizard / carousel dots | `CCStepIndicator(count:)`, `index` (the current dot springs into a capsule), `onSelect` for completed dots |

## Menus — `CCMenu.swift`

Every custom menu renders through one kit: `CaptureCatMenuPresenter` (NSMenu
→ context menus, dropdowns, flyout submenus), `TimelinePickerPopover` (the
timeline's rich pickers, via `CaptureCatPopover`) and `CCComboboxPopup`
(CCSelect/CCCombobox). Presenters keep their own panel, keyboard and
dismissal logic; everything visible comes from here.

- **`CCMenuStage`** — the panel's content view: the floating surface
  (`popover` token, `.lg` radius, CCMaterial hairline, soft wide shadow —
  "radius 24 / y 10 / dark .45 · light .16"; CA's `shadowRadius` is a
  SIGMA, so the layer value is 12) inside a transparent margin the shadow
  falls into (a layer shadow is clipped at the WINDOW edge — size panels
  with `panelFrame(surfaceOrigin:)`, hit/hover-test `surfaceScreenRect`).
- **`CCMenuList`** — rows, sentence-case section headers (+ an optional
  caption that says why a section is unavailable), hairline separators.
  `fittingWidth()` picks min 220 / max 380 where NO title, subtitle or
  shortcut ever truncates (the menu widens instead) and every description
  needs ≤ 2 lines; height grows to fit and only scrolls past the screen
  (`CCMenuStage.maxSurfaceHeight`). Owns the glide wash, the single
  hover/keyboard highlight (`routeHover(windowPoint:)` — hover is POLLED by
  the presenter, `moveHighlight`, `typeSelect`, `activateHighlighted`,
  `pinnedRow` for an open flyout), the pick `pulse(_:then:)` and the row
  stagger. Disabled rows dim and take no hover.
- **`CCMenuRow`** — `.simple` (30 pt: 16 pt kit icon in muted ink · 13 pt
  title · faint inline subtitle · quiet `CCKbd` shortcut cap · check/mixed/
  chevron at the FAR right) or `.rich` (30×30 well tile with a 15 pt icon ·
  13 pt semibold title · 11.5 pt muted description wrapping ≤ 2 lines; on
  hover the tile springs to the accent with a white icon).

Motion (Reduce Motion → fades only): OPEN = 120 ms fade + 0.96→1 scale on
`CCMotion.Spring.arrive` (slight overshoot) pivoting on the edge nearest the
trigger + a 6 pt slide from it; rows stagger in (fade + 6 pt rise, 18 ms
apart, first 8). HOVER = the glide wash. PICK = the wash blinks once
(~120 ms), then the menu closes and the action runs (CCCombobox commits its
model synchronously and blinks during the close). CLOSE = 100 ms fade +
scale to 0.98. FLYOUT = 6 pt slide + fade (140 ms dwell / 300 ms grace).

Probe seams: `CCMenu.probeIsolated` (the real pointer and outside clicks
never reach a probe's menus; CCHoverPoller ticks stop), `probeReduceMotion`,
`probeInjectedDefects` (`"narrow"`, `"snap"` — the gate's self-tests),
`CaptureCatMenuPresenter.probeRoot/probeFlyout`, `CaptureCatPopover.probeStage/
probeList`, `CCComboboxPopup.probeStage/probeList`.

Dialog/alert cards clamp to their parent window (width AND height, 280pt
floor) and re-center live on parent resize — no work needed at call sites.

## Motion — `CCMotion`

```swift
CCMotion.run { … }                     // NSAnimationContext + settle curve
CCMotion.quick { … }                   // 0.16s glide, hover/press feedback
CCMotion.spring(layer, keyPath:to:)    // .snappy / .smooth / .bouncy / .arrive (floating-surface arrival)
CCMotion.fade(layer, keyPath:to:)      // explicit fades (view layers suppress implicit)
CCMotion.pressScale(view, down:)       // press acknowledgement
CCMotion.fadeContentSwap(label)        // crossfade text swaps (+ animateLayout)
CCMotion.animateLayout(view)           // glide a width change through autolayout
CCMotion.expand(view)                  // GROWTH: lands on the house bounce
CCMotion.animateFrame(of: window, to:) // curve-true window-frame animation
CCMotion.animate(constraint, to:, in:) // curve-true IN-WINDOW growth (120 Hz, relayout per tick)
CCMotion.spring(layer, keyPath:from:to:_:delay:)  // explicit start + optional stagger delay
CCMotion.glide(view, to: frame)        // FLIP: frame lands now, the visual springs there
CCMotion.scaleTransform(s, pivot:in:)  // anchor-safe scale about any pivot (view layers)
CCMotion.pop(view)                     // small spring pop for content changes
CCMotion.fadeAlpha(view, to:)          // alphaValue-safe view fade (+ delay/from)
CCMotion.stagger(views)                // staggered fade + rise arrivals
CCMotion.pace = .relaxed/.standard/.brisk   // ONE knob scales all kit motion
```

**In-window growth goes through `CCMotion.animate(constraint…)`**, not
implicit layout animation: `CCMaterial.refit` runs with actions disabled, so
under an implicit bounds animation the dressed surface parks at its FINAL
size while only the content bounces. The constraint driver re-lays-out every
tick, so material, content and siblings move in lockstep (collapsible,
accordion card, tabs pane area, text area, badge width, callout collapse).

**Scale effects never re-anchor a view's backing layer** — AppKit owns its
anchorPoint; compose the pivot with `scaleTransform` instead. Keep scale and
FLIP translation on different layers (toasts: scale on the card, glide on the
container).

**Growth bounces, and only the pushed edge moves.** Anything that grows —
a dialog gaining rows, a title getting wider, an error line appearing — lands
with the soft `bounce` overshoot (~10%), never a flat stop. And the ONLY edge
that animates is the edge the content pushes (stacked rows push the bottom;
a widening title pushes the trailing edge): every other edge stays pinned and
existing content/text never shifts or fades during the resize. Use
`CCMotion.expand(view)` for autolayout growth,
`dialog.animateContentChange { … }` for presented dialogs (mutations apply
instantly; the bottom edge reveals them as it travels), and
`CCMotion.resize(window, to:moving:)` for window growth with explicit pinned
edges. **Never animate a window frame with `window.animator()`** — that path
ignores timing functions entirely (the bounce silently flattened until the
overshoot gate caught it); `animateFrame`/`resize` drive the exact curve.

**Entrances** — how surfaces arrive/leave (transform-only; the caller owns the
alpha fade — dialogs fade their window, in-window views pair with an opacity
fade):

```swift
dialog.entrance = .slideUp()                    // CCDialog / CCAlert knob
alert.entrance  = .slideDown(distance: 16)
CCMotion.enter(toast.layer!, .scaleIn)          // any layer
CCMotion.exit(toast.layer!, .scaleIn)
// styles: .scaleIn (default house settle) · .slideUp() · .slideDown() · .fade
```

**Glide-hover state law:** a wash keeps its `current` row through the exit
fade and appears-in-place only when its *presentation* opacity is faded out —
otherwise every hop after a pause snaps instead of gliding (shipped bug,
2026-08-15).

## Verification gates (run the built binary)

| Flag | Covers |
|---|---|
| `--capkit-shot` | every component: topology, live dark→light retheme, motion mid-flight (toggle, checkbox, title-swap, glide, segmented hover), pill radius geometry, responsive window-shrink pass |
| `--capalert-shot` | alert: entrance mid-flight, parent-resize re-clamp, click-through, teardown |
| `--capdialog-shot` | dialog: scroll body resolves, responsive re-clamp, `.slideUp` entrance mid-flight |
| `--menu-hover-probe` / `--menu-hover-live` | menu wash glides between rows (synthetic / real cursor) |
| `--menu-shot [dir]` | the REAL menus in the real editor topology, dark + light: effects picker with/without camera (sections, disabled-group caption, disabled rows take no hover), a context menu with shortcuts + a flyout (dwell, slide mid-flight, row-level alignment), the editor's aspect CCSelect, the annotation picker, a 2-line wrap at 380 pt: no label truncated (cell-measured), surface tokens + shadow room, open mid-flight ~60 ms into the animation + stagger + settle, hover glide + tile cross-fade mid-flight, pick blink, close fade, Reduce Motion fade-only. `--inject narrow` / `--inject snap` must FAIL. `--before` = captures only. Prints `MENUSHOT` |
| `--capkit-extras-shot` | toast/tooltip/accordion/tabs/radio/avatar/skeleton/stepper/text area/callout/empty state/ring + polished bar/spinner/badge in ONE 3-column gallery: topology, material via probe seams, motion mid-flight (toast entrance + fan, accordion & text-area growth OVERSHOOT with top pinned, tab glide + directional crossfade, radio bead, digit roll, ring arc + counting label, tooltip scale pivot, badge pop, stagger, callout collapse, avatar spread), tooltip delay/hand-off/flip, toast auto-dismiss, live retheme (22 real-layer probes), responsive shrink incl. text re-wrap + radio hug. Prints `CAPKITX`; captures are upright 2x |
| `--iconkit-test` | the icon kit: every glyph parses to its end (one shape per element, on the 24 grid), every SF alias draws its kit glyph (never the SF fallback), template box + non-empty + unclipped at 16/24 pt, ink strictly grows with weight, parser unit cases (relative, implicit lineto, packed arc flags, `.5.5`, exponents, elliptical/rotated/out-of-range/zero-radius arcs, S/T), structural ring/knockout/orientation probes; writes light/dark contact sheets of the Swift renderer. Prints `ICONKIT` |
| `--onboarding-shot` | the onboarding (uses `CCKbd` + `CCStepIndicator`) in BOTH hosts (own window + editor content switcher): per-step layout invariants, stage motion mid-flight (camera push, page glide, scene dissolve, step capsule stretch, mirrored switch spring), finish burst, retheme, resize, and a STRUCTURAL check that every material-dressed raw layer rounds its own fill (a square host paints a black box behind the pill) |

Gate laws: probe inside the real hosting chain, assert animations **mid-flight**
(never only settled frames), and prove a new assertion can fail by injecting
the defect once. Two measurement gotchas: constraints solve on **alignment
rects** (NSTextField frames carry ~2pt slop), and a window won't shrink below
its content's required minimum — assert against the resolved width. A
CARenderer snapshot taken in the same runloop turn as a resize renders blank;
defer it a beat. **Sample motion BEFORE any CARenderer capture:** the renderer
re-hosts the live layer tree and the window's next commit drops every
in-flight animation (springs read as snapped, loops vanish) — capture last.

Two AppKit layout traps (both shipped once in this kit's development and are
now gated): `NSStackView` is **unflipped**, and a view's `isGeometryFlipped`
is RELATIVE to its parent (AppKit toggles it so a view's sublayer space
matches its own `isFlipped`) — CCMaterial orients by it, so containers of
dressed views stay unflipped (pin to the top with constraints); for your own
sublayer geometry use `layer.contentsAreFlipped()`. And a wrapping label must
sync its wrap width in its OWN `layout()` (`CCWrappingLabel`), with horizontal
compression resistance below 500, or text clips on shrink and the window
can't narrow.

**Press = tint in place.** Apple buttons never move: press darkens (light) or lightens (dark) the surface via the component wash or `CCMaterial.press(layer, down:)` — no travel, no scale, no restyle. Actions fire on mouseUp with an inside check, never bare mouseDown.
