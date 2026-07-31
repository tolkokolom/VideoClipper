//
//  ClipEditExporter.swift
//  VideoClipper
//
//  Ported from ClipShot. Exports a trimmed and/or rotated copy of a clip via
//  AVAssetExportSession + AVMutableVideoComposition. Audio passes through the trim
//  automatically. Pure-rotation saves (no trim, no crop) take a lossless passthrough
//  fast-path that only rewrites the orientation metadata — no re-encode, no quality loss.
//

@preconcurrency import AVFoundation
import Foundation
import os

nonisolated enum ClipEditError: LocalizedError {
    case noVideoTrack
    case cannotCreateExportSession

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The clip has no video track"
        case .cannotCreateExportSession: "Could not create the export session"
        }
    }
}

nonisolated enum ClipEditExporter {
    /// Exports `sourceURL` limited to `timeRange`, rotated by `rotationQuarters` × 90° and
    /// cropped to `cropRect` (normalized in the displayed, post-rotation video; nil = no crop).
    /// Re-encoded exports land in an .mp4 container (shareable everywhere); the lossless
    /// rotation fast-path keeps .mov, since passthrough must accept whatever codec is inside.
    static func export(sourceURL: URL, timeRange: CMTimeRange, rotationQuarters: Int, cropRect: CGRect? = nil) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw ClipEditError.noVideoTrack
        }

        // Lossless fast-path: when the ONLY edit is rotation (no trim, no crop), rewrite the
        // video track's orientation metadata (preferredTransform) and remux via passthrough
        // instead of re-encoding. Preserves both resolution AND quality and is far faster —
        // the re-encode path below recompresses every frame and loses quality each save.
        let quarters = ((rotationQuarters % 4) + 4) % 4
        let hasCrop = (cropRect.map { !EditMath.isIdentityCrop($0) } ?? false)
        if quarters != 0, !hasCrop {
            let assetDuration = (try? await asset.load(.duration)) ?? .zero
            let coversFullClip = timeRange.start.seconds <= 0.04
                && timeRange.duration.seconds >= assetDuration.seconds - 0.04
            if coversFullClip {
                do {
                    let url = try await exportRotationLossless(sourceURL: sourceURL, rotationQuarters: quarters)
                    AppLog.export.info("export: lossless rotation fast-path succeeded (quarters=\(quarters, privacy: .public))")
                    return url
                } catch {
                    // Passthrough can fail for unusual codecs/containers — fall through to the
                    // standard re-encode so the save still succeeds.
                    AppLog.export.error("export: lossless rotation failed (\(error.localizedDescription, privacy: .public)); re-encoding")
                }
            }
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipEditError.cannotCreateExportSession
        }
        exportSession.timeRange = timeRange

        if let videoComposition = await makeVideoComposition(url: sourceURL, rotationQuarters: rotationQuarters, cropRect: cropRect) {
            exportSession.videoComposition = videoComposition
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperEdit-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        try await exportSession.export(to: outputURL, as: .mp4)
        return outputURL
    }

    /// Lossless pure-rotation export. Inserts the source tracks into a composition (a reference
    /// copy — no pixel work), rewrites only the video track's `preferredTransform` to bake in the
    /// user rotation, and remuxes via passthrough. The encoded video/audio samples are copied
    /// verbatim, so resolution and quality are preserved and the export is near-instant.
    private static func exportRotationLossless(sourceURL: URL, rotationQuarters quarters: Int) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipEditError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipEditError.cannotCreateExportSession
        }
        try videoTrack.insertTimeRange(fullRange, of: sourceVideo, at: .zero)

        // Carry audio through unchanged (best-effort — clips may have none).
        if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(fullRange, of: sourceAudio, at: .zero)
        }

        // Orientation metadata only: source preferredTransform composed with the user rotation,
        // normalized so the rotated content sits in positive coordinates (same math the render
        // path uses; the render size is irrelevant for a preferredTransform).
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let (transform, _) = EditMath.rotation(naturalSize: naturalSize, preferredTransform: preferredTransform, quarters: quarters)
        videoTrack.preferredTransform = transform

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipEditError.cannotCreateExportSession
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperEdit-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)
        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    /// Builds a rotation/crop video composition for the asset, or nil when no edit needs one.
    /// Reused for both export and live preview (AVPlayerItem.videoComposition).
    static func makeVideoComposition(
        url: URL,
        rotationQuarters: Int,
        cropRect: CGRect? = nil
    ) async -> AVMutableVideoComposition? {
        let quarters = ((rotationQuarters % 4) + 4) % 4
        let crop = (cropRect.map { !EditMath.isIdentityCrop($0) } ?? false) ? cropRect : nil
        guard quarters != 0 || crop != nil else { return nil }
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 30

        var (transform, renderSize) = EditMath.rotation(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            quarters: quarters
        )

        if let crop {
            (transform, renderSize) = EditMath.applyCrop(crop, transform: transform, renderSize: renderSize)
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        return videoComposition
    }
}
