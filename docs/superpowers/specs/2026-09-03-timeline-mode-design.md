# VideoClipper — Timeline mode (multi-layer compose: duplicate / reverse / trim / offset / z-order)

**Date:** 2026-09-03
**Status:** Approved (design)

## Goal

A new **Timeline** editor mode with AE-style basics on full-frame layers of the
selected clip: duplicate a layer, reverse it, trim each layer independently,
position layers on a master timeline, and reorder who's on top by drag. The
composed result plays live in the preview and exports as a single video.

## Decisions (settled with the user)

- **Overlap semantics:** top layer wins, full-frame. No PIP/opacity/transform
  compositing in v1.
- **Layer sources:** duplicates of the current clip only. Other bin clips as
  layers are out of scope for v1.
- **Audio:** the composed timeline is silent (preview and export).
- **Engine:** multi-track `AVMutableComposition` + `AVVideoComposition`
  per-region visibility instructions (approach B) — one track per layer, chosen
  over single-track flattening to leave headroom for opacity/PIP later.

## Model

```swift
struct TimelineLayer: Identifiable, Sendable {
    let id = UUID()
    var sourceIn: Double    // trim window, in the layer's own media time
    var sourceOut: Double   //   (reversed layers: in *reversed* media time, like AE)
    var start: Double       // position on the master timeline, seconds, ≥ 0
    var reversed = false
    var end: Double { start + (sourceOut - sourceIn) }
}
```

- `Clip.timelineLayers: [TimelineLayer]` — staged on the clip like every other
  edit (switching clips in the bin keeps it). **Array order is z-order**, last
  element = topmost.
- Empty array = no timeline. Entering Timeline mode seeds one layer from the
  staged trim (`sourceIn = trimStart`, `sourceOut = trimEnd`, `start = 0`).
  Leaving the mode with exactly that untouched single layer clears the array,
  so a clip without real timeline work keeps the plain export path.
- `Clip.reversedAsset: idle / rendering / ready(URL) / failed` — one reversed
  media file serves all reversed layers of the clip.
- `AppModel.Tool` gains `.timeline`; `AppModel.selectedLayerID: UUID?`.

### AppModel operations (all unit-testable)

- `enterTimeline()` — seeds the first layer when empty (from staged trim).
- `duplicateLayer(id)` — inserts a copy directly **above** the original (same
  start/trim), selects the copy.
- `deleteLayer(id)` — removes; clears selection if it pointed there.
- `moveLayer(id, toIndex)` — z-reorder.
- `setLayerStart(id, seconds)` — clamped ≥ 0.
- `trimLayer(id, sourceIn:/sourceOut:)` — clamped to media bounds, minimum
  layer length 0.2 s.
- `toggleReverse(id)` — flips `reversed` and **mirrors** the trim window
  (`in, out → D − out, D − in`, D = media duration) so the same content stays
  selected (AE time-reverse behavior). Kicks the reverse render when needed.
- Master duration (for the ruler scale and playback clamp):
  `max(layers.map(\.end).max(), source duration)`.

## Composition engine — `TimelineComposer`

Two halves; the first is pure and carries the correctness burden.

### Pure core: `regions(layers:) -> [Region]`

`Region = (start: Double, end: Double, topLayerIndex: Int?)`. Slice the master
timeline at every layer `start`/`end` boundary; within each region the visible
layer is the **highest array index whose span covers the region**; `nil` means
gap (renders black). Adjacent regions with the same winner merge. This function
is the single source of truth for what is on screen and is exhaustively
table-tested.

### AVFoundation half: `makeComposition(layers:, sourceURL:, reversedURL:?)`

Returns `(AVMutableComposition, AVMutableVideoComposition)`:

- One composition **video track per layer**; the layer's
  `[sourceIn, sourceOut]` range from its asset (original file, or the reversed
  file when `reversed` and ready) inserted at `start`.
- One `AVMutableVideoCompositionInstruction` per region: the visible layer's
  track at opacity 1, all other tracks at opacity 0; gap regions have no layer
  instructions and a black background.
- Every layer instruction carries the staged rotation/crop transform via the
  same `EditMath.rotation`/`applyCrop` math `ClipEditExporter` uses;
  `renderSize` comes from that geometry. Frame duration from the source track's
  nominal frame rate.
- A reversed layer whose render isn't ready yet uses the **forward** source
  (UI badges the row "reversing…"); the composition rebuilds when the file
  lands or fails.

The pair feeds **both** the preview `AVPlayerItem` and the export session.
Rebuilds are reference-only; during drags they are debounced (~50 ms) and the
player-item swap preserves the current playhead time.

## Reverse renderer — `ReverseRenderer`

- Video-only (timeline is silent). `AVAssetReader` collects the frame
  timestamps, then re-reads the movie in chunks from the tail and writes frames
  in reversed order with `AVAssetWriter` (H.264, source dimensions) — chunked so
  long recordings never hold all frames in memory.
- Output cached in the temp directory keyed by (source path, mtime); cache hit
  skips the render.
- Runs off-main; progress surfaces through `Clip.reversedAsset`. Failure shows
  the standard error alert and unsets `reversed` on the layers that needed it.

## UI — Timeline mode

- **Tool button** "Timeline" (`rectangle.stack`) beside Mark; corner dot when
  the clip has an active timeline.
- In this mode the trim strip + marker lane are replaced by:
  - **Ruler row** — time ticks across the master duration, shared playhead
    with grab knob, drag-to-scrub. The transport readout shows master-timeline
    time.
  - **Track stack** — one ~24 pt row per layer, **top row = topmost layer**.
    Each row draws a rounded bar from `start` to `end` scaled to the master
    duration:
    - drag the bar body → move `start`;
    - drag the left/right ~8 pt edge zones → trim `sourceIn`/`sourceOut`;
    - drag a row vertically past its neighbor → z-reorder;
    - click → select (highlight + `L2 · 3.4s` label).
  - **Layer actions** on the selected row's trailing edge: Duplicate, Reverse
    toggle (badge while rendering), Delete. Bare `⌫` deletes the selected
    layer in this mode (the existing stroke/clip delete shortcuts keep their
    modes).
- Preview always plays the composed result, so every edit is visible live.
- Entering the mode pauses/reset inspection zoom (same guard as Crop/Mark).

## Export & integration

- With an active timeline, `⌘S`/`⇧⌘S` export the composed timeline (silent,
  rotation/crop applied) through `AVAssetExportSession` with the existing
  `<base>-edit` never-overwrite naming. Without one, the existing single-clip
  path runs untouched. `hasEdits` includes "has active timeline".
- Frame handoff (`M`, notes, paint, `⌘E`) stays source-based and unaffected.
- The clip-level staged trim only seeds the first layer; inside Timeline mode
  layers own their trims.

## Testing

- **Pure:** `regions()` table tests — single layer; two overlapping (top
  wins); reorder flips the winner; gaps yield `nil` regions; adjacent
  boundaries don't create zero-width regions; same-winner regions merge.
  `toggleReverse` trim mirroring. Layer op clamps (start ≥ 0, min length,
  media bounds).
- **Integration (SampleClip.mov):** reverse render — output exists, duration ≈
  source, has a playable video track; composition builder — two overlapped
  layers give composition duration = max end and one instruction per region;
  composed export produces an mp4 of the expected duration.

## Out of scope (v1)

Opacity/PIP/transform compositing, cross-clip layers, audio, ripple/roll edit
tools, snapping, undo history for timeline edits.
