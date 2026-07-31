//
//  ExporterIntegrationTests.swift
//  VideoClipperTests
//
//  End-to-end export against the bundled SampleClip.mov: real AVFoundation sessions,
//  real files. Verifies the .mp4 re-encode path (trim+crop+rotate) and the lossless
//  .mov rotation fast-path actually produce playable assets with the expected geometry.
//

@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import VideoClipper

struct ExporterIntegrationTests {
    private func sampleURL() throws -> URL {
        let url = Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov")
        return try #require(url)
    }

    @Test func reencodeWithTrimRotationAndCropProducesMp4() async throws {
        let source = try sampleURL()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        try #require(duration > 1)

        let range = CMTimeRange(
            start: CMTime(seconds: 0.2, preferredTimescale: 600),
            end: CMTime(seconds: min(1.2, duration), preferredTimescale: 600)
        )
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let output = try await ClipEditExporter.export(
            sourceURL: source, timeRange: range, rotationQuarters: 1, cropRect: crop)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "mp4")
        let exported = AVURLAsset(url: output)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)

        // Source geometry → rotated render → cropped to half in each dimension.
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        let sourceTransform = try await sourceTrack.load(.preferredTransform)
        let (_, rotatedSize) = EditMath.rotation(
            naturalSize: sourceSize, preferredTransform: sourceTransform, quarters: 1)
        let (_, expectedSize) = EditMath.applyCrop(crop, transform: .identity, renderSize: rotatedSize)
        #expect(abs(naturalSize.width - expectedSize.width) <= 2)
        #expect(abs(naturalSize.height - expectedSize.height) <= 2)

        let exportedDuration = try await exported.load(.duration).seconds
        #expect(abs(exportedDuration - range.duration.seconds) < 0.25)
    }

    @Test func pureRotationTakesLosslessMovFastPath() async throws {
        let source = try sampleURL()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)

        let output = try await ClipEditExporter.export(
            sourceURL: source,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            rotationQuarters: 1,
            cropRect: nil
        )
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "mov")
        let exported = AVURLAsset(url: output)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)

        // Passthrough: sample data untouched (same natural size), rotation carried in
        // the preferredTransform so the *displayed* size is swapped.
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        let sourceTransform = try await sourceTrack.load(.preferredTransform)
        let sourceDisplayed = CGRect(origin: .zero, size: sourceSize).applying(sourceTransform)
        #expect(abs(abs(displayed.width) - abs(sourceDisplayed.height)) < 1)
        #expect(abs(abs(displayed.height) - abs(sourceDisplayed.width)) < 1)
    }
}

private final class BundleToken {}
