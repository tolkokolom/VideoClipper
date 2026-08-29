//
//  FrameHandoffExporter.swift
//  VideoClipper
//
//  Exports the marked frames of a clip as a handoff folder: downscaled JPEGs plus
//  a frames.md manifest, with an absolute-path manifest returned for the clipboard.
//  Staged crop/rotation applies via the same video composition the preview and the
//  video export use, so a frame looks exactly like what the canvas shows.
//

@preconcurrency import AVFoundation
import AppKit
import Foundation

nonisolated enum FrameHandoffError: LocalizedError {
    case frameGenerationFailed(Double)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .frameGenerationFailed(let time):
            String(format: "Couldn't grab the frame at %.2fs", time)
        case .imageEncodingFailed:
            "Couldn't encode a frame as JPEG"
        }
    }
}

nonisolated enum FrameHandoffExporter {
    struct Result {
        let folder: URL
        /// The manifest with absolute frame paths — one ⌘V hands an agent the
        /// timing context plus paths it can open itself.
        let clipboardText: String
    }

    /// Coding-agent vision downscales anything larger anyway, so bigger is pure waste.
    static let defaultMaxDimension: CGFloat = 1568

    static func export(
        sourceURL: URL,
        markers: [FrameMarker],
        rotationQuarters: Int,
        cropRect: CGRect? = nil,
        maxDimension: CGFloat = defaultMaxDimension
    ) async throws -> Result {
        let sorted = markers.sorted { $0.time < $1.time }
        let asset = AVURLAsset(url: sourceURL)
        let duration = ((try? await asset.load(.duration)) ?? .zero).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let composition = await ClipEditExporter.makeVideoComposition(
            url: sourceURL, rotationQuarters: rotationQuarters, cropRect: cropRect) {
            generator.videoComposition = composition
        } else {
            generator.appliesPreferredTrackTransform = true
        }

        let folder = FrameHandoff.nextAvailableFolder(besides: sourceURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (offset, marker) in sorted.enumerated() {
            let time = CMTime(seconds: marker.time, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else {
                throw FrameHandoffError.frameGenerationFailed(marker.time)
            }
            let scaled = downscale(cgImage, toFit: maxDimension)
            let painted = PaintRenderer.bake(strokes: marker.strokes, into: scaled)
            let rep = NSBitmapImageRep(cgImage: painted)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                throw FrameHandoffError.imageEncodingFailed
            }
            let filename = FrameHandoff.frameFilename(index: offset + 1, time: marker.time)
            try data.write(to: folder.appendingPathComponent(filename))
        }

        let name = sourceURL.lastPathComponent
        let relative = FrameHandoff.manifest(
            sourceName: name, duration: duration, markers: sorted, basePath: nil)
        try relative.write(
            to: folder.appendingPathComponent("frames.md"), atomically: true, encoding: .utf8)
        let absolute = FrameHandoff.manifest(
            sourceName: name, duration: duration, markers: sorted, basePath: folder.path)
        AppLog.export.info("frame handoff: \(sorted.count) frame(s) → \(folder.lastPathComponent, privacy: .public)")
        return Result(folder: folder, clipboardText: absolute)
    }

    /// Proportional downscale so the longest edge fits `maxDimension`; full-size
    /// frames pass through untouched. Done in code (not generator.maximumSize)
    /// so it behaves identically with and without a video composition.
    private static func downscale(_ image: CGImage, toFit maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height, 1))
        guard scale < 1 else { return image }
        let newWidth = Int((width * scale).rounded()), newHeight = Int((height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: newWidth, height: newHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
}
