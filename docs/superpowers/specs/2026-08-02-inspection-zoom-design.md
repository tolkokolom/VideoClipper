# VideoClipper — mouse-wheel inspection zoom with schematic minimap

**Date:** 2026-08-02
**Status:** Approved (design)

## Goal

Let the user zoom into the video canvas with the mouse wheel to inspect detail,
panning by drag, with a corner **minimap** that schematically shows the current
zoom area. The minimap is a faithful port of the iOS ClipShot `ZoomMinimap`
(`15_ClipShot/GestureRecognition/ClipEditorView.swift`): a white outline
representing the whole frame and a yellow box representing the part currently
on screen, shown only while interacting.

This is a **viewing aid only**. It never affects trim, crop, rotation, or
export. Everything returns to normal at 1×.

## Interaction model

- **Scroll wheel** over the canvas zooms toward the cursor. Scroll up = zoom
  in. The canvas doesn't scroll, so no modifier key is needed.
- **Trackpad pinch** (magnify gesture) also zooms toward the cursor.
- While zoomed in (> 1×), **left-drag pans** the view (the canvas has no click
  action, so nothing conflicts).
- Zoom range **1×–8×**. Wheel steps are exponential:
  `factor = exp(deltaY * k)`, `k = 0.003` as the starting sensitivity
  (a tunable constant). Precise trackpad deltas are used as-is; clicky-wheel
  line deltas are scaled ×16.
- Zooming out clamps to exactly 1× (state returns to exact identity).
- **Tool interplay:** zoom works in normal and Trim modes. Entering **Crop**
  resets zoom to 1× and suspends zoom gestures — the crop overlay owns
  dragging.
- **Resets:** zoom returns to identity on clip switch and on rotate (the
  displayed aspect changes).

## Rendering approach

Zoom state is **normalized**: `ZoomMath.State { zoom, cx, cy }` where
`(cx, cy)` is the center of the visible region in 0…1 canvas coordinates
(top-left origin). `visibleRect(state)` derives the normalized visible region;
it drives the layer transform.

Pan and zoom clamp against the fitted video's rect, not the full canvas
(`within video: CGRect` on `zoom`/`wheelZoom`/`pan`, normalized to canvas
coordinates — defaults to the full canvas). Per axis: where the zoomed video
overflows the viewport, the center clamps inside the video's band; where it
doesn't (e.g. the short axis of a letterboxed clip until zoom pushes it past
1:1), the center pins to the video band's midpoint — no pan on that axis.
This matches iOS `clampedInspectionPan`, and it means a clip whose aspect
differs from the canvas can never pan into pure letterbox. With the video
rect equal to the full canvas the clamp reduces exactly to the old
frame-relative behavior.

The zoom is applied inside `PlayerHostNSView` by sizing `playerLayer` to
`bounds × zoom` and offsetting it so the visible rect fills the view (the
iOS approach — content moves inside a static host — so event coordinates stay
trivially correct). The host layer masks to bounds. Window resize needs no
special handling: `layout()` re-derives the frame from the normalized state.

Momentum-phase scroll events (trackpad flicks still decaying after the
fingers lift) are filtered out in `scrollWheel` — they carry no new user
intent, so they neither zoom nor re-arm the minimap linger.

## Gesture capture

`PlayerHostNSView` (the existing AVPlayerLayer host) overrides `scrollWheel`,
`magnify`, `mouseDown/Dragged/Up` and reports via closures — the same pattern
the iOS `PlayerHostView` uses (`onInspection`). It reports:

- `onWheel(deltaY, anchor)` — anchor is the cursor as a 0…1 fraction of the
  view, top-left origin (AppKit's bottom-left y is flipped at the source).
- `onPinch(factor, anchor)` — `1 + event.magnification` per event.
- `onPan(dxFrac, dyFrac)` — drag deltas as fractions of the view.
- `onInteractionEnd()` — mouse up / pinch ended; drives the minimap linger.

The zoom state lives in `MainView` (`@State`), which decides policy: gestures
are ignored in Crop mode, pan only engages while zoomed.

## Minimap (faithful iOS port)

`Views/ZoomMinimap.swift` — near-verbatim port of the iOS view:

- **White frame:** `RoundedRectangle(cornerRadius: 6, style: .continuous)`,
  stroke `.white.opacity(0.5)` lineWidth 2.5, longest side **90pt**,
  aspect-matched to the displayed content. VideoClipper's preview composition
  applies the staged crop, so the aspect is `clip.previewAspect` (iOS used
  rotation-only aspect; here the preview really shows the crop).
- **Yellow box:** `RoundedRectangle(cornerRadius: 4, style: .continuous)`
  filled `.ultraThinMaterial` + `.yellow.opacity(0.4)` overlay +
  `.yellow` strokeBorder 2.5; sides `max(6, visible × frame)`, offset clamped
  inside the frame. `visible` is **video-space**, not canvas-space:
  `ZoomMath.videoViewport(canvasVisible:video:)` maps the canvas-normalized
  `visibleRect` onto the fitted video's rect (the iOS `inspectionViewport`
  math), so the box always reads as "this fraction of the video frame" even
  when the video is letterboxed against the canvas.
- **Widget:** `.shadow(color: .black.opacity(0.35), radius: 5, y: 2)`,
  `.animation(.smooth(duration: 0.3), value: displayedAspect)`, mounted
  top-leading with `.padding(14)`, `.allowsHitTesting(false)`.
- **Lifecycle (iOS semantics preserved):** the widget stays mounted (except in
  Crop mode) and is faded/scaled via a `minimapVisible` flag — so a quick
  re-engagement mid-dissolve reverses smoothly instead of popping from
  scratch. Shown (spring `response: 0.3, dampingFraction: 0.85`, scale
  0.5 ↔ 1 + fade) as soon as `zoom > 1.05` and the user interacts. Hidden
  only by the interaction ending: **0.2s** after mouse-up / pinch-end (a
  cancellable task, so re-engaging cancels the pending hide), and **0.6s**
  after the last wheel tick (a wheel has no release event).

## Components

1. **`Export/ZoomMath.swift`** — pure geometry beside `EditMath`
   (`nonisolated enum`, same file conventions): `State` (Equatable, with
   `.identity`), `visibleRect`, `zoom(_:anchor:factor:)` (shared by wheel and
   pinch, cursor-anchored, clamped), `wheelZoom` (exponential wrapper),
   `pan(_:dxFrac:dyFrac:)`.
2. **`VideoClipperTests/ZoomMathTests.swift`** — Swift Testing, mirroring
   `EditMathTests` style: identity, anchor invariance, clamping at both ends,
   exact identity on zoom-out, pan clamping.
3. **`Views/PlayerCanvasView.swift`** — `visibleRect` parameter + gesture
   closures on `PlayerCanvasView`/`PlayerHostNSView`; layer zoom in
   `applyZoom()`; `masksToBounds`.
4. **`Views/MainView.swift`** — `@State` zoom state, gesture policy closures,
   resets (clip switch / rotate / crop enter), minimap overlay + visibility
   tasks.
5. **`Views/ZoomMinimap.swift`** — the ported minimap view.

## Error handling

- Zero-size view or missing clip → gesture handlers no-op.
- All math clamps: zoom to [1, 8], pan/center so the visible rect never
  leaves the frame; zoom-out lands on exact identity.
- Playback continues while zoomed; the periodic time observer and trim strip
  are untouched.

## Out of scope

- Any effect on export/trim/crop/rotate math.
- Zoom UI chrome (buttons, sliders, percentage readout).
- Keyboard shortcuts, double-click reset.
- Persisting zoom per clip (always resets).
