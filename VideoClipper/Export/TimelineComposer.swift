//
//  TimelineComposer.swift
//  VideoClipper
//
//  Timeline-mode engine. The pure regions() function is the single source of
//  truth for what is visible when: it slices the master timeline at every layer
//  boundary and names the topmost covering layer per slice (nil = gap → black).
//

@preconcurrency import AVFoundation
import Foundation

/// One slice of the master timeline with a single visible layer (or none).
struct TimelineRegion: Equatable, Sendable {
    var start: Double
    var end: Double
    /// Index into the layers array; nil renders black.
    var topLayerIndex: Int?
}

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

        // Keep the asset itself alive for the rest of the function: AVAssetTrack.asset is a
        // weak back-reference, so an unretained temporary AVURLAsset here would be deallocated
        // as soon as loadTracks returns, and the later insertTimeRange(_:of:at:) below would
        // fail (AVFoundationErrorDomain -11800 / OSStatus -12780) reading from a track whose
        // parent asset is gone. Same pattern as ClipEditExporter.exportRotationLossless's
        // retained `asset` local.
        var reversedAsset: AVURLAsset?
        var reversedTrack: AVAssetTrack?
        if let reversedURL {
            reversedAsset = AVURLAsset(url: reversedURL)
            reversedTrack = try await reversedAsset!.loadTracks(withMediaType: .video).first
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
}
