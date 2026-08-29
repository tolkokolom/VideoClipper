//
//  FrameHandoffExporterTests.swift
//  VideoClipperTests
//
//  End-to-end frame handoff export against the bundled SampleClip.mov: real
//  AVAssetImageGenerator, real files. The source is copied into a temp directory
//  first, because the export lands beside its source.
//

@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import VideoClipper

struct FrameHandoffExporterTests {
    /// Copies the bundled sample into a fresh temp directory and returns its URL there.
    private func temporarySample() throws -> URL {
        let bundled = try #require(
            Bundle(for: BundleToken.self).url(forResource: "SampleClip", withExtension: "mov"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameHandoffTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("mybug.mov")
        try FileManager.default.copyItem(at: bundled, to: copy)
        return copy
    }

    private func pixelSize(of url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        return CGSize(width: width, height: height)
    }

    @Test func exportWritesJpegsManifestAndClipboardText() async throws {
        let source = try temporarySample()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let markers = [
            FrameMarker(time: 0.2, note: "first"),
            FrameMarker(time: 0.8),
        ]
        let result = try await FrameHandoffExporter.export(
            sourceURL: source, markers: markers, rotationQuarters: 0, cropRect: nil)

        #expect(result.folder.lastPathComponent == "mybug-frames")
        let frame1 = result.folder.appendingPathComponent("01_t0.20s.jpg")
        let frame2 = result.folder.appendingPathComponent("02_t0.80s.jpg")
        #expect(FileManager.default.fileExists(atPath: frame1.path))
        #expect(FileManager.default.fileExists(atPath: frame2.path))

        // frames.md stays relative (the folder is self-contained and movable).
        let manifest = try String(
            contentsOf: result.folder.appendingPathComponent("frames.md"), encoding: .utf8)
        #expect(manifest.contains("— 01_t0.20s.jpg"))
        #expect(manifest.contains("note: first"))

        // The clipboard payload carries absolute paths an agent can open directly.
        #expect(result.clipboardText.contains("— \(frame1.path)"))
        #expect(result.clipboardText.contains("(Δ+0.60s) — \(frame2.path)"))

        let size = try pixelSize(of: frame1)
        #expect(size.width > 0 && size.width <= 1568)
        #expect(size.height > 0 && size.height <= 1568)
    }

    @Test func exportAppliesStagedCropToFrames() async throws {
        let source = try temporarySample()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let result = try await FrameHandoffExporter.export(
            sourceURL: source, markers: [FrameMarker(time: 0.2)],
            rotationQuarters: 1, cropRect: crop)

        // Expected geometry mirrors the video exporter: rotate, then crop.
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let (_, rotated) = EditMath.rotation(
            naturalSize: naturalSize, preferredTransform: transform, quarters: 1)
        let (_, expected) = EditMath.applyCrop(crop, transform: .identity, renderSize: rotated)

        let size = try pixelSize(of: result.folder.appendingPathComponent("01_t0.20s.jpg"))
        // Compare aspect (not raw size) so the max-dimension downscale can't skew it.
        #expect(abs(size.width / size.height - expected.width / expected.height) < 0.05)
    }

    @Test func exportHonorsMaxDimension() async throws {
        let source = try temporarySample()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await FrameHandoffExporter.export(
            sourceURL: source, markers: [FrameMarker(time: 0.2)],
            rotationQuarters: 0, cropRect: nil, maxDimension: 64)

        let size = try pixelSize(of: result.folder.appendingPathComponent("01_t0.20s.jpg"))
        #expect(max(size.width, size.height) <= 64)
    }
}

private final class BundleToken {}
