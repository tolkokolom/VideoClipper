# Timeline Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Timeline editor mode composing full-frame layers of the selected clip — duplicate / reverse / trim / offset / z-reorder — with live composed preview and single-video export.

**Architecture:** Multi-track `AVMutableComposition` (one video track per layer) + `AVMutableVideoComposition` per-region visibility instructions (top layer opacity 1, others 0). A pure `regions()` function is the single source of truth for visibility. Reversed layers use a background-pre-rendered reversed file, cached per source. The (composition, videoComposition) pair feeds both preview and export.

**Tech Stack:** Swift 6 (default MainActor isolation — engine types must be `nonisolated`), SwiftUI, AVFoundation, Swift Testing (`@Test`/`#expect`), xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-03-timeline-mode-design.md`

## Global Constraints

- macOS 15 deployment; project uses `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — every engine/enum used from async export paths is declared `nonisolated`.
- After creating any new file: run `xcodegen generate` before building (the .xcodeproj is generated and gitignored).
- Test command: `xcodebuild -scheme VideoClipper test` (filter noise: append `2>&1 | grep -E "Test run with|TEST|error:"`).
- Timeline compositions are **silent** — never add audio tracks.
- Never reference the user's absolute paths in code; tests copy `SampleClip.mov` from the bundle to temp when they need a file on disk.
- Work on branch `feat/timeline-mode` off `main`.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: TimelineLayer model + pure `regions()` core

**Files:**
- Create: `VideoClipper/Models/TimelineLayer.swift`
- Create: `VideoClipper/Export/TimelineComposer.swift` (pure part only)
- Test: `VideoClipperTests/TimelineComposerTests.swift`

**Interfaces:**
- Produces: `struct TimelineLayer` (`id: UUID`, `sourceIn/sourceOut/start: Double`, `reversed: Bool`, `end: Double`), `enum ReversedAssetState`, `struct TimelineRegion` (`start/end: Double`, `topLayerIndex: Int?`), `TimelineComposer.regions(layers:) -> [TimelineRegion]`.

- [ ] **Step 1: Create branch**

```bash
git checkout -b feat/timeline-mode main
```

- [ ] **Step 2: Write the failing tests**

Create `VideoClipperTests/TimelineComposerTests.swift`:

```swift
//
//  TimelineComposerTests.swift
//  VideoClipperTests
//
//  Pure visibility flattening for the timeline: regions() slices the master
//  timeline at layer boundaries and names the topmost covering layer per slice.
//

import Foundation
import Testing
@testable import VideoClipper

struct TimelineComposerTests {
    private func layer(_ start: Double, in sourceIn: Double, out sourceOut: Double) -> TimelineLayer {
        TimelineLayer(sourceIn: sourceIn, sourceOut: sourceOut, start: start)
    }

    @Test func emptyLayersYieldNoRegions() {
        #expect(TimelineComposer.regions(layers: []).isEmpty)
    }

    @Test func singleLayerCoversItsSpan() {
        let regions = TimelineComposer.regions(layers: [layer(0, in: 0, out: 3)])
        #expect(regions == [TimelineRegion(start: 0, end: 3, topLayerIndex: 0)])
    }

    @Test func topLayerWinsDuringOverlap() {
        let regions = TimelineComposer.regions(layers: [
            layer(0, in: 0, out: 4),     // index 0, spans 0–4
            layer(2, in: 0, out: 4),     // index 1 (top), spans 2–6
        ])
        #expect(regions == [
            TimelineRegion(start: 0, end: 2, topLayerIndex: 0),
            TimelineRegion(start: 2, end: 6, topLayerIndex: 1),
        ])
    }

    @Test func reorderingFlipsTheWinner() {
        let regions = TimelineComposer.regions(layers: [
            layer(2, in: 0, out: 4),     // index 0 (bottom), spans 2–6
            layer(0, in: 0, out: 4),     // index 1 (top), spans 0–4
        ])
        #expect(regions == [
            TimelineRegion(start: 0, end: 4, topLayerIndex: 1),
            TimelineRegion(start: 4, end: 6, topLayerIndex: 0),
        ])
    }

    @Test func gapsBeforeAndBetweenLayersAreNilRegions() {
        let regions = TimelineComposer.regions(layers: [
            layer(1, in: 0, out: 1),     // spans 1–2
            layer(3, in: 0, out: 1),     // spans 3–4
        ])
        #expect(regions == [
            TimelineRegion(start: 0, end: 1, topLayerIndex: nil),
            TimelineRegion(start: 1, end: 2, topLayerIndex: 0),
            TimelineRegion(start: 2, end: 3, topLayerIndex: nil),
            TimelineRegion(start: 3, end: 4, topLayerIndex: 1),
        ])
    }

    @Test func adjacentLayersProduceNoZeroWidthRegions() {
        let regions = TimelineComposer.regions(layers: [
            layer(0, in: 0, out: 2),     // spans 0–2
            layer(2, in: 0, out: 2),     // spans 2–4
        ])
        #expect(regions == [
            TimelineRegion(start: 0, end: 2, topLayerIndex: 0),
            TimelineRegion(start: 2, end: 4, topLayerIndex: 1),
        ])
    }

    @Test func sameWinnerRegionsMerge() {
        // A short bottom layer fully inside the top layer's span must not split
        // the top layer's region into three.
        let regions = TimelineComposer.regions(layers: [
            layer(1, in: 0, out: 1),     // index 0, spans 1–2, fully covered
            layer(0, in: 0, out: 4),     // index 1 (top), spans 0–4
        ])
        #expect(regions == [TimelineRegion(start: 0, end: 4, topLayerIndex: 1)])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
xcodebuild -scheme VideoClipper test 2>&1 | grep -E "error:" | sort -u | head -5
```
Expected: compile errors — `cannot find 'TimelineLayer'`, `cannot find 'TimelineComposer'`. (No xcodegen yet — the test file itself is new, so run `xcodegen generate` first, then the test build fails on the missing types.)

- [ ] **Step 4: Implement the model and the pure core**

Create `VideoClipper/Models/TimelineLayer.swift`:

