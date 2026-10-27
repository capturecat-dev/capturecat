"use client"

/**
 * The dashboard menus' travelling highlight — the web twin of the editor
 * kit's glide wash (editor/ui/kit/Floating.tsx useGlide) for Radix menus.
 *
 * ONE wash per menu surface GLIDES (transform transition) to whichever row
 * Radix marks `data-highlighted` — pointer or keyboard alike — and rests on
 * a sub-trigger while its submenu is open. Rows themselves never paint a
 * hover background. Placed from offsetLeft/Top, so it is immune to the
 * surface's own scale-in and the rows' stagger rise.
 *
 * `markMenuPicked` tags the surface when an item is chosen, so its close
 * animation first pulses the wash once (styles/app-2026.css).
 */
import * as React from "react"

const ROW = "[data-slot$='-item'], [data-slot$='-sub-trigger']"

export function MenuWash() {
  const ref = React.useRef<HTMLSpanElement>(null)

  React.useLayoutEffect(() => {
    const wash = ref.current
    const surface = wash?.parentElement
    if (!wash || !surface) return
    let visible = false
    let hideTimer = 0

    const place = () => {
      // A closing surface keeps its wash where it is (the pick pulse plays there).
      if (surface.dataset.state === "closed") return
      const rows = [...surface.querySelectorAll<HTMLElement>(ROW)].filter((r) => r.closest("[data-slot$='menu-content'], [data-slot$='menu-sub-content']") === surface)
      const row =
        rows.find((r) => r.hasAttribute("data-highlighted")) ??
        rows.find((r) => r.dataset.slot?.endsWith("sub-trigger") && r.dataset.state === "open")
      if (!row || row.hasAttribute("data-disabled")) {
        // Radix un-highlights the row it leaves BEFORE highlighting the next
        // one; wait a beat so row → row glides instead of blinking.
        if (visible && !hideTimer) {
          hideTimer = window.setTimeout(() => {
            hideTimer = 0
            visible = false
            wash.style.opacity = "0"
          }, 60)
        }
        return
      }
      window.clearTimeout(hideTimer)
      hideTimer = 0
      wash.dataset.tone = row.dataset.variant === "destructive" ? "destructive" : ""
      // Faded out → jump in place, then fade in; visible → glide there.
      wash.dataset.instant = visible ? "false" : "true"
      wash.style.transform = `translate(${row.offsetLeft}px, ${row.offsetTop}px)`
      wash.style.width = `${row.offsetWidth}px`
      wash.style.height = `${row.offsetHeight}px`
      if (!visible) void wash.offsetWidth
      wash.dataset.instant = "false"
      wash.style.opacity = "1"
      visible = true
    }

    const mo = new MutationObserver(place)
    mo.observe(surface, { subtree: true, attributes: true, attributeFilter: ["data-highlighted", "data-state"] })
    place()
    return () => {
      mo.disconnect()
      window.clearTimeout(hideTimer)
    }
  }, [])

  return <span ref={ref} data-slot="menu-wash" data-instant="true" aria-hidden />
}

const SURFACE = "[data-slot$='menu-content'], [data-slot$='menu-sub-content']"

/**
 * An item was chosen: tag its surface `data-picked` (the close pulses the
 * wash on the chosen row, then fades) and every other open menu surface —
 * the parents a submenu pick closes too — `data-picked-parent` (they hold
 * for the pulse, then fade with it).
 */
export function markMenuPicked(el: Element | null) {
  const surface = el?.closest<HTMLElement>(SURFACE)
  if (!surface) return
  surface.setAttribute("data-picked", "")
  for (const s of document.querySelectorAll<HTMLElement>(SURFACE)) {
    if (s !== surface && s.dataset.state === "open") s.setAttribute("data-picked-parent", "")
  }
}

/** Wrap a Radix item's onSelect so a real pick (not prevented) tags the surface. */
export function withPickMark<E extends Event>(onSelect?: (event: E) => void) {
  return (event: E) => {
    onSelect?.(event)
    if (!event.defaultPrevented) markMenuPicked(event.target as Element | null)
  }
}
