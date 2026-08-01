# Inspection Zoom + Schematic Minimap Implementation Plan (VideoClipper)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scroll-wheel (and pinch) zoom into the video canvas toward the cursor (1×–8×), drag to pan, with the iOS ClipShot `ZoomMinimap` ported as a corner overlay (white outline = whole frame, yellow box = visible area).

**Architecture:** Pure normalized zoom math in `Export/ZoomMath.swift` (tested with Swift Testing). Gestures captured in `PlayerHostNSView` (AppKit event overrides reporting via closures, the iOS `PlayerHostView` pattern); zoom rendered by sizing/offsetting the `AVPlayerLayer` inside its static host. Policy, state, resets, and the minimap overlay live in `MainView`.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`), SwiftUI + AppKit, macOS 15, XcodeGen (`.xcodeproj` is gitignored — run `xcodegen generate` after adding files). Tests: Swift Testing via `xcodebuild -scheme VideoClipper test`.

**Spec:** `docs/superpowers/specs/2026-08-02-inspection-zoom-design.md`

## Global Constraints

- Zoom range **1×–8×**; wheel factor `exp(deltaY * k)`, `k = 0.003` (constant `ZoomMath.wheelSensitivity`); positive deltaY = zoom in; non-precise (line-mode) wheel deltas scaled **×16** at the event source.
- Zooming out clamps to **exact identity** (`zoom == 1, cx == 0.5, cy == 0.5`).
- Pan and zoom always clamp so the visible rect stays inside the frame.
- Gestures ignored while `model.activeTool == .crop`; entering Crop resets zoom; zoom resets on clip switch and on rotate.
- Pan engages only while `zoom > 1`.
- Minimap (iOS `ZoomMinimap` values, verbatim): longest side **90pt**; white stroke `.white.opacity(0.5)` width 2.5, corner radius 6 continuous; yellow box `.ultraThinMaterial` + `.yellow.opacity(0.4)` fill + `.yellow` strokeBorder 2.5, corner radius 4 continuous, min side **6pt**, offset clamped inside the frame; shadow `.black.opacity(0.35), radius: 5, y: 2`; aspect change animated `.smooth(duration: 0.3)`.
- Minimap frame aspect = `clip.previewAspect` (preview shows the staged crop).
- Minimap lifecycle: mounted except in Crop mode; visible only while `zoom > 1.05` and interacting; pop = spring `response: 0.3, dampingFraction: 0.85`, `scaleEffect` 0.5 ↔ 1 + opacity 0 ↔ 1, `.padding(14)`, `.allowsHitTesting(false)`; hide **0.2s** after mouse-up/pinch-end, **0.6s** after the last wheel tick, via a cancellable `Task` (re-engaging cancels the pending hide).
- Viewing aid only: no changes to trim/crop/rotate/export logic.
- After creating any new source file, run `xcodegen generate` before building.
- Build: `xcodebuild -scheme VideoClipper build` (run from the repo root). Tests: `xcodebuild -scheme VideoClipper test`.

---

### Task 1: Zoom math (`ZoomMath.swift`)

**Files:**
- Create: `VideoClipper/Export/ZoomMath.swift`
- Test: `VideoClipperTests/ZoomMathTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 2–3):
  - `ZoomMath.State` — `struct { var zoom, cx, cy: CGFloat }`, `Equatable`, `static let identity` (zoom 1, center 0.5/0.5).
  - `ZoomMath.minZoom == 1`, `ZoomMath.maxZoom == 8`, `ZoomMath.wheelSensitivity == 0.003` (all `CGFloat`).
  - `ZoomMath.visibleRect(_ s: State) -> CGRect` — normalized visible region, top-left origin.
  - `ZoomMath.zoom(_ s: State, anchor: CGPoint, factor: CGFloat) -> State` — rescale about anchor (0…1 view fraction), clamped.
  - `ZoomMath.wheelZoom(_ s: State, anchor: CGPoint, deltaY: CGFloat) -> State` — `zoom` with `factor = exp(deltaY * wheelSensitivity)`.
  - `ZoomMath.pan(_ s: State, dxFrac: CGFloat, dyFrac: CGFloat) -> State` — content follows the drag, clamped.