```swift
//
//  TimelineLayer.swift
//  VideoClipper
//
//  One full-frame layer on the Timeline-mode master timeline. Array order on
//  Clip.timelineLayers is z-order (last = topmost). sourceIn/out are in the
//  layer's own media time — for reversed layers that is *reversed* media time,
//  like AE's time-reverse.
//

import Foundation

struct TimelineLayer: Identifiable, Sendable {
    let id = UUID()
    var sourceIn: Double
    var sourceOut: Double
    var start: Double
    var reversed = false

    var end: Double { start + (sourceOut - sourceIn) }
}

/// One reversed media file per clip serves all its reversed layers.
enum ReversedAssetState {
    case idle
    case rendering
    case ready(URL)
    case failed

    var readyURL: URL? { if case .ready(let url) = self { url } else { nil } }
    var isRendering: Bool { if case .rendering = self { true } else { false } }
}
```

Create `VideoClipper/Export/TimelineComposer.swift`:

```swift
//
//  TimelineComposer.swift
//  VideoClipper
//
//  Timeline-mode engine. The pure regions() function is the single source of
//  truth for what is visible when: it slices the master timeline at every layer
//  boundary and names the topmost covering layer per slice (nil = gap → black).
//

import Foundation

/// One slice of the master timeline with a single visible layer (or none).
struct TimelineRegion: Equatable, Sendable {
    var start: Double
    var end: Double
    /// Index into the layers array; nil renders black.
    var topLayerIndex: Int?
}

nonisolated enum TimelineComposer {
    static func regions(layers: [TimelineLayer]) -> [TimelineRegion] {
        guard !layers.isEmpty else { return [] }
        var bounds: Set<Double> = [0]
        for layer in layers where layer.end > layer.start {
            bounds.insert(layer.start)
            bounds.insert(layer.end)
        }
        let sorted = bounds.sorted()
        var regions: [TimelineRegion] = []
        for (sliceStart, sliceEnd) in zip(sorted, sorted.dropFirst()) where sliceEnd - sliceStart > 1e-9 {
            let mid = (sliceStart + sliceEnd) / 2
            let top = layers.lastIndex { $0.start <= mid && $0.end >= mid && $0.end > $0.start }
            if var last = regions.last, last.topLayerIndex == top {
                last.end = sliceEnd
                regions[regions.count - 1] = last
            } else {
                regions.append(TimelineRegion(start: sliceStart, end: sliceEnd, topLayerIndex: top))
            }
        }
        return regions
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
xcodegen generate && xcodebuild -scheme VideoClipper test 2>&1 | grep -E "Test run with|error:" | head -3
```
Expected: all tests pass (76 existing + 7 new).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Timeline mode: layer model + pure regions() visibility core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Clip storage + AppModel layer operations

**Files:**
- Modify: `VideoClipper/Models/Clip.swift` (add two stored properties + two computed)
- Modify: `VideoClipper/Models/AppModel.swift` (Tool case + layer ops)
- Test: `VideoClipperTests/AppModelTests.swift` (append)

**Interfaces:**
- Consumes: `TimelineLayer`, `ReversedAssetState` (Task 1).
- Produces: `Clip.timelineLayers: [TimelineLayer]`, `Clip.reversedAsset: ReversedAssetState`, `Clip.hasActiveTimeline: Bool`, `AppModel.Tool.timeline`, `AppModel.selectedLayerID: TimelineLayer.ID?`, `AppModel.masterDuration: Double`, and ops `enterTimeline() / duplicateLayer(_:) / deleteLayer(_:) / deleteSelectedLayer() / moveLayer(_:toIndex:) / setLayerStart(_:seconds:) / trimLayer(_:sourceIn:sourceOut:) / toggleReverse(_:) / pruneTrivialTimeline()`. `minLayerLength = 0.2`.

- [ ] **Step 1: Write the failing tests** — append to `VideoClipperTests/AppModelTests.swift` before the `// MARK: - Frame handoff export` section:

