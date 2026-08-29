//
//  FrameHandoffTests.swift
//  VideoClipperTests
//
//  Pure naming/formatting for the frame handoff export: frame filenames, the
//  never-overwriting folder name, and the markdown manifest (relative for the
//  on-disk frames.md, absolute for the clipboard payload).
//

import Foundation
import Testing
@testable import VideoClipper

struct FrameHandoffTests {
    // MARK: - Frame filenames

    @Test func frameFilenameZeroPadsIndexAndFormatsTime() {
        #expect(FrameHandoff.frameFilename(index: 1, time: 0) == "01_t0.00s.jpg")
        #expect(FrameHandoff.frameFilename(index: 12, time: 71.466) == "12_t71.47s.jpg")
    }

    // MARK: - Folder naming

    @Test func firstExportGetsFramesFolderBesideSource() {
        let source = URL(fileURLWithPath: "/tmp/captures/mybug.mov")
        let folder = FrameHandoff.nextAvailableFolder(besides: source) { _ in false }
        #expect(folder.path == "/tmp/captures/mybug-frames")
    }

    @Test func folderCollisionsIncrementSuffix() {
        let source = URL(fileURLWithPath: "/tmp/captures/mybug.mov")
        let taken: Set<String> = ["/tmp/captures/mybug-frames", "/tmp/captures/mybug-frames-2"]
        let folder = FrameHandoff.nextAvailableFolder(besides: source) { taken.contains($0.path) }
        #expect(folder.path == "/tmp/captures/mybug-frames-3")
    }

    // MARK: - Manifest

    private let markers = [
        FrameMarker(time: 0, note: "initial state, button enabled"),
        FrameMarker(time: 1.47, note: ""),
        FrameMarker(time: 3.1, note: "spinner stuck"),
    ]

    @Test func manifestListsFramesWithTimingDeltasAndNotes() {
        let text = FrameHandoff.manifest(
            sourceName: "mybug.mov", duration: 5.2, markers: markers, basePath: nil)
        #expect(text == """
        Frames from screen recording mybug.mov (5.2s, 3 frames marked):

        1. t=0.00s — 01_t0.00s.jpg
           note: initial state, button enabled
        2. t=1.47s (Δ+1.47s) — 02_t1.47s.jpg
        3. t=3.10s (Δ+1.63s) — 03_t3.10s.jpg
           note: spinner stuck
        """)
    }

    @Test func manifestWithBasePathEmitsAbsoluteFramePaths() {
        let text = FrameHandoff.manifest(
            sourceName: "mybug.mov", duration: 5.2, markers: markers,
            basePath: "/tmp/captures/mybug-frames")
        #expect(text.contains("— /tmp/captures/mybug-frames/01_t0.00s.jpg"))
        #expect(text.contains("— /tmp/captures/mybug-frames/03_t3.10s.jpg"))
    }

    @Test func manifestCollapsesNewlinesInsideNotes() {
        let text = FrameHandoff.manifest(
            sourceName: "a.mov", duration: 1,
            markers: [FrameMarker(time: 0, note: "line one\nline two")], basePath: nil)
        #expect(text.contains("note: line one line two"))
    }

    @Test func manifestFlagsFramesCarryingPaintStrokes() {
        let stroke = PaintStroke(points: [CGPoint(x: 0.5, y: 0.5)], color: .red)
        let text = FrameHandoff.manifest(
            sourceName: "a.mov", duration: 1,
            markers: [
                FrameMarker(time: 0, strokes: [stroke]),
                FrameMarker(time: 0.5),
            ],
            basePath: nil)
        #expect(text.contains("— 01_t0.00s.jpg (annotated)"))
        #expect(text.contains("— 02_t0.50s.jpg\n") || text.hasSuffix("— 02_t0.50s.jpg"))
    }

    @Test func manifestOmitsWhitespaceOnlyNotes() {
        let text = FrameHandoff.manifest(
            sourceName: "a.mov", duration: 1,
            markers: [FrameMarker(time: 0, note: "  ")], basePath: nil)
        #expect(!text.contains("note:"))
    }
}
