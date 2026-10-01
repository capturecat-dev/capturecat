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
| `CCBadge` | status pill | variant subtle/primary/destructive/outline · live `text` changes crossfade + spring pop + width glide |
| `CCDivider` | 1pt hairline | `vertical:` pins width instead of height |
| `CCCard` | surface container | `init(title:)`, `addContent(_:fullWidth:)` |
| `CCProgressBar` / `CCSpinner` | progress | replaces NSProgressIndicator · bar fill SPRINGS to each value, `isIndeterminate` sweep · spinner is a breathing arc on a faint track |
| `CCPreviewPad` | recessed demo well | `showsGridDots:`, draw inside `contentRect` |
| `CCGlideHighlight` | wash that glides between rows | `update(row:active:)`; wash rides its own subview |
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
| `CCKbd` | shadcn Kbd keycap | `CCKbd("⌘", size: .sm/.regular/.lg)`, `CCKbd.group(["⇧","⌘","4"])`, `tap()` / `isPressed` (tints in place — never travels) |
| `CCStepIndicator` | wizard / carousel dots | `CCStepIndicator(count:)`, `index` (the current dot springs into a capsule), `onSelect` for completed dots |

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
| `--capkit-extras-shot` | toast/tooltip/accordion/tabs/radio/avatar/skeleton/stepper/text area/callout/empty state/ring + polished bar/spinner/badge in ONE 3-column gallery: topology, material via probe seams, motion mid-flight (toast entrance + fan, accordion & text-area growth OVERSHOOT with top pinned, tab glide + directional crossfade, radio bead, digit roll, ring arc + counting label, tooltip scale pivot, badge pop, stagger, callout collapse, avatar spread), tooltip delay/hand-off/flip, toast auto-dismiss, live retheme (22 real-layer probes), responsive shrink incl. text re-wrap + radio hug. Prints `CAPKITX`; captures are upright 2x |
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