```swift
    // MARK: - Timeline layers

    /// Clip with duration 10 and a staged trim 1…9, timeline mode entered.
    private func timelineModel() -> AppModel {
        let model = modelWithClip()
        model.selectedClip?.trimStart = 1
        model.selectedClip?.trimEnd = 9
        model.enterTimeline()
        return model
    }

    @Test func enterTimelineSeedsOneLayerFromTheStagedTrim() {
        let model = timelineModel()
        let layers = model.selectedClip?.timelineLayers
        #expect(layers?.count == 1)
        #expect(layers?.first?.sourceIn == 1)
        #expect(layers?.first?.sourceOut == 9)
        #expect(layers?.first?.start == 0)
        #expect(model.selectedLayerID == layers?.first?.id)
    }

    @Test func duplicateInsertsAboveAndSelectsTheCopy() throws {
        let model = timelineModel()
        let original = try #require(model.selectedClip?.timelineLayers.first)
        model.duplicateLayer(original.id)
        let layers = try #require(model.selectedClip?.timelineLayers)
        #expect(layers.count == 2)
        #expect(layers[0].id == original.id)
        #expect(layers[1].id != original.id)
        #expect(layers[1].sourceIn == original.sourceIn && layers[1].start == original.start)
        #expect(model.selectedLayerID == layers[1].id)
    }

    @Test func deleteLayerClearsItsSelection() throws {
        let model = timelineModel()
        let layer = try #require(model.selectedClip?.timelineLayers.first)
        model.deleteLayer(layer.id)
        #expect(model.selectedClip?.timelineLayers.isEmpty == true)
        #expect(model.selectedLayerID == nil)
    }

    @Test func moveLayerReordersZ() throws {
        let model = timelineModel()
        let bottom = try #require(model.selectedClip?.timelineLayers.first)
        model.duplicateLayer(bottom.id)
        model.moveLayer(bottom.id, toIndex: 1)
        #expect(model.selectedClip?.timelineLayers.last?.id == bottom.id)
    }

    @Test func layerStartAndTrimClampToLegalRanges() throws {
        let model = timelineModel()
        let layer = try #require(model.selectedClip?.timelineLayers.first)
        model.setLayerStart(layer.id, seconds: -3)
        #expect(model.selectedClip?.timelineLayers.first?.start == 0)
        model.trimLayer(layer.id, sourceIn: -1, sourceOut: 99)
        #expect(model.selectedClip?.timelineLayers.first?.sourceIn == 0)
        #expect(model.selectedClip?.timelineLayers.first?.sourceOut == 10)
        model.trimLayer(layer.id, sourceIn: 9.95, sourceOut: nil)   // would leave < 0.2 s
        let trimmed = try #require(model.selectedClip?.timelineLayers.first)
        #expect(trimmed.sourceOut - trimmed.sourceIn >= model.minLayerLength - 1e-9)
    }

    @Test func toggleReverseMirrorsTheTrimWindow() throws {
        let model = timelineModel()
        let layer = try #require(model.selectedClip?.timelineLayers.first)   // in 1, out 9, D = 10
        model.toggleReverse(layer.id)
        let reversed = try #require(model.selectedClip?.timelineLayers.first)
        #expect(reversed.reversed)
        #expect(reversed.sourceIn == 1)    // 10 − 9
        #expect(reversed.sourceOut == 9)   // 10 − 1
        model.toggleReverse(layer.id)
        #expect(model.selectedClip?.timelineLayers.first?.reversed == false)
    }

    @Test func pruneClearsOnlyTheTrivialSeedTimeline() throws {
        let model = timelineModel()
        model.pruneTrivialTimeline()
        #expect(model.selectedClip?.timelineLayers.isEmpty == true)

        model.enterTimeline()
        let layer = try #require(model.selectedClip?.timelineLayers.first)
        model.setLayerStart(layer.id, seconds: 2)
        model.pruneTrivialTimeline()
        #expect(model.selectedClip?.timelineLayers.count == 1)
    }

    @Test func masterDurationIsMaxOfLayerEndsAndSourceDuration() throws {
        let model = timelineModel()
        let layer = try #require(model.selectedClip?.timelineLayers.first)
        #expect(model.masterDuration == 10)          // clip duration dominates (8 s layer)
        model.setLayerStart(layer.id, seconds: 5)    // layer now ends at 13
        #expect(model.masterDuration == 13)
    }
```

- [ ] **Step 2: Run to verify failure** — expected compile errors: `no member 'enterTimeline'`, `no member 'timelineLayers'`, etc.

- [ ] **Step 3: Implement**

In `VideoClipper/Models/Clip.swift`, after `var markers: [FrameMarker] = []` add:

```swift
    /// Timeline-mode layers; array order is z-order (last = topmost). Empty =
    /// no timeline. Staged like every other edit.
    var timelineLayers: [TimelineLayer] = []
    var reversedAsset: ReversedAssetState = .idle
```

After `var hasEdits` add `var hasActiveTimeline: Bool { !timelineLayers.isEmpty }` and change `hasEdits` to `{ isTrimmed || isCropped || isRotated || hasActiveTimeline }`.

In `VideoClipper/Models/AppModel.swift`: change the enum to `enum Tool { case trim, crop, marker, timeline }`, add near the other selection state:

```swift
    /// Timeline mode: the layer selected for editing.
    var selectedLayerID: TimelineLayer.ID?
    let minLayerLength = 0.2
```

Add a new section before `// MARK: - Tools`:

```swift
    // MARK: - Timeline layers

    /// Ruler scale and playback ceiling for Timeline mode.
    var masterDuration: Double {
        guard let clip = selectedClip else { return 0 }
        return max(clip.timelineLayers.map(\.end).max() ?? 0, clip.duration)
    }

    /// First entry seeds a single layer from the staged trim.
    func enterTimeline() {
        guard let clip = selectedClip else { return }
        if clip.timelineLayers.isEmpty {
            clip.timelineLayers = [
                TimelineLayer(sourceIn: clip.trimStart, sourceOut: clip.trimEnd, start: 0)
            ]
        }
        selectedLayerID = clip.timelineLayers.last?.id
    }

    /// Leaving the mode with just the untouched seed layer clears the timeline,
    /// so a clip without real timeline work keeps the plain export path.
    func pruneTrivialTimeline() {
        guard let clip = selectedClip, clip.timelineLayers.count == 1,
              let layer = clip.timelineLayers.first, !layer.reversed,
              abs(layer.start) < 1e-9,
              abs(layer.sourceIn - clip.trimStart) < 1e-9,
              abs(layer.sourceOut - clip.trimEnd) < 1e-9 else { return }
        clip.timelineLayers = []
        selectedLayerID = nil
    }

    private func layerIndex(_ id: TimelineLayer.ID) -> Int? {
        selectedClip?.timelineLayers.firstIndex { $0.id == id }
    }

    func duplicateLayer(_ id: TimelineLayer.ID) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        let source = clip.timelineLayers[index]
        let copy = TimelineLayer(
            sourceIn: source.sourceIn, sourceOut: source.sourceOut,
            start: source.start, reversed: source.reversed)
        clip.timelineLayers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
    }

    func deleteLayer(_ id: TimelineLayer.ID) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        clip.timelineLayers.remove(at: index)
        if selectedLayerID == id { selectedLayerID = nil }
    }

    func deleteSelectedLayer() {
        if let id = selectedLayerID { deleteLayer(id) }
    }

    func moveLayer(_ id: TimelineLayer.ID, toIndex target: Int) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        let clamped = min(max(target, 0), clip.timelineLayers.count - 1)
        guard clamped != index else { return }
        let layer = clip.timelineLayers.remove(at: index)
        clip.timelineLayers.insert(layer, at: clamped)
    }

    func setLayerStart(_ id: TimelineLayer.ID, seconds: Double) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        clip.timelineLayers[index].start = max(0, seconds)
    }

    /// Pass nil to leave an edge untouched. Clamped to media bounds and the
    /// minimum layer length.
    func trimLayer(_ id: TimelineLayer.ID, sourceIn: Double?, sourceOut: Double?) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        var layer = clip.timelineLayers[index]
        if let sourceIn {
            layer.sourceIn = min(max(0, sourceIn), layer.sourceOut - minLayerLength)
        }
        if let sourceOut {
            layer.sourceOut = max(min(clip.duration, sourceOut), layer.sourceIn + minLayerLength)
        }
        clip.timelineLayers[index] = layer
    }

    /// Flips direction and mirrors the trim window (in,out → D−out,D−in) so the
    /// same content stays selected — AE time-reverse semantics.
    func toggleReverse(_ id: TimelineLayer.ID) {
        guard let clip = selectedClip, let index = layerIndex(id) else { return }
        var layer = clip.timelineLayers[index]
        layer.reversed.toggle()
        let mirroredIn = clip.duration - layer.sourceOut
        layer.sourceOut = clip.duration - layer.sourceIn
        layer.sourceIn = mirroredIn
        clip.timelineLayers[index] = layer
    }
```

