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