- [ ] **Step 1: Write the failing tests**

Create `VideoClipperTests/ZoomMathTests.swift`:

```swift
//
//  ZoomMathTests.swift
//  VideoClipperTests
//

import CoreGraphics
import Foundation
import Testing
@testable import VideoClipper

struct ZoomMathTests {
    private func close(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool {
        abs(a - b) < eps
    }

    @Test func visibleRectIdentity() {
        #expect(ZoomMath.visibleRect(.identity) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func visibleRectAt2xCentered() {
        let r = ZoomMath.visibleRect(ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5))
        #expect(close(r.minX, 0.25) && close(r.minY, 0.25))
        #expect(close(r.width, 0.5) && close(r.height, 0.5))
    }

    @Test func wheelZoomInOnPositiveDelta() {
        let s = ZoomMath.wheelZoom(.identity, anchor: CGPoint(x: 0.5, y: 0.5), deltaY: 200)
        #expect(close(s.zoom, exp(200 * ZoomMath.wheelSensitivity)))
        #expect(close(s.cx, 0.5) && close(s.cy, 0.5))
    }

    @Test func zoomKeepsAnchorContentPointFixed() {
        let before = ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5)
        let anchor = CGPoint(x: 0.25, y: 0.75)
        let rb = ZoomMath.visibleRect(before)
        let px = rb.minX + anchor.x * rb.width
        let py = rb.minY + anchor.y * rb.height
        let after = ZoomMath.zoom(before, anchor: anchor, factor: 1.35) // stays clear of the clamps
        let ra = ZoomMath.visibleRect(after)
        #expect(close(ra.minX + anchor.x * ra.width, px))
        #expect(close(ra.minY + anchor.y * ra.height, py))
    }

    @Test func zoomClampsAtMax() {
        let s = ZoomMath.zoom(
            ZoomMath.State(zoom: 7.9, cx: 0.5, cy: 0.5),
            anchor: CGPoint(x: 0.5, y: 0.5),
            factor: 100
        )
        #expect(s.zoom == ZoomMath.maxZoom)
    }

    @Test func zoomOutReturnsToExactIdentity() {
        let s = ZoomMath.zoom(
            ZoomMath.State(zoom: 1.3, cx: 0.4, cy: 0.6),
            anchor: CGPoint(x: 0.1, y: 0.1),
            factor: 0.01
        )
        #expect(s == .identity)
    }

    @Test func panShiftsOppositeTheDragScaledByZoom() {
        let s = ZoomMath.pan(ZoomMath.State(zoom: 4, cx: 0.5, cy: 0.5), dxFrac: 0.1, dyFrac: -0.2)
        #expect(close(s.cx, 0.5 - 0.1 / 4))
        #expect(close(s.cy, 0.5 + 0.2 / 4))
    }

    @Test func panClampsAtTheEdges() {
        let s = ZoomMath.pan(ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5), dxFrac: 5, dyFrac: 5)
        let r = ZoomMath.visibleRect(s)
        #expect(close(s.cx, 0.25) && close(s.cy, 0.25))
        #expect(close(r.minX, 0) && close(r.minY, 0))
    }

    @Test func panAt1xStaysCentered() {
        #expect(ZoomMath.pan(.identity, dxFrac: 0.3, dyFrac: 0.3) == .identity)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme VideoClipper test` (from the repo root; run `xcodegen generate` first so the new test file is in the project)
Expected: BUILD FAILURE — `cannot find 'ZoomMath' in scope`. (Compile failure is this stack's red step; Swift can't run tests against missing types.)

- [ ] **Step 3: Write the implementation**

Create `VideoClipper/Export/ZoomMath.swift`:

