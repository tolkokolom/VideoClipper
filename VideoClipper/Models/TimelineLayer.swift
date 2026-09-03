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
    nonisolated let id = UUID()
    nonisolated var sourceIn: Double
    nonisolated var sourceOut: Double
    nonisolated var start: Double
    nonisolated var reversed = false

    nonisolated var end: Double { start + (sourceOut - sourceIn) }
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
