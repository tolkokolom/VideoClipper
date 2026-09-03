//
//  TimelineComposerTests.swift
//  VideoClipperTests
//
//  Pure visibility flattening for the timeline: regions() slices the master
//  timeline at layer boundaries and names the topmost covering layer per slice.
//

import Foundation
@preconcurrency import AVFoundation
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

        // Pin the visibility semantics of the overlap region (0.6–1.6, top = layer 1):
        // the top layer's track must be listed first at opacity 1, and every other
        // overlapping track must still be listed, hidden at opacity 0.
        let compositionTracks = composition.tracks(withMediaType: .video)
        let overlap = try #require(
            videoComposition.instructions.last as? AVMutableVideoCompositionInstruction)
        #expect(abs(overlap.timeRange.start.seconds - 0.6) < 0.02)
        #expect(overlap.layerInstructions.count == 2)
        #expect(overlap.layerInstructions[0].trackID == compositionTracks[1].trackID)
        #expect(overlap.layerInstructions[1].trackID == compositionTracks[0].trackID)

        // setOpacity(_:at:) records a (degenerate, constant) ramp rather than a bare
        // value, so getOpacityRamp does report one here — start == end == the opacity
        // that was set, holding from the region start with an indefinite duration
        // (no further keyframe follows). Confirmed empirically before writing these
        // assertions; see the report for the exact recorded values.
        var visStart: Float = -1
        var visEnd: Float = -1
        var visRange = CMTimeRange.zero
        let visHasRamp = overlap.layerInstructions[0].getOpacityRamp(
            for: overlap.timeRange.start,
            startOpacity: &visStart, endOpacity: &visEnd, timeRange: &visRange)
        #expect(visHasRamp == true)
        #expect(visStart == 1)
        #expect(visEnd == 1)

        var hidStart: Float = -1
        var hidEnd: Float = -1
        var hidRange = CMTimeRange.zero
        let hidHasRamp = overlap.layerInstructions[1].getOpacityRamp(
            for: overlap.timeRange.start,
            startOpacity: &hidStart, endOpacity: &hidEnd, timeRange: &hidRange)
        #expect(hidHasRamp == true)
        #expect(hidStart == 0)
        #expect(hidEnd == 0)
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

    // MARK: - Reversed-source selection

    /// A cheap stand-in for a real reverse render: a copy of SampleClip.mov at a
    /// distinct URL, so we can prove *which file* a track's media came from without
    /// needing an actual time-reversed asset (makeComposition only loads a video track).
    private func copyOfSample() throws -> URL {
        let source = try sampleURL()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try FileManager.default.copyItem(at: source, to: tempURL)
        return tempURL
    }

    @Test func reversedLayerUsesReversedURLWhenProvided() async throws {
        let source = try sampleURL()
        let reversedCopy = try copyOfSample()
        defer { try? FileManager.default.removeItem(at: reversedCopy) }

        let layers = [TimelineLayer(sourceIn: 0, sourceOut: 1.0, start: 0, reversed: true)]
        let (composition, _) = try await TimelineComposer.makeComposition(
            layers: layers, sourceURL: source, reversedURL: reversedCopy,
            rotationQuarters: 0, cropRect: nil)

        let track = try #require(composition.tracks(withMediaType: .video).first)
        let segment = try #require(track.segments.first)
        #expect(segment.sourceURL == reversedCopy)
    }

    @Test func reversedLayerFallsBackToSourceWhenNoReversedURL() async throws {
        let source = try sampleURL()
        let layers = [TimelineLayer(sourceIn: 0, sourceOut: 1.0, start: 0, reversed: true)]
        let (composition, _) = try await TimelineComposer.makeComposition(
            layers: layers, sourceURL: source, reversedURL: nil,
            rotationQuarters: 0, cropRect: nil)

        let track = try #require(composition.tracks(withMediaType: .video).first)
        let segment = try #require(track.segments.first)
        #expect(segment.sourceURL == source)
    }

    // MARK: - Export

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
}

private final class BundleToken {}
