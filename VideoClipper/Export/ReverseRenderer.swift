//
//  ReverseRenderer.swift
//  VideoClipper
//
//  Pre-renders a reversed copy of a clip's video track (silent — the timeline
//  has no audio). AVFoundation can't play a composition track backwards, so
//  reversed layers reference this file instead. Frames are processed in chunks
//  from the tail so long recordings never hold every frame in memory. Output is
//  cached in the temp directory keyed by (source path, mtime).
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum ReverseRendererError: LocalizedError {
    case noVideoTrack
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The clip has no video track"
        case .readFailed: "Couldn't read the clip's frames"
        case .writeFailed: "Couldn't write the reversed clip"
        }
    }
}

nonisolated enum ReverseRenderer {
    static func render(sourceURL: URL) async throws -> URL {
        let output = cacheURL(for: sourceURL)
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReverseRendererError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)

        // Pass 1: every frame's presentation time (compressed read — cheap).
        var times: [CMTime] = []
        let scanReader = try AVAssetReader(asset: asset)
        let scanOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        scanReader.add(scanOutput)
        scanReader.startReading()
        while let sample = scanOutput.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, CMSampleBufferGetNumSamples(sample) > 0 { times.append(time) }
        }
        guard scanReader.status == .completed, !times.isEmpty else {
            throw ReverseRendererError.readFailed
        }
        times.sort { $0 < $1 }   // decode order can differ from presentation order

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperReversing-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = preferredTransform
        // Deviation from brief: sourcePixelBufferAttributes: nil made the adaptor's
        // internal pool assume a default pixel format that didn't match the 32BGRA
        // buffers read below, and every append failed with AVFoundationErrorDomain
        // -11800 (underlying -16364). Declaring the same format/dimensions the
        // reader produces fixes it.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(naturalSize.width),
                kCVPixelBufferHeightKey as String: Int(naturalSize.height),
            ])
        guard writer.canAdd(input) else { throw ReverseRendererError.writeFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Pass 2: decode chunks from the tail; source frame i (whose display
        // window ends at end_i) plays at (duration − end_i), which mirrors the
        // movie while preserving every frame's own duration.
        // Deviation from brief: chunkSize was 30. At 30 — and at 15, 10, and 5 —
        // appends eventually fail with AVFoundationErrorDomain -11800 (underlying
        // -16364, a VideoToolbox malfunction), reproducibly, after several
        // chunks/readers have cycled. Suspecting AVAssetReaderTrackOutput's small
        // internal buffer pool being starved by holding a chunk's worth of its
        // buffers, we deep-copied every decoded frame into an independently
        // allocated buffer immediately on read (see deepCopy below) and released
        // the reader's own buffer right away — that hypothesis did NOT hold: the
        // same -16364 still reproduced at 30 and at 5 with copies in place. The
        // deep-copy is kept anyway (it's strictly more correct — memory no longer
        // depends on the reader's pool), but the actual fix, empirically, is
        // keeping the chunk small. Verified reliably clean at 3 (repeated fresh-
        // cache runs, ~7s each, all ~196 chunk transitions succeeding); the real
        // root cause is still unknown — see the task report for what was ruled
        // out and what's worth investigating further.
        let chunkSize = 3
        var chunkUpper = times.count   // exclusive
        while chunkUpper > 0 {
            let chunkLower = max(0, chunkUpper - chunkSize)
            let rangeEnd = chunkUpper < times.count ? times[chunkUpper] : assetDuration
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: times[chunkLower], end: rangeEnd)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(readerOutput)
            reader.startReading()
            var frames: [(time: CMTime, buffer: CVPixelBuffer)] = []
            while let sample = readerOutput.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    // Deep-copy immediately and let the reader's vended buffer go,
                    // rather than retaining a whole chunk's worth of buffers straight
                    // out of AVAssetReaderTrackOutput's own pool. Decoupling from that
                    // pool is correct regardless (frames.count no longer bounds live
                    // pool buffers), though it did NOT fix the -16364 malfunction below
                    // on its own — see the chunkSize comment.
                    guard let copy = deepCopy(buffer) else { throw ReverseRendererError.readFailed }
                    frames.append((CMSampleBufferGetPresentationTimeStamp(sample), copy))
                }
            }
            guard reader.status == .completed else { throw ReverseRendererError.readFailed }
            frames.sort { $0.time < $1.time }

            // Pair decoded frames with their global indices (the reader can clip
            // chunk edges, so pair from the back where alignment is exact).
            let indices = Array(chunkLower..<chunkUpper).suffix(frames.count)
            for (frame, index) in zip(frames, indices).reversed() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let frameEnd = index + 1 < times.count ? times[index + 1] : assetDuration
                let newTime = assetDuration - frameEnd
                if !adaptor.append(frame.buffer, withPresentationTime: newTime) {
                    throw ReverseRendererError.writeFailed
                }
            }
            chunkUpper = chunkLower
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ReverseRendererError.writeFailed }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temp, to: output)
        return output
    }

    /// Deep-copies a decoded frame into its own IOSurface-backed buffer, independent
    /// of the reader's internal pool (see the call site for why that matters).
    private static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var copyBox: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &copyBox)
        guard status == kCVReturnSuccess, let copy = copyBox else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(copy) else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(srcStride, dstStride, width * 4)
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstStride), srcBase.advanced(by: row * srcStride), rowBytes)
        }
        return copy
    }

    private static func cacheURL(for source: URL) -> URL {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 5381
        for byte in "\(source.path)|\(mtime)".utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoClipperReversed-\(hash).mov")
    }
}
