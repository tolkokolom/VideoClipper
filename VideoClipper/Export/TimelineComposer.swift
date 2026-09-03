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
