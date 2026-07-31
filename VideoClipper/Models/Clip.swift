//
//  Clip.swift
//  VideoClipper
//
//  One dropped video file plus its staged (unsaved) edits. Edits live on the clip —
//  not on the editor — so switching clips in the filmstrip never loses work.
//

@preconcurrency import AVFoundation
import AppKit
import Observation

enum ExportState {
    case idle
    case exporting
    case done(URL)
    case failed(String)

    var isExporting: Bool { if case .exporting = self { true } else { false } }
    var exportedURL: URL? { if case .done(let url) = self { url } else { nil } }
}

@Observable
final class Clip: Identifiable {
    let id = UUID()
    let url: URL

    var duration: Double = 0
    /// Displayed aspect of the source (orientation-resolved), before any user rotation.
    var videoAspect: CGFloat = 16.0 / 9.0
    var posterImage: NSImage?
    var stripThumbnails: [NSImage] = []
    var isLoaded = false
    var loadFailed = false

    // Staged edits.
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var rotationSteps = 0
    /// Normalized (0…1, top-left origin) in the displayed, post-rotation video.
    var cropRect = EditMath.identityCrop
    var cropAspect: CropAspect = .original

    var exportState: ExportState = .idle

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    /// Kicks off the async metadata/poster load once. Kept as a handle so thumbnail
    /// generation can await it — selecting a clip right after dropping it must not race
    /// the load (a zero duration would skip thumbnails permanently).
    func startLoading() {
        guard loadTask == nil else { return }
        loadTask = Task { await self.load() }
    }

    var rotationQuarters: Int { ((rotationSteps % 4) + 4) % 4 }
    /// Displayed aspect after user rotation, before crop.
    var rotatedAspect: CGFloat { rotationQuarters % 2 == 0 ? videoAspect : 1 / videoAspect }
    /// Displayed aspect after rotation and the staged crop — what the preview shows.
    var previewAspect: CGFloat {
        isCropped ? rotatedAspect * cropRect.width / cropRect.height : rotatedAspect
    }

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
    var isTrimmed: Bool { duration > 0 && (trimStart > 0.05 || trimEnd < duration - 0.05) }
    var isCropped: Bool { !EditMath.isIdentityCrop(cropRect) }
    var isRotated: Bool { rotationQuarters != 0 }
    var hasEdits: Bool { isTrimmed || isCropped || isRotated }

    /// Loads duration, orientation-resolved aspect, and a filmstrip poster frame.
    func load() async {
        let asset = AVURLAsset(url: url)
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        duration = max(0.1, durationTime.seconds)
        trimStart = 0
        trimEnd = duration

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            loadFailed = true
            AppLog.editor.error("load: no video track in \(self.url.lastPathComponent, privacy: .public)")
            return
        }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let resolved = size.applying(transform)
        let w = abs(resolved.width), h = abs(resolved.height)
        if w > 0, h > 0 { videoAspect = w / h }

        if let data = await Self.thumbnailDatas(url: url, duration: duration, count: 1).first {
            posterImage = NSImage(data: data)
        }
        isLoaded = true
        AppLog.editor.info("load done: \(self.url.lastPathComponent, privacy: .public) \(self.duration, format: .fixed(precision: 2))s")
    }

    /// Generates the trim strip's thumbnails (lazily, first time the clip is selected).
    func loadStripThumbnails() async {
        await loadTask?.value
        guard stripThumbnails.isEmpty, duration > 0, !loadFailed else { return }
        let datas = await Self.thumbnailDatas(url: url, duration: duration, count: 10)
        stripThumbnails = datas.compactMap { NSImage(data: $0) }
    }

    /// Off-main thumbnail generation (the image generator is not Sendable, so it stays here;
    /// JPEG data crosses back to the main actor).
    nonisolated private static func thumbnailDatas(url: URL, duration: Double, count: Int) async -> [Data] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        var datas: [Data] = []
        for index in 0..<count {
            let fraction = (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
                    datas.append(data)
                }
            }
        }
        return datas
    }
}