```swift
//
//  ZoomMath.swift
//  VideoClipper
//
//  Pure geometry for the inspection zoom (a viewing aid — never part of the
//  export). State is normalized: zoom in [1, 8], (cx, cy) = center of the
//  visible region in 0…1 canvas coordinates with a top-left origin.
//

import CoreGraphics
import Foundation

nonisolated enum ZoomMath {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 8
    static let wheelSensitivity: CGFloat = 0.003

    struct State: Equatable {
        var zoom: CGFloat
        var cx: CGFloat
        var cy: CGFloat

        static let identity = State(zoom: 1, cx: 0.5, cy: 0.5)
    }

    /// Normalized visible region (top-left origin) for a state.
    static func visibleRect(_ s: State) -> CGRect {
        let w = 1 / s.zoom
        return CGRect(x: s.cx - w / 2, y: s.cy - w / 2, width: w, height: w)
    }

    /// Rescale about `anchor` (cursor as a 0…1 fraction of the view): the
    /// content point under the anchor stays put. Shared by wheel and pinch.
    static func zoom(_ s: State, anchor: CGPoint, factor: CGFloat) -> State {
        let newZoom = min(maxZoom, max(minZoom, s.zoom * factor))
        let r = visibleRect(s)
        let px = r.minX + anchor.x * r.width
        let py = r.minY + anchor.y * r.height
        let w = 1 / newZoom
        return clamped(State(zoom: newZoom, cx: px - anchor.x * w + w / 2, cy: py - anchor.y * w + w / 2))
    }

    /// Wheel step: exponential in the scroll delta, positive = zoom in.
    static func wheelZoom(_ s: State, anchor: CGPoint, deltaY: CGFloat) -> State {
        zoom(s, anchor: anchor, factor: exp(deltaY * wheelSensitivity))
    }

    /// Pan by a drag expressed as fractions of the view; the content follows
    /// the cursor, so the visible window moves opposite the drag, scaled by
    /// 1/zoom.
    static func pan(_ s: State, dxFrac: CGFloat, dyFrac: CGFloat) -> State {
        clamped(State(zoom: s.zoom, cx: s.cx - dxFrac / s.zoom, cy: s.cy - dyFrac / s.zoom))
    }

    /// Keeps the visible rect inside the frame. At zoom 1 the only valid
    /// center is (0.5, 0.5), which is what makes zoom-out land on identity.
    private static func clamped(_ s: State) -> State {
        let half = 1 / (2 * s.zoom)
        func clamp(_ v: CGFloat) -> CGFloat { min(1 - half, max(half, v)) }
        return State(zoom: s.zoom, cx: clamp(s.cx), cy: clamp(s.cy))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -scheme VideoClipper test`
Expected: TEST SUCCEEDED — all `ZoomMathTests` and existing `EditMathTests` pass. (`ExporterIntegrationTests` require a fixture video; if they were failing before this change, note it, but they must be no worse.)

- [ ] **Step 5: Commit**

```bash
git add VideoClipper/Export/ZoomMath.swift VideoClipperTests/ZoomMathTests.swift
git commit -m "Inspection zoom: pure zoom math (wheel/pinch zoom, pan, visible rect) + tests"
```

---

### Task 2: Gesture capture + layer zoom + resets

**Files:**
- Modify: `VideoClipper/Views/PlayerCanvasView.swift` (full-file replacement below)
- Modify: `VideoClipper/Views/MainView.swift` (canvas section + resets)

**Interfaces:**
- Consumes: `ZoomMath` from Task 1.
- Produces (used by Task 3):
  - `PlayerCanvasView(player:visibleRect:onWheel:onPinch:onPan:onInteractionEnd:)` — closures as listed below.
  - `MainView.zoomState: ZoomMath.State` (`@State`) and gesture closures in `canvas` where Task 3 adds minimap calls.

- [ ] **Step 1: Replace `VideoClipper/Views/PlayerCanvasView.swift`**

Full new contents:

```swift
//
//  PlayerCanvasView.swift
//  VideoClipper
//
//  Plays video through an AVPlayerLayer (no system controls — the trim strip is the only
//  scrubber). Rotation and staged crops are previewed via AVPlayerItem.videoComposition,
//  so the layer itself stays untransformed and `resizeAspect` handles the fitting.
//
//  Inspection zoom: the host view also captures wheel/pinch/drag events (reported via
//  closures — policy lives in MainView) and renders the zoom by sizing the player layer
//  to bounds × zoom and offsetting it so `visibleRect` fills the view. The host clips.
//

@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct PlayerCanvasView: NSViewRepresentable {
    let player: AVPlayer
    var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var onWheel: ((_ deltaY: CGFloat, _ anchor: CGPoint) -> Void)?
    var onPinch: ((_ factor: CGFloat, _ anchor: CGPoint) -> Void)?
    var onPan: ((_ dxFrac: CGFloat, _ dyFrac: CGFloat) -> Void)?
    var onInteractionEnd: (() -> Void)?

    func makeNSView(context: Context) -> PlayerHostNSView {
        let view = PlayerHostNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.onWheel = onWheel
        nsView.onPinch = onPinch
        nsView.onPan = onPan
        nsView.onInteractionEnd = onInteractionEnd
        nsView.visibleRect = visibleRect
    }
}

final class PlayerHostNSView: NSView {
    let playerLayer = AVPlayerLayer()

    var onWheel: ((CGFloat, CGPoint) -> Void)?
    var onPinch: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onInteractionEnd: (() -> Void)?

    /// Normalized (0…1, top-left origin) region of the canvas to show. Full rect = no zoom.
    var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { if visibleRect != oldValue { applyZoom() } }
    }

    private var lastDragPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        applyZoom()
    }

    /// Sizes the player layer to bounds × zoom and offsets it so `visibleRect` fills the
    /// view. AppKit layer coordinates have a bottom-left origin, hence the maxY flip.
    private func applyZoom() {
        let zoom = 1 / max(visibleRect.width, 0.001)
        let w = bounds.width * zoom
        let h = bounds.height * zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = CGRect(x: -visibleRect.minX * w, y: -(1 - visibleRect.maxY) * h, width: w, height: h)
        CATransaction.commit()
    }

    /// Cursor position as a 0…1 fraction of the view, top-left origin.
    private func anchor(for event: NSEvent) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / bounds.width, y: 1 - p.y / bounds.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onWheel, let anchor = anchor(for: event) else {
            super.scrollWheel(with: event)
            return
        }
        var deltaY = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { deltaY *= 16 }
        onWheel(deltaY, anchor)
    }

    override func magnify(with event: NSEvent) {
        guard let onPinch, let anchor = anchor(for: event) else {
            super.magnify(with: event)
            return
        }
        onPinch(1 + event.magnification, anchor)
        if event.phase == .ended || event.phase == .cancelled { onInteractionEnd?() }
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint, bounds.width > 0, bounds.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        // View y grows upward; the pan math expects top-left-origin deltas.
        onPan?((p.x - last.x) / bounds.width, -(p.y - last.y) / bounds.height)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        onInteractionEnd?()
    }
}
```

- [ ] **Step 2: Wire state, policy, and resets in `MainView.swift`**

In `struct MainView`, add a state property under `@State private var isDropTargeted = false`:

```swift
    /// Inspection-zoom state for the canvas — a viewing aid, reset on clip
    /// switch, rotation, and entering Crop. Never touches the staged edits.
    @State private var zoomState = ZoomMath.State.identity
```

In `private var canvas`, replace:

```swift
                if let clip = model.selectedClip, clip.isLoaded {
                    PlayerCanvasView(player: model.player)
```

with:

```swift
                if let clip = model.selectedClip, clip.isLoaded {
                    PlayerCanvasView(
                        player: model.player,
                        visibleRect: ZoomMath.visibleRect(zoomState),
                        onWheel: { deltaY, anchor in
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.wheelZoom(zoomState, anchor: anchor, deltaY: deltaY)
                        },
                        onPinch: { factor, anchor in
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.zoom(zoomState, anchor: anchor, factor: factor)
                        },
                        onPan: { dxFrac, dyFrac in
                            guard model.activeTool != .crop, zoomState.zoom > 1 else { return }
                            zoomState = ZoomMath.pan(zoomState, dxFrac: dxFrac, dyFrac: dyFrac)
                        },
                        onInteractionEnd: {}
                    )
```

On the canvas `GeometryReader` (in `private var canvas`, after `.frame(maxWidth: .infinity, maxHeight: .infinity)`), add the resets:

```swift
        .onChange(of: model.selectedClipID) { zoomState = .identity }
        .onChange(of: model.selectedClip?.rotationQuarters) { zoomState = .identity }
        .onChange(of: model.activeTool) {
            if model.activeTool == .crop { zoomState = .identity }
        }
```

- [ ] **Step 3: Build and run the test suite**

