//
//  AppModelTests.swift
//  VideoClipperTests
//

import Foundation
import Testing
@testable import VideoClipper

struct AppModelTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/videoclipper-tests/\(name).mov")
    }

    @Test func addClipsFocusesFirstAddedWhenBinEmpty() {
        let model = AppModel()
        model.addClips(urls: [url("a"), url("b")])
        #expect(model.selectedClip?.url == url("a"))
    }

    @Test func addClipsRefocusesOnNewlyAddedClip() {
        let model = AppModel()
        model.addClips(urls: [url("a")])
        model.addClips(urls: [url("b"), url("c")])
        #expect(model.selectedClip?.url == url("b"))
    }

    @Test func duplicateDropFocusesExistingClip() {
        let model = AppModel()
        model.addClips(urls: [url("a"), url("b")]) // focuses a
        let handled = model.addClips(urls: [url("b")])
        #expect(handled)
        #expect(model.selectedClip?.url == url("b"))
    }

    @Test func nonVideoDropIsStillRejected() {
        let model = AppModel()
        let handled = model.addClips(urls: [URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(!handled)
        #expect(model.selectedClip == nil)
    }

    // MARK: - Frame markers

    /// Model with one selected clip whose duration is set (clips never load in tests —
    /// the fixture URLs don't exist).
    private func modelWithClip(duration: Double = 10) -> AppModel {
        let model = AppModel()
        model.addClips(urls: [url("a")])
        model.selectedClip?.duration = duration
        return model
    }

    @Test func toggleMarkerAddsMarkerAtPlayhead() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.toggleMarker()
        #expect(model.selectedClip?.markers.map(\.time) == [1.5])
    }

    @Test func toggleMarkerOnExistingMarkerRemovesIt() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.toggleMarker()
        model.toggleMarker()
        #expect(model.selectedClip?.markers.isEmpty == true)
    }

    @Test func markersStaySortedByTime() {
        let model = modelWithClip()
        model.currentTime = 2.0
        model.toggleMarker()
        model.currentTime = 0.5
        model.toggleMarker()
        #expect(model.selectedClip?.markers.map(\.time) == [0.5, 2.0])
    }

    @Test func jumpToMarkerSeeksToNeighborAndClampsAtEnds() {
        let model = modelWithClip()
        model.currentTime = 0.5
        model.toggleMarker()
        model.currentTime = 2.0
        model.toggleMarker()

        model.currentTime = 0
        model.jumpToMarker(offset: 1)
        #expect(model.currentTime == 0.5)
        model.jumpToMarker(offset: 1)
        #expect(model.currentTime == 2.0)
        model.jumpToMarker(offset: 1)   // no marker after the last: stay put
        #expect(model.currentTime == 2.0)
        model.jumpToMarker(offset: -1)
        #expect(model.currentTime == 0.5)
        model.jumpToMarker(offset: -1)  // no marker before the first: stay put
        #expect(model.currentTime == 0.5)
    }

    @Test func toggleMarkerWithoutClipDoesNothing() {
        let model = AppModel()
        model.toggleMarker()   // must not crash
        model.jumpToMarker(offset: 1)
        #expect(model.selectedClip == nil)
    }

    @Test func markerToolTogglesWithoutSeedingACrop() {
        let model = modelWithClip()
        model.toggleTool(.marker)
        #expect(model.activeTool == .marker)
        #expect(model.selectedClip?.isCropped == false)   // only Crop seeds a crop rect
        model.toggleTool(.marker)
        #expect(model.activeTool == nil)
    }

    @Test func requestNoteFocusOpensMarkerToolSeeksAndSetsRequest() throws {
        let model = modelWithClip()
        model.currentTime = 1.0
        model.toggleMarker()
        let marker = try #require(model.selectedClip?.markers.first)

        model.toggleTool(.trim)
        model.currentTime = 5
        model.requestNoteFocus(marker)

        #expect(model.activeTool == .marker)
        #expect(model.currentTime == 1.0)
        #expect(model.noteFocusRequest == marker.id)
    }

    @Test func editNoteAtPlayheadTargetsTheMarkerUnderThePlayhead() {
        let model = modelWithClip()
        model.currentTime = 1.0
        model.toggleMarker()

        model.editNoteAtPlayhead()   // straight after M — the playhead is on the marker
        #expect(model.noteFocusRequest == model.selectedClip?.markers.first?.id)
        #expect(model.activeTool == .marker)
    }

    @Test func editNoteAtPlayheadDoesNothingAwayFromMarkers() {
        let model = modelWithClip()
        model.currentTime = 1.0
        model.toggleMarker()
        model.currentTime = 5

        model.editNoteAtPlayhead()
        #expect(model.noteFocusRequest == nil)
    }

    @Test func scrubbingBlursNoteEditingAndSeeks() {
        let model = modelWithClip()
        model.isEditingNote = true
        let before = model.noteBlurSignal
        model.scrub(to: 2)
        #expect(model.noteBlurSignal == before + 1)
        #expect(model.currentTime == 2)
    }

    @Test func togglePlayBlursNoteEditing() {
        let model = modelWithClip()
        model.isEditingNote = true
        let before = model.noteBlurSignal
        model.togglePlay()
        #expect(model.noteBlurSignal == before + 1)
    }

    @Test func blurSignalStaysQuietWhenNotEditing() {
        let model = modelWithClip()
        let before = model.noteBlurSignal
        model.scrub(to: 2)
        model.togglePlay()
        #expect(model.noteBlurSignal == before)
    }

    // MARK: - Paint strokes

    @Test func addStrokeOnUnmarkedFrameCreatesTheMarker() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.addStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)])
        #expect(model.selectedClip?.markers.map(\.time) == [1.5])
        #expect(model.selectedClip?.markers.first?.strokes.count == 1)
    }

    @Test func addStrokeUsesTheSelectedSwatchAndAppendsOnMarkedFrames() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.toggleMarker()
        model.paintColor = .yellow
        model.addStroke(points: [CGPoint(x: 0.1, y: 0.1)])
        model.paintColor = .green
        model.addStroke(points: [CGPoint(x: 0.9, y: 0.9)])
        let marker = model.selectedClip?.markers.first
        #expect(model.selectedClip?.markers.count == 1)
        #expect(marker?.strokes.map(\.color) == [.yellow, .green])
    }

    @Test func addStrokeUsesTheSelectedBrushWidth() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.paintWidth = 0.02
        model.addStroke(points: [CGPoint(x: 0.5, y: 0.5)])
        #expect(model.selectedClip?.markers.first?.strokes.first?.width == 0.02)
    }

    @Test func addStrokeCarriesTheSelectedShapeKind() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.paintShape = .rectangle
        model.addStroke(points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])
        #expect(model.selectedClip?.markers.first?.strokes.first?.kind == .rectangle)
    }

    @Test func undoRemovesOnlyTheLastStrokeAndClearRemovesAll() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.addStroke(points: [CGPoint(x: 0.1, y: 0.1)])
        model.addStroke(points: [CGPoint(x: 0.2, y: 0.2)])
        model.undoStroke()
        #expect(model.selectedClip?.markers.first?.strokes.count == 1)
        model.addStroke(points: [CGPoint(x: 0.3, y: 0.3)])
        model.clearStrokes()
        #expect(model.selectedClip?.markers.first?.strokes.isEmpty == true)
    }

    @Test func deleteSelectedStrokeRemovesOnlyThatStrokeAndClearsSelection() throws {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.addStroke(points: [CGPoint(x: 0.1, y: 0.1)])
        model.addStroke(points: [CGPoint(x: 0.9, y: 0.9)])
        let first = try #require(model.selectedClip?.markers.first?.strokes.first)

        model.selectedStrokeID = first.id
        model.deleteSelectedStroke()

        let strokes = model.selectedClip?.markers.first?.strokes
        #expect(strokes?.count == 1)
        #expect(strokes?.first?.id != first.id)
        #expect(model.selectedStrokeID == nil)
    }

    @Test func translateAndScaleApplyOnlyToTheSelectedStroke() throws {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.addStroke(points: [CGPoint(x: 0.2, y: 0.2)])
        model.addStroke(points: [CGPoint(x: 0.6, y: 0.6)])
        let second = try #require(model.selectedClip?.markers.first?.strokes.last)

        model.selectedStrokeID = second.id
        model.translateSelectedStroke(by: CGPoint(x: 0.1, y: 0.1))
        model.scaleSelectedStroke(by: CGSize(width: 2, height: 2), anchor: CGPoint(x: 0.5, y: 0.5))

        let strokes = model.selectedClip?.markers.first?.strokes
        #expect(strokes?.first?.points.first == CGPoint(x: 0.2, y: 0.2))   // untouched
        let moved = try #require(strokes?.last?.points.first)
        // (0.6+0.1 − 0.5) × 2 + 0.5 = 0.9 on both axes
        #expect(abs(moved.x - 0.9) < 1e-9 && abs(moved.y - 0.9) < 1e-9)
    }

    @Test func strokeEditOpsWithoutSelectionAreNoOps() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.addStroke(points: [CGPoint(x: 0.2, y: 0.2)])
        model.deleteSelectedStroke()
        model.translateSelectedStroke(by: CGPoint(x: 0.1, y: 0.1))
        let strokes = model.selectedClip?.markers.first?.strokes
        #expect(strokes?.count == 1)
        #expect(strokes?.first?.points.first == CGPoint(x: 0.2, y: 0.2))
    }

    @Test func strokeOpsAwayFromAnyMarkerDoNothing() {
        let model = modelWithClip()
        model.currentTime = 1.5
        model.toggleMarker()
        model.currentTime = 5
        model.undoStroke()    // must not crash, must not touch the marker at 1.5
        model.clearStrokes()
        #expect(model.selectedClip?.markers.count == 1)
    }

    // MARK: - Frame handoff export

    @Test func exportMarkedFramesWithoutMarkersReportsError() {
        let model = modelWithClip()
        model.selectedClip?.isLoaded = true
        model.exportMarkedFrames()
        #expect(model.errorMessage != nil)
        #expect(model.selectedClip?.frameExportState.isExporting == false)
    }

    @Test func exportMarkedFramesCopiesManifestAndRecordsFolder() async throws {
        let bundled = try #require(
            Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelFrameExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("mybug.mov")
        try FileManager.default.copyItem(at: bundled, to: source)

        let model = AppModel()
        var copied: String?
        model.writeClipboard = { copied = $0 }
        model.addClips(urls: [source])
        let clip = try #require(model.selectedClip)
        clip.isLoaded = true
        clip.duration = 1
        model.currentTime = 0.2
        model.toggleMarker()

        model.exportMarkedFrames()
        for _ in 0..<200 where !clip.frameExportState.exportedFolderExists {
            try await Task.sleep(for: .milliseconds(50))
        }

        let folder = try #require(clip.frameExportState.exportedURL)
        #expect(folder.lastPathComponent == "mybug-frames")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames.md").path))
        let clipboard = try #require(copied)
        #expect(clipboard.contains(folder.appendingPathComponent("01_t0.20s.jpg").path))
    }
}

private extension ExportState {
    var exportedFolderExists: Bool { exportedURL != nil }
}

private final class BundleToken {}
