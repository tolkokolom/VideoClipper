//
//  ReverseRendererTests.swift
//  VideoClipperTests
//
//  End-to-end reverse render of the bundled SampleClip.mov: real reader/writer.
//

@preconcurrency import AVFoundation
import AppKit
import Foundation
import Testing
@testable import VideoClipper

struct ReverseRendererTests {
    @Test func rendersAReversedPlayableVideoOfTheSameDuration() async throws {
        let source = try #require(
            Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov"))
        let output = try await ReverseRenderer.render(sourceURL: source)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let reversed = AVURLAsset(url: output)
        let duration = try await reversed.load(.duration).seconds
        #expect(abs(duration - sourceDuration) < 0.25)

        let track = try #require(try await reversed.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let sourceTrack = try #require(
            try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        #expect(size == sourceSize)

        // Content actually reversed, not just re-encoded: a frame near the start of
        // the output should resemble the SOURCE's end far more than the source's
        // start. Coarse, generous comparison (a few sample points' average color) —
        // just enough to catch "the renderer silently produced a forward copy."
        let margin = 0.15
        let sourceAsset = AVURLAsset(url: source)
        let sourceStartFrame = try await frame(of: sourceAsset, atSeconds: sourceDuration * margin)
        let sourceEndFrame = try await frame(of: sourceAsset, atSeconds: sourceDuration * (1 - margin))
        let reversedStartFrame = try await frame(of: reversed, atSeconds: duration * margin)

        let distanceToSourceEnd = colorDistance(
            pixelSignature(of: reversedStartFrame), pixelSignature(of: sourceEndFrame))
        let distanceToSourceStart = colorDistance(
            pixelSignature(of: reversedStartFrame), pixelSignature(of: sourceStartFrame))
        #expect(
            distanceToSourceEnd < distanceToSourceStart,
            "the reversed output's start should resemble the source's end, not its start")

        // Cached: a second call answers the same URL without re-rendering.
        let again = try await ReverseRenderer.render(sourceURL: source)
        #expect(again == output)
    }
}

/// Grabs a single frame at an exact time (zero tolerance) with orientation resolved.
private func frame(of asset: AVURLAsset, atSeconds seconds: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.appliesPreferredTrackTransform = true
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    return try await generator.image(at: time).image
}

/// A coarse fingerprint: the average color at a fixed 3×3 grid of sample points,
/// flattened to [r,g,b,r,g,b,...]. Cheap and robust enough to tell "roughly the
/// same picture" from "a clearly different one" without pixel-exact comparison.
private func pixelSignature(of image: CGImage) -> [Double] {
    let rep = NSBitmapImageRep(cgImage: image)
    let points: [(CGFloat, CGFloat)] = [
        (0.2, 0.2), (0.5, 0.2), (0.8, 0.2),
        (0.2, 0.5), (0.5, 0.5), (0.8, 0.5),
        (0.2, 0.8), (0.5, 0.8), (0.8, 0.8),
    ]
    return points.flatMap { (fx, fy) -> [Double] in
        let x = min(max(Int(fx * CGFloat(rep.pixelsWide)), 0), rep.pixelsWide - 1)
        let y = min(max(Int(fy * CGFloat(rep.pixelsHigh)), 0), rep.pixelsHigh - 1)
        let color = (rep.colorAt(x: x, y: y) ?? .black).usingColorSpace(.deviceRGB) ?? .black
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }
}

/// Sum of absolute per-component differences between two signatures.
private func colorDistance(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
}

private final class BundleToken {}