- [ ] **Step 4: Run to verify green** — full suite passes.

- [ ] **Step 5: Commit** (message: `Timeline mode: clip storage + layer operations on AppModel`, with the co-author trailer).

---

### Task 3: ReverseRenderer + render kick-off

**Files:**
- Create: `VideoClipper/Export/ReverseRenderer.swift`
- Modify: `VideoClipper/Models/AppModel.swift` (`toggleReverse` kicks the render)
- Test: `VideoClipperTests/ReverseRendererTests.swift`

**Interfaces:**
- Consumes: `Clip.reversedAsset` (Task 2).
- Produces: `ReverseRenderer.render(sourceURL:) async throws -> URL` (cached), `AppModel.ensureReversedAsset(for:)` (private; called from `toggleReverse`).

- [ ] **Step 1: Write the failing test**

Create `VideoClipperTests/ReverseRendererTests.swift`:

```swift
//
//  ReverseRendererTests.swift
//  VideoClipperTests
//
//  End-to-end reverse render of the bundled SampleClip.mov: real reader/writer.
//

@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import VideoClipper

struct ReverseRendererTests {
    @Test func rendersAReversedPlayableVideoOfTheSameDuration() async throws {
        let source = try #require(
            Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov"))
        let output = try await ReverseRenderer.render(sourceURL: source)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let reversed = AVURLAsset(url: output)
        let duration = try await reversed.load(.duration).seconds
        #expect(abs(duration - sourceDuration) < 0.25)

        let track = try #require(try await reversed.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let sourceTrack = try #require(
            try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        #expect(size == sourceSize)

        // Cached: a second call answers the same URL without re-rendering.
        let again = try await ReverseRenderer.render(sourceURL: source)
        #expect(again == output)
    }
}

private final class BundleToken {}
```

- [ ] **Step 2: Run to verify failure** — compile error `cannot find 'ReverseRenderer'`.

- [ ] **Step 3: Implement**

Create `VideoClipper/Export/ReverseRenderer.swift`:

```swift
//
//  ReverseRenderer.swift
//  VideoClipper
//
//  Pre-renders a reversed copy of a clip's video track (silent — the timeline
//  has no audio). AVFoundation can't play a composition track backwards, so
//  reversed layers reference this file instead. Frames are processed in chunks
//  from the tail so long recordings never hold every frame in memory. Output is
//  cached in the temp directory keyed by (source path, mtime).
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum ReverseRendererError: LocalizedError {
    case noVideoTrack
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The clip has no video track"
        case .readFailed: "Couldn't read the clip's frames"
        case .writeFailed: "Couldn't write the reversed clip"
        }
    }
}

nonisolated enum ReverseRenderer {
    static func render(sourceURL: URL) async throws -> URL {
        let output = cacheURL(for: sourceURL)
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReverseRendererError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)

        // Pass 1: every frame's presentation time (compressed read — cheap).
        var times: [CMTime] = []
        let scanReader = try AVAssetReader(asset: asset)
        let scanOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        scanReader.add(scanOutput)
        scanReader.startReading()
        while let sample = scanOutput.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, CMSampleBufferGetNumSamples(sample) > 0 { times.append(time) }
        }
        guard scanReader.status == .completed, !times.isEmpty else {
            throw ReverseRendererError.readFailed
        }
        times.sort { $0 < $1 }   // decode order can differ from presentation order

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperReversing-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ReverseRendererError.writeFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Pass 2: decode chunks from the tail; source frame i (whose display
        // window ends at end_i) plays at (duration − end_i), which mirrors the
        // movie while preserving every frame's own duration.
        let chunkSize = 30
        var chunkUpper = times.count   // exclusive
        while chunkUpper > 0 {
            let chunkLower = max(0, chunkUpper - chunkSize)
            let rangeEnd = chunkUpper < times.count ? times[chunkUpper] : assetDuration
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: times[chunkLower], end: rangeEnd)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(readerOutput)
            reader.startReading()
            var frames: [(time: CMTime, buffer: CVPixelBuffer)] = []
            while let sample = readerOutput.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frames.append((CMSampleBufferGetPresentationTimeStamp(sample), buffer))
                }
            }
            guard reader.status == .completed else { throw ReverseRendererError.readFailed }
            frames.sort { $0.time < $1.time }

            // Pair decoded frames with their global indices (the reader can clip
            // chunk edges, so pair from the back where alignment is exact).
            let indices = Array(chunkLower..<chunkUpper).suffix(frames.count)
            for (frame, index) in zip(frames, indices).reversed() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let frameEnd = index + 1 < times.count ? times[index + 1] : assetDuration
                let newTime = assetDuration - frameEnd
                if !adaptor.append(frame.buffer, withPresentationTime: newTime) {
                    throw ReverseRendererError.writeFailed
                }
            }
            chunkUpper = chunkLower
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ReverseRendererError.writeFailed }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temp, to: output)
        return output
    }

    private static func cacheURL(for source: URL) -> URL {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 5381
        for byte in "\(source.path)|\(mtime)".utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperReversed-\(hash).mov")
    }
}
```

In `AppModel.toggleReverse`, after `clip.timelineLayers[index] = layer` add:

```swift
        if layer.reversed { ensureReversedAsset(for: clip) }
```

and add below it:

```swift
    /// Kicks the one-per-clip reversed render if it isn't ready or running.
    private func ensureReversedAsset(for clip: Clip) {
        switch clip.reversedAsset {
        case .rendering, .ready: return
        case .idle, .failed: break
        }
        clip.reversedAsset = .rendering
        let url = clip.url
        Task {
            do {
                let output = try await ReverseRenderer.render(sourceURL: url)
                clip.reversedAsset = .ready(output)
            } catch {
                clip.reversedAsset = .failed
                for index in clip.timelineLayers.indices where clip.timelineLayers[index].reversed {
                    self.toggleReverse(clip.timelineLayers[index].id)   // un-reverse (mirrors back)
                }
                self.errorMessage = "Couldn't reverse: \(error.localizedDescription)"
            }
        }
    }
```

(Task 5 later appends `refreshTimelinePreview()` after the `.ready` assignment.)

- [ ] **Step 4: Run to verify green** — `xcodegen generate` then full suite; the render test takes a few seconds.

- [ ] **Step 5: Commit** (`Timeline mode: chunked reverse renderer with per-source cache`).

---

### Task 4: Composition builder

**Files:**
- Modify: `VideoClipper/Export/TimelineComposer.swift`
- Test: `VideoClipperTests/TimelineComposerTests.swift` (append)

**Interfaces:**
- Consumes: `regions(layers:)` (Task 1), `EditMath.rotation/applyCrop/isIdentityCrop` (existing).
- Produces: `TimelineComposer.makeComposition(layers:sourceURL:reversedURL:rotationQuarters:cropRect:) async throws -> (AVMutableComposition, AVMutableVideoComposition)` and `TimelineComposerError`.

- [ ] **Step 1: Write the failing tests** — append to `TimelineComposerTests.swift` (add `@preconcurrency import AVFoundation` at the top and this fixture + tests at the bottom of the struct, plus a `private final class BundleToken {}` after it):

```swift
    // MARK: - Composition building (integration, SampleClip.mov)

    private func sampleURL() throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov"))
    }

    @Test func compositionSpansMaxLayerEndWithOneInstructionPerRegion() async throws {
        let source = try sampleURL()
        let layers = [
            TimelineLayer(sourceIn: 0, sourceOut: 1.2, start: 0),
            TimelineLayer(sourceIn: 0, sourceOut: 1.0, start: 0.6),
        ]
        let (composition, videoComposition) = try await TimelineComposer.makeComposition(
            layers: layers, sourceURL: source, reversedURL: nil,
            rotationQuarters: 0, cropRect: nil)

        #expect(composition.tracks(withMediaType: .video).count == 2)
        #expect(composition.tracks(withMediaType: .audio).isEmpty)   // silent timeline
        #expect(abs(composition.duration.seconds - 1.6) < 0.05)
        #expect(videoComposition.instructions.count
            == TimelineComposer.regions(layers: layers).count)
    }

    @Test func gapRegionsGetAnEmptyBlackInstruction() async throws {
        let source = try sampleURL()
        let layers = [TimelineLayer(sourceIn: 0, sourceOut: 1.0, start: 0.5)]
        let (_, videoComposition) = try await TimelineComposer.makeComposition(
            layers: layers, sourceURL: source, reversedURL: nil,
            rotationQuarters: 0, cropRect: nil)

        let first = try #require(
            videoComposition.instructions.first as? AVMutableVideoCompositionInstruction)
        #expect(first.layerInstructions.isEmpty)
        #expect(abs(first.timeRange.duration.seconds - 0.5) < 0.02)
    }
```

- [ ] **Step 2: Run to verify failure** — `no member 'makeComposition'`.

- [ ] **Step 3: Implement** — in `TimelineComposer.swift`, change the imports to `@preconcurrency import AVFoundation` + `import Foundation`, add:

```swift
nonisolated enum TimelineComposerError: LocalizedError {
    case noVideoTrack
    case cannotBuild

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The clip has no video track"
        case .cannotBuild: "Couldn't build the timeline composition"
        }
    }
}
```

and inside `TimelineComposer`:

```swift
    /// One composition video track per layer; one instruction per region with the
    /// visible track at opacity 1 and every other overlapping track at 0. Gap
    /// regions render black. Rotation/crop transforms match ClipEditExporter's.
    static func makeComposition(
        layers: [TimelineLayer],
        sourceURL: URL,
        reversedURL: URL?,
        rotationQuarters: Int,
        cropRect: CGRect?
    ) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw TimelineComposerError.noVideoTrack
        }
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let frameRate = (try? await sourceTrack.load(.nominalFrameRate)) ?? 30

        let quarters = ((rotationQuarters % 4) + 4) % 4
        var (transform, renderSize) = EditMath.rotation(
            naturalSize: naturalSize, preferredTransform: preferredTransform, quarters: quarters)
        if let cropRect, !EditMath.isIdentityCrop(cropRect) {
            (transform, renderSize) = EditMath.applyCrop(
                cropRect, transform: transform, renderSize: renderSize)
        }

        var reversedTrack: AVAssetTrack?
        if let reversedURL {
            reversedTrack = try await AVURLAsset(url: reversedURL)
                .loadTracks(withMediaType: .video).first
        }

        let composition = AVMutableComposition()
        var compositionTracks: [AVMutableCompositionTrack] = []
        for layer in layers {
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TimelineComposerError.cannotBuild
            }
            let mediaTrack = (layer.reversed ? reversedTrack : nil) ?? sourceTrack
            try track.insertTimeRange(
                CMTimeRange(
                    start: CMTime(seconds: layer.sourceIn, preferredTimescale: 600),
                    end: CMTime(seconds: layer.sourceOut, preferredTimescale: 600)),
                of: mediaTrack,
                at: CMTime(seconds: layer.start, preferredTimescale: 600))
            compositionTracks.append(track)
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for region in regions(layers: layers) {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(seconds: region.start, preferredTimescale: 600),
                end: CMTime(seconds: region.end, preferredTimescale: 600))
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let top = region.topLayerIndex {
                var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                let visible = AVMutableVideoCompositionLayerInstruction(
                    assetTrack: compositionTracks[top])
                visible.setTransform(transform, at: .zero)
                visible.setOpacity(1, at: .zero)
                layerInstructions.append(visible)
                // Every other track with media in this region must be listed —
                // hidden explicitly — or the compositor's output is undefined.
                for (index, track) in compositionTracks.enumerated()
                where index != top
                    && layers[index].start < region.end && layers[index].end > region.start {
                    let hidden = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    hidden.setTransform(transform, at: .zero)
                    hidden.setOpacity(0, at: .zero)
                    layerInstructions.append(hidden)
                }
                instruction.layerInstructions = layerInstructions
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        return (composition, videoComposition)
    }
```

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit** (`Timeline mode: multi-track composition builder with visibility instructions`).

