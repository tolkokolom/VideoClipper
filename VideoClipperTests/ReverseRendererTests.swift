//
//  ReverseRendererTests.swift
//  VideoClipperTests
//
//  End-to-end reverse render of the bundled SampleClip.mov: real reader/writer.
//

@preconcurrency import AVFoundation
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

        // Cached: a second call answers the same URL without re-rendering.
        let again = try await ReverseRenderer.render(sourceURL: source)
        #expect(again == output)
    }
}

private final class BundleToken {}
