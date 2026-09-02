# CCKit — CaptureCat's AppKit design kit

Skeuomorphic, token-driven, 100% AppKit (no SwiftUI — see the repo's CLAUDE.md §1).
Everything in this folder is self-contained: **DesignKit files must not import
app code** (the kit is meant to lift into a standalone package).

## Material (skeuomorphism — since 2026-09-01, previously flat)

Every surface is dressed by `CCMaterial`, derived from the live theme tokens
(no assets). The target look is **soft-extruded matte keys** (Mike's
calculator-icon reference): a raised surface is a chunky key — gentle top-lit
gradient, a thick darker UNDER edge peeking out below (the key's "side",
following the corners), a soft top light, and a soft drop shadow. Pressing
TINTS in place (see Press below) — never movement or a restyle. **No glass
sheen, ever**
(vetoed on sight) and no hard 1px bevel lines on raised surfaces — those
exist only on recessed wells, auto-hidden on pills:

```swift
CCMaterial.dress(layer, as: .raised(tint: fill), radius: r)      // buttons, chips, thumbs
CCMaterial.dress(layer, as: .raisedMatte(tint: fill), radius: r) // cards, dialogs
CCMaterial.dress(layer, as: .recessed(tint: fill), radius: r)    // fields, tracks, wells
CCMaterial.refit(layer, radius: r)   // from layout(): re-frame only
CCMaterial.strip(layer)              // ghost/link/clear surfaces
```

Rules: `dress` from applyTheme (colors+frames), `refit` from layout (frames);
inputs are recessed wells, touchable things are raised. The material
sublayers are named `ccmat.*` and sit BELOW all content — **never probe a
component with `sublayers.first`**; use its `probe*` seams (a material layer
reads as a plausible-but-wrong answer and passes vacuously).

Quality guards (learned from real panes): bevel lines auto-hide on pill-ish
(radius > 35% of height) or narrow (< 40pt) surfaces — straight 1px lines
read as floating dashes there; inner shadows hide under 10pt tall.

The style also covers the editor surfaces: InspectorKit chips/knob/buttons,
the timeline's `drawBlockSurface` (CG twin of the raised material), and the
recording bar via `GlassCompatView.fillColor` — the one choke point that
dresses every filled chip on the bar.

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
| `CCButton` | shadcn Button | `style:` primary/secondary/outline/ghost/link/destructive · `size:` sm/regular/lg · `symbol:` (alone = square icon button) · `radius:` |
| `CCToggle` | switch | `isOn` (spring thumb) |
| `CCCheckbox` | checkbox | `title`, stroke-animated check |
| `CCSegmented` | tabs / segments | `size:` sm/regular · `chrome:` elevated/plain · `radius:` (`.full` = pill, chip stays concentric) · `hoverWash:` glide hover · `setTitle(_:at:)` for live counts |
| `CCSlider` | pill slider | `title`, normalized 0–100% readout (never px/pt) |
| `CCField` | text input | `placeholder`, `isError`, `onCommit/onTextChange`; real padded cell |
| `CCFormRow` | label + control + hint | `setError("…")` glides an error line in; tints a CCField border |
| `CCSelect` / `CCCombobox` | popup select (searchless / searchable) | `options`, `selectedIndex`, `onSelect`; keyboard ↑/↓/↩/⎋ |
| `CCSearchField` | loupe + field | `radius:` (`.full` default), `onQueryChange`, `onCommand` (moveUp/moveDown/commit/cancel) |
| `CCBadge` | status pill | variant subtle/primary/destructive/outline |
| `CCDivider` | 1pt hairline | `vertical:` pins width instead of height |
| `CCCard` | surface container | `init(title:)`, `addContent(_:fullWidth:)` |
| `CCProgressBar` / `CCSpinner` | progress | replaces NSProgressIndicator |
| `CCPreviewPad` | recessed demo well | `showsGridDots:`, draw inside `contentRect` |
| `CCGlideHighlight` | wash that glides between rows | `update(row:active:)`; wash rides its own subview |
| `CCAlert` | NSAlert replacement | `addButton(_:role:)`, `beginSheet`/`runModal`, `accessoryView`, `entrance` |
| `CCDialog` | form dialog (header/scroll/footer) | `addContent`, `addFooter`, `setMaxContentHeight`, `onEscape`, `entrance` |

Dialog/alert cards clamp to their parent window (width AND height, 280pt
floor) and re-center live on parent resize — no work needed at call sites.

## Motion — `CCMotion`

```swift
CCMotion.run { … }                     // NSAnimationContext + settle curve
CCMotion.quick { … }                   // 0.16s glide, hover/press feedback
CCMotion.spring(layer, keyPath:to:)    // .snappy / .smooth / .bouncy
CCMotion.fade(layer, keyPath:to:)      // explicit fades (view layers suppress implicit)
CCMotion.pressScale(view, down:)       // press acknowledgement
CCMotion.fadeContentSwap(label)        // crossfade text swaps (+ animateLayout)
CCMotion.animateLayout(view)           // glide a width change through autolayout
CCMotion.expand(view)                  // GROWTH: lands on the house bounce
CCMotion.animateFrame(of: window, to:) // curve-true window-frame animation
CCMotion.pace = .relaxed/.standard/.brisk   // ONE knob scales all kit motion
```

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
// styles: .scaleIn (default Keynote settle) · .slideUp() · .slideDown() · .fade
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

Gate laws: probe inside the real hosting chain, assert animations **mid-flight**
(never only settled frames), and prove a new assertion can fail by injecting
the defect once. Two measurement gotchas: constraints solve on **alignment
rects** (NSTextField frames carry ~2pt slop), and a window won't shrink below
its content's required minimum — assert against the resolved width. A
CARenderer snapshot taken in the same runloop turn as a resize renders blank;
defer it a beat.

**Press = tint in place.** Apple buttons never move: press darkens (light) or lightens (dark) the surface via the component wash or `CCMaterial.press(layer, down:)` — no travel, no scale, no restyle. Actions fire on mouseUp with an inside check, never bare mouseDown.