Run: `xcodebuild -scheme VideoClipper build && xcodebuild -scheme VideoClipper test`
Expected: BUILD SUCCEEDED; TEST SUCCEEDED (no regressions — this task adds no new tests; the zoom behavior is covered by Task 1's math tests and manual verification).

- [ ] **Step 4: Manual verification (launch the app)**

Launch the built app with a test video. Verify:

1. Scroll up over the canvas zooms in toward the cursor; scroll down zooms out; fully out = exactly the normal fitted view. (If scroll direction feels inverted, flip the sign at the single call site `exp(deltaY * wheelSensitivity)` — note it in the report.)
2. Trackpad pinch zooms toward the pointer.
3. While zoomed: left-drag pans; the image never reveals blank margins; playback continues normally.
4. Crop mode: entering Crop resets to 1×; wheel/pinch/drag do not zoom while cropping (the crop overlay still works).
5. Trim mode: zoom works.
6. Switching clips or rotating resets to 1×.
7. Resizing the window while zoomed keeps the zoomed view consistent (no jumps).

- [ ] **Step 5: Commit**

```bash
git add VideoClipper/Views/PlayerCanvasView.swift VideoClipper/Views/MainView.swift
git commit -m "Inspection zoom: wheel/pinch zoom + drag pan on the canvas"
```

---

### Task 3: Schematic minimap (iOS `ZoomMinimap` port)

**Files:**
- Create: `VideoClipper/Views/ZoomMinimap.swift`
- Modify: `VideoClipper/Views/MainView.swift` (minimap overlay + visibility)

**Interfaces:**
- Consumes: `zoomState`, the gesture closures from Task 2, `ZoomMath.visibleRect`, `clip.previewAspect`.
- Produces: user-facing minimap; no downstream consumers.

- [ ] **Step 1: Create `VideoClipper/Views/ZoomMinimap.swift`**

Near-verbatim port of the iOS ClipShot view (`15_ClipShot/GestureRecognition/ClipEditorView.swift`, `ZoomMinimap`):

```swift
//
//  ZoomMinimap.swift
//  VideoClipper
//
//  Corner zoom navigator, ported from the iOS ClipShot editor. White outline = the
//  whole video frame (aspect-matched); yellow box = the part currently on screen.
//

import SwiftUI

struct ZoomMinimap: View {
    let displayedAspect: CGFloat   // w/h of the displayed (rotation+crop-adjusted) video
    let visible: CGRect            // visible region, normalized 0…1

    /// Longest side of the white frame.
    private let maxSide: CGFloat = 90

    private var frameSize: CGSize {
        let a = max(0.01, displayedAspect)
        return a >= 1
            ? CGSize(width: maxSide, height: maxSide / a)
            : CGSize(width: maxSide * a, height: maxSide)
    }

    var body: some View {
        let f = frameSize
        let yellowW = max(6, visible.width * f.width)
        let yellowH = max(6, visible.height * f.height)
        let offX = min(max(0, visible.minX * f.width), f.width - yellowW)
        let offY = min(max(0, visible.minY * f.height), f.height - yellowH)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.5), lineWidth: 2.5)
                .frame(width: f.width, height: f.height)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)                                   // ~frosted backdrop blur
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.yellow.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.yellow, lineWidth: 2.5))
                .frame(width: yellowW, height: yellowH)
                .offset(x: offX, y: offY)
        }
        .frame(width: f.width, height: f.height)
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .animation(.smooth(duration: 0.3), value: displayedAspect)
    }
}
```

- [ ] **Step 2: Add visibility state and helpers to `MainView.swift`**

Under the `zoomState` property, add:

```swift
    /// True while the wheel/pinch/drag is engaging the zoom — the minimap is only up
    /// while interacting, with a short linger after release (iOS ClipShot semantics).
    @State private var minimapVisible = false
    @State private var minimapHideTask: Task<Void, Never>?
    /// Pop animation for the navigator — gentle, low overshoot.
    private let minimapSpring: Animation = .spring(response: 0.3, dampingFraction: 0.85)
```

Below `private var dropHint` (same level), add:

```swift
    /// Show the minimap now (if actually zoomed in); optionally schedule a hide —
    /// wheel events have no "release", so each tick re-arms a 0.6s linger.
    private func minimapEngaged(hideAfter delay: Double?) {
        minimapHideTask?.cancel()
        if zoomState.zoom > 1.05 {
            withAnimation(minimapSpring) { minimapVisible = true }
        }
        if let delay { minimapScheduleHide(after: delay) }
    }

    /// Hide with a linger; a quick re-engagement cancels the pending hide, so the
    /// pop reverses smoothly mid-dissolve instead of restarting.
    private func minimapScheduleHide(after delay: Double) {
        minimapHideTask?.cancel()
        minimapHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(minimapSpring) { minimapVisible = false }
        }
    }
```

- [ ] **Step 3: Wire the gesture closures and overlay in `canvas`**

In the `PlayerCanvasView` initializer from Task 2, make each closure drive the minimap — replace the four closures with:

```swift
                        onWheel: { deltaY, anchor in
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.wheelZoom(zoomState, anchor: anchor, deltaY: deltaY)
                            minimapEngaged(hideAfter: 0.6)
                        },
                        onPinch: { factor, anchor in
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.zoom(zoomState, anchor: anchor, factor: factor)
                            minimapEngaged(hideAfter: nil)
                        },
                        onPan: { dxFrac, dyFrac in
                            guard model.activeTool != .crop, zoomState.zoom > 1 else { return }
                            zoomState = ZoomMath.pan(zoomState, dxFrac: dxFrac, dyFrac: dyFrac)
                            minimapEngaged(hideAfter: nil)
                        },
                        onInteractionEnd: { minimapScheduleHide(after: 0.2) }
```

On the canvas `ZStack` (inside the `GeometryReader`, after the closing brace of the `ZStack`), add the overlay — kept mounted outside Crop mode and faded/scaled via `minimapVisible`, so a quick re-touch mid-dissolve reverses smoothly (iOS semantics):

```swift
            .overlay(alignment: .topLeading) {
                if model.activeTool != .crop, let clip = model.selectedClip, clip.isLoaded {
                    ZoomMinimap(displayedAspect: clip.previewAspect, visible: ZoomMath.visibleRect(zoomState))
                        .scaleEffect(minimapVisible ? 1 : 0.5)
                        .opacity(minimapVisible ? 1 : 0)
                        .padding(14)
                        .allowsHitTesting(false)
                        .animation(minimapSpring, value: minimapVisible)
                }
            }
```

Extend the resets from Task 2 so a reset also drops the minimap — replace the three `.onChange` modifiers with:

```swift
        .onChange(of: model.selectedClipID) { resetZoom() }
        .onChange(of: model.selectedClip?.rotationQuarters) { resetZoom() }
        .onChange(of: model.activeTool) {
            if model.activeTool == .crop { resetZoom() }
        }
```

and add below `minimapScheduleHide`:

```swift
    private func resetZoom() {
        zoomState = .identity
        minimapHideTask?.cancel()
        minimapVisible = false
    }
```

- [ ] **Step 4: Build and run the test suite**

Run: `xcodegen generate && xcodebuild -scheme VideoClipper build && xcodebuild -scheme VideoClipper test`
Expected: BUILD SUCCEEDED; TEST SUCCEEDED.

- [ ] **Step 5: Manual verification (launch the app)**

1. Zoom in with the wheel: the minimap pops in at the canvas's top-left (scale 0.5→1 + fade), white outline matching the video's aspect, yellow blurred box showing the visible area.
2. The yellow box tracks zoom (shrinks as you zoom in) and pan (moves with drag), never leaving the white frame.
3. Stop wheeling: the minimap fades out ~0.6s after the last tick. Release a drag: fades ~0.2s after mouse-up; stays up continuously mid-drag.
4. Re-engage mid-fade: the pop reverses smoothly (no restart).
5. Rotate a clip (or crop one, commit, and zoom): the white frame's aspect matches what the preview shows.
6. Crop mode: no minimap; leaving Crop and zooming brings it back.

- [ ] **Step 6: Commit**

```bash
git add VideoClipper/Views/ZoomMinimap.swift VideoClipper/Views/MainView.swift
git commit -m "Inspection zoom: schematic minimap ported from iOS ClipShot"
```