---

### Task 5: Preview wiring

**Files:**
- Modify: `VideoClipper/Models/AppModel.swift`

**Interfaces:**
- Consumes: `TimelineComposer.makeComposition` (Task 4), `Clip.reversedAsset.readyURL` (Task 1).
- Produces: `AppModel.refreshTimelinePreview()` — called by every layer op; Timeline enter/leave handling inside `toggleTool`.

Preview wiring is player-bound and verified by build + the manual smoke in Task 8; the testable state rules were already covered in Task 2.

- [ ] **Step 1: Add the rebuild plumbing** — in AppModel near `previewGeneration` add:

```swift
    @ObservationIgnored private var timelineGeneration = 0
    @ObservationIgnored private var timelineRebuildTask: Task<Void, Never>?
```

Add at the end of the `// MARK: - Timeline layers` section:

```swift
    /// Rebuilds the composed preview item (debounced — drags emit streams of
    /// edits; the composition is reference-only so rebuilds are cheap).
    func refreshTimelinePreview() {
        guard activeTool == .timeline, let clip = selectedClip,
              !clip.timelineLayers.isEmpty else { return }
        timelineGeneration += 1
        let generation = timelineGeneration
        let layers = clip.timelineLayers
        let url = clip.url
        let reversedURL = clip.reversedAsset.readyURL
        let quarters = clip.rotationQuarters
        let crop = clip.isCropped ? clip.cropRect : nil
        timelineRebuildTask?.cancel()
        timelineRebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            guard let (composition, videoComposition) = try? await TimelineComposer.makeComposition(
                layers: layers, sourceURL: url, reversedURL: reversedURL,
                rotationQuarters: quarters, cropRect: crop) else { return }
            guard generation == self.timelineGeneration, self.activeTool == .timeline else { return }
            let resumeTime = self.currentTime
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = videoComposition
            self.player.pause()
            self.player.replaceCurrentItem(with: item)
            self.player.seek(
                to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
```

- [ ] **Step 2: Hook the layer ops** — append `refreshTimelinePreview()` as the last line of: `duplicateLayer`, `deleteLayer`, `moveLayer` (after the reorder), `setLayerStart`, `trimLayer`, `toggleReverse` (after the `ensureReversedAsset` line), and in `ensureReversedAsset` right after `clip.reversedAsset = .ready(output)`.

- [ ] **Step 3: Mode enter/leave** — in `toggleTool`, capture `let previous = activeTool` as the first line, and after the crop-seeding `if` add:

```swift
        if activeTool == .timeline {
            player.pause()
            isPlaying = false
            enterTimeline()
            refreshTimelinePreview()
        } else if previous == .timeline {
            pruneTrivialTimeline()
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: clip.url)))
            seek(to: min(currentTime, clip.duration))
        }
```

Guard the existing composition path: first line of `applyPreviewComposition()` becomes `guard activeTool != .timeline, let clip = selectedClip, let item = player.currentItem else { return }` — leaving Timeline mode already calls it via the existing call at the end of `toggleTool`, which now runs against the restored source item.

- [ ] **Step 4: Playback rules** — in `playbackTick`, change the trim-pause condition to also require `activeTool != .timeline`. In `togglePlay`, wrap the existing restart logic:

```swift
        if activeTool == .timeline {
            let end = player.currentItem?.duration.seconds ?? 0
            if end > 0, currentTime >= end - 0.05 { seek(to: 0) }
        } else if currentTime >= clip.trimEnd - 0.05 || currentTime < clip.trimStart {
            seek(to: clip.trimStart)
        }
```

- [ ] **Step 5: Build + full suite green, commit** (`Timeline mode: composed live preview wiring`).

---

### Task 6: Export path

**Files:**
- Modify: `VideoClipper/Export/TimelineComposer.swift` (add `export`)
- Modify: `VideoClipper/Models/AppModel.swift` (dispatch in `export(_:chooseDestination:)`)
- Test: `VideoClipperTests/TimelineComposerTests.swift` (append)

**Interfaces:**
- Consumes: `makeComposition` (Task 4), `ExportDestination` (existing).
- Produces: `TimelineComposer.export(layers:sourceURL:reversedURL:rotationQuarters:cropRect:) async throws -> URL` (temp .mp4).

- [ ] **Step 1: Write the failing test** — append to `TimelineComposerTests`:

```swift
    @Test func exportProducesAnMp4OfTheComposedDuration() async throws {
        let source = try sampleURL()
        let layers = [
            TimelineLayer(sourceIn: 0, sourceOut: 0.8, start: 0),
            TimelineLayer(sourceIn: 0, sourceOut: 0.8, start: 0.4),
        ]
        let output = try await TimelineComposer.export(
            layers: layers, sourceURL: source, reversedURL: nil,
            rotationQuarters: 0, cropRect: nil)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "mp4")
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.2) < 0.1)
    }
```

- [ ] **Step 2: Run to verify failure** — `no member 'export'`.

- [ ] **Step 3: Implement** — add to `TimelineComposer`:

```swift
    /// Exports the composed timeline to a temp .mp4 (silent, edits applied).
    static func export(
        layers: [TimelineLayer],
        sourceURL: URL,
        reversedURL: URL?,
        rotationQuarters: Int,
        cropRect: CGRect?
    ) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(
            layers: layers, sourceURL: sourceURL, reversedURL: reversedURL,
            rotationQuarters: rotationQuarters, cropRect: cropRect)
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TimelineComposerError.cannotBuild
        }
        session.videoComposition = videoComposition
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperTimeline-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
        return output
    }
```

