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
}

private final class BundleToken {}