In `AppModel.export(_:chooseDestination:)`, right after the `isExporting` guard insert:

```swift
        if clip.hasActiveTimeline {
            exportTimeline(clip, chooseDestination: chooseDestination)
            return
        }
```

and add alongside:

```swift
    /// Timeline export: same destination conventions as the single-clip path.
    private func exportTimeline(_ clip: Clip, chooseDestination: Bool) {
        clip.exportState = .exporting
        let layers = clip.timelineLayers
        let reversedURL = clip.reversedAsset.readyURL
        let quarters = clip.rotationQuarters
        let crop = clip.isCropped ? clip.cropRect : nil
        Task {
            do {
                let temp = try await TimelineComposer.export(
                    layers: layers, sourceURL: clip.url, reversedURL: reversedURL,
                    rotationQuarters: quarters, cropRect: crop)
                guard let destination = self.resolveDestination(
                    for: clip, produced: temp, choose: chooseDestination) else {
                    try? FileManager.default.removeItem(at: temp)
                    clip.exportState = .idle
                    return
                }
                try ExportDestination.place(temp, at: destination)
                clip.exportState = .done(destination)
                AppLog.export.info("timeline exported → \(destination.lastPathComponent, privacy: .public)")
            } catch {
                clip.exportState = .failed(error.localizedDescription)
                self.errorMessage = "Couldn't export timeline: \(error.localizedDescription)"
            }
        }
    }
```

Note: the existing `hasEdits` guard in `export` stays after the timeline dispatch — `hasActiveTimeline` already makes `hasEdits` true (Task 2).

- [ ] **Step 4: Run to verify green.**

- [ ] **Step 5: Commit** (`Timeline mode: composed export through the standard destination flow`).

---

### Task 7: Track UI + integration

**Files:**
- Create: `VideoClipper/Views/TimelineTrackView.swift`
- Modify: `VideoClipper/Views/MainView.swift` (tool button, strip swap, readout, zoom guards)
- Modify: `VideoClipper/VideoClipperApp.swift` (mode-aware ⌫)
- Modify: `README.md`

View-layer work (no unit tests, per repo convention); verified by build + Task 8 smoke.

- [ ] **Step 1: Create `VideoClipper/Views/TimelineTrackView.swift`**

```swift
//
//  TimelineTrackView.swift
//  VideoClipper
//
//  Timeline mode's editor: a ruler with the shared playhead over a stack of
//  layer rows (top row = topmost layer). Bar body drags move a layer on the
//  master timeline, edge drags trim it, vertical drags reorder z. The selected
//  row carries duplicate / reverse / delete actions.
//

import SwiftUI

struct TimelineTrackView: View {
    let model: AppModel
    @Bindable var clip: Clip

    private let rowHeight: CGFloat = 24

    /// One drag's fixed frame of reference (values at drag start).
    private struct DragOrigin {
        var start: Double
        var sourceIn: Double
        var sourceOut: Double
        var zIndex: Int
    }
    private enum DragKind { case move, trimIn, trimOut }
    @State private var dragOrigin: DragOrigin?
    @State private var dragKind: DragKind?

    var body: some View {
        VStack(spacing: 4) {
            ruler.frame(height: 18)
            // Reversed: array end = topmost layer = first row, AE-style.
            ForEach(Array(clip.timelineLayers.enumerated()).reversed(), id: \.element.id) { index, layer in
                trackRow(layer: layer, zIndex: index)
                    .frame(height: rowHeight)
            }
        }
    }

    // MARK: - Ruler

    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.masterDuration, 0.001)
            let step: Double = duration > 20 ? 5 : 1
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { tick in
                    let x = CGFloat(tick / duration) * width
                    Rectangle().fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 6)
                        .offset(x: x, y: 6)
                    Text("\(Int(tick))s")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: x + 2, y: -2)
                }
                let playheadX = min(max(CGFloat(model.currentTime / duration) * width, 0), width)
                Rectangle().fill(.white).frame(width: 2, height: 18)
                    .offset(x: playheadX - 1)
                    .allowsHitTesting(false)
                Circle().fill(.white).frame(width: 10, height: 10)
                    .offset(x: playheadX - 5, y: 4)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                    model.scrub(to: Double(fraction) * duration)
                }
            )
        }
    }

    // MARK: - Track rows

    private func trackRow(layer: TimelineLayer, zIndex: Int) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.masterDuration, 0.001)
            let scale = width / CGFloat(duration)
            let barX = CGFloat(layer.start) * scale
            let barWidth = max(CGFloat(layer.end - layer.start) * scale, 8)
            let isSelected = model.selectedLayerID == layer.id

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))

                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.cyan.opacity(0.75) : Color.cyan.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.white : Color.cyan, lineWidth: 1))
                    .overlay(alignment: .leading) {
                        HStack(spacing: 4) {
                            if layer.reversed {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            Text(label(for: layer, zIndex: zIndex))
                                .font(.system(size: 9).monospacedDigit())
                                .lineLimit(1)
                        }
                        .foregroundStyle(.black)
                        .padding(.leading, 10)
                    }
                    .frame(width: barWidth)
                    .offset(x: barX)
                    .gesture(barGesture(layer: layer, zIndex: zIndex, barX: barX,
                                        barWidth: barWidth, scale: scale))

                if isSelected {
                    layerActions(layer: layer)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func label(for layer: TimelineLayer, zIndex: Int) -> String {
        let length = layer.sourceOut - layer.sourceIn
        let rendering = layer.reversed && clip.reversedAsset.isRendering
        return "L\(zIndex + 1) · \(String(format: "%.1f", length))s"
            + (rendering ? " · reversing…" : "")
    }

    private func layerActions(layer: TimelineLayer) -> some View {
        HStack(spacing: 8) {
            Button { model.duplicateLayer(layer.id) } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Duplicate layer")
            Button { model.toggleReverse(layer.id) } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(layer.reversed ? Color.cyan : Color.secondary)
            }
            .help(layer.reversed ? "Play forward" : "Reverse layer")
            Button { model.deleteLayer(layer.id) } label: {
                Image(systemName: "trash")
            }
            .help("Delete layer (⌫)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .padding(.trailing, 6)
    }

    /// One gesture covers select, move, edge-trim, and vertical z-reorder. The
    /// zone (edge vs body) is fixed at drag start; edits are absolute against
    /// the drag-start values, so there is no incremental error accumulation.
    private func barGesture(
        layer: TimelineLayer, zIndex: Int, barX: CGFloat, barWidth: CGFloat, scale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    model.selectedLayerID = layer.id
                    model.endNoteEditing()
                    dragOrigin = DragOrigin(
                        start: layer.start, sourceIn: layer.sourceIn,
                        sourceOut: layer.sourceOut, zIndex: zIndex)
                    let grabX = value.startLocation.x - barX
                    dragKind = grabX < 8 ? .trimIn : (grabX > barWidth - 8 ? .trimOut : .move)
                }
                guard let origin = dragOrigin, let kind = dragKind else { return }
                let deltaSeconds = Double(value.translation.width / max(scale, 0.001))
                switch kind {
                case .move:
                    model.setLayerStart(layer.id, seconds: origin.start + deltaSeconds)
                    // Dragging up (negative height) raises the layer, one row per
                    // rowHeight step; moveLayer clamps and ignores no-ops.
                    let steps = Int((-value.translation.height / rowHeight).rounded())
                    model.moveLayer(layer.id, toIndex: origin.zIndex + steps)
                case .trimIn:
                    model.trimLayer(layer.id, sourceIn: origin.sourceIn + deltaSeconds, sourceOut: nil)
                case .trimOut:
                    model.trimLayer(layer.id, sourceIn: nil, sourceOut: origin.sourceOut + deltaSeconds)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragKind = nil
            }
    }
}
```

- [ ] **Step 2: MainView integration**

In `ControlsView`, wrap the lane + strip block: the existing

```swift
            if !clip.markers.isEmpty || model.activeTool == .marker || model.activeTool == .trim {
                playheadActionLane
            }

            TrimStrip(
```
…through `.frame(height: 44)` becomes:

```swift
            if model.activeTool == .timeline {
                TimelineTrackView(model: model, clip: clip)
            } else {
                if !clip.markers.isEmpty || model.activeTool == .marker || model.activeTool == .trim {
                    playheadActionLane
                }

                TrimStrip(
                    thumbnails: clip.stripThumbnails,
                    duration: clip.duration,
                    minTrim: model.minTrim,
                    isTrimming: model.activeTool == .trim,
                    trimStart: $clip.trimStart,
                    trimEnd: $clip.trimEnd,
                    playhead: model.currentTime,
                    markers: clip.markers.map(\.time),
                    onScrub: { model.scrub(to: $0) }
                )
                .frame(height: 44)
            }
```

Tool row — after the Mark button add:

```swift
                toolButton("Timeline", systemImage: "rectangle.stack",
                           isActive: model.activeTool == .timeline,
                           hasEdit: clip.hasActiveTimeline, dotColor: .cyan) {
                    model.toggleTool(.timeline)
                }
                .help("Timeline — duplicate/reverse/trim/offset layers; drag rows to restack")
```

Transport readout — replace the `Text(...)` line with:

```swift
                Text(model.activeTool == .timeline
                    ? "\(timeString(model.currentTime)) / \(timeString(model.masterDuration))"
                    : "\(timeString(playheadDisplayTime)) / \(timeString(clip.trimmedDuration))")
```

Canvas zoom guards: in `MainView`, each of the three `guard model.activeTool != .crop, model.activeTool != .marker` closures gains `, model.activeTool != .timeline`; the `resetZoom` `onChange` condition gains `|| model.activeTool == .timeline`.

- [ ] **Step 3: Mode-aware ⌫** — in `VideoClipperApp.swift`, replace the "Delete Selected Stroke" button with:

```swift
            Button(model.activeTool == .timeline ? "Delete Layer" : "Delete Selected Stroke") {
                if model.activeTool == .timeline {
                    model.deleteSelectedLayer()
                } else {
                    model.deleteSelectedStroke()
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.isEditingNote || (model.activeTool == .timeline
                ? model.selectedLayerID == nil
                : model.selectedStrokeID == nil))
```

- [ ] **Step 4: README** — in the feature list after the frame-handoff section add:

```markdown
## Timeline mode

The **Timeline** tool stacks full-frame layers of the current clip, AE-style:
duplicate a layer, reverse it (pre-rendered in the background), trim each
layer's window, drag it along the master timeline, and drag rows vertically to
change who's on top — during overlaps the topmost layer plays. The composed
result previews live and `⌘S` exports it as a single silent video.
```

- [ ] **Step 5: Build + full suite green, commit** (`Timeline mode: track UI, tool button, mode-aware delete, README`).

---

### Task 8: Verification + smoke test

- [ ] **Step 1: Full suite** — `xcodebuild -scheme VideoClipper test`; expected: all tests pass (Tasks 1–6 added ~13).
- [ ] **Step 2: Launch smoke** — build, `open` the Debug app, and verify by hand with a real clip: enter Timeline (seed layer appears full-width), duplicate, trim the copy by its edges, drag it right to overlap, drag it below the original (z flip visible in preview), reverse it (badge → plays backwards), `⌘S` exports and the file plays. Report anything broken back as a bug before proceeding.
- [ ] **Step 3: Report status to the user** — do not merge/push without their word; the repo is public.

## Self-review notes

- Spec coverage: model/seeding (T2), regions (T1), composition+instructions (T4), reverse renderer+cache+failure unset (T3), preview (T5), export+naming (T6), UI incl. reorder drag and ⌫ (T7), out-of-scope untouched. Trim-strip/marker features remain untouched outside `activeTool == .timeline` branches.
- Types cross-checked: `TimelineLayer.ID`, `regions(layers:)`, `makeComposition(layers:sourceURL:reversedURL:rotationQuarters:cropRect:)`, `readyURL`, `minLayerLength` used consistently across tasks.
