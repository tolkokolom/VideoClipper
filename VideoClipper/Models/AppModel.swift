//
//  AppModel.swift
//  VideoClipper
//
//  Central app state: the clip bin, the shared player, the active tool, and export
//  orchestration. One AVPlayer is reused across clips (ClipShot's model); staged
//  edits live on each Clip.
//

@preconcurrency import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class AppModel {
    var clips: [Clip] = []
    var selectedClipID: Clip.ID?
    var activeTool: Tool?
    var isPlaying = false
    var currentTime: Double = 0
    var errorMessage: String?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    /// Guards async preview-composition application against clip switches mid-await.
    @ObservationIgnored private var previewGeneration = 0

    enum Tool { case trim, crop }

    let minTrim: Double = 1

    var selectedClip: Clip? { clips.first { $0.id == selectedClipID } }

    init() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playbackTick(time.seconds)
            }
        }
    }

    // MARK: - Bin

    /// Adds dropped/opened URLs that look like videos; selects the first added clip
    /// if nothing is selected yet. Returns true when at least one clip was accepted.
    @discardableResult
    func addClips(urls: [URL]) -> Bool {
        let accepted = urls.filter { url in
            guard !clips.contains(where: { $0.url == url }) else { return false }
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
        }
        guard !accepted.isEmpty else { return false }

        for url in accepted {
            let clip = Clip(url: url)
            clips.append(clip)
            Task { await clip.load() }
        }
        if selectedClipID == nil, let first = clips.first(where: { $0.url == accepted[0] }) {
            select(first)
        }
        AppLog.app.info("added \(accepted.count) clip(s)")
        return true
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video]
        guard panel.runModal() == .OK else { return }
        addClips(urls: panel.urls)
    }

    func select(_ clip: Clip) {
        guard clip.id != selectedClipID else { return }
        selectedClipID = clip.id
        activeTool = nil
        currentTime = clip.trimStart
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: clip.url)))
        applyPreviewComposition()
        seek(to: clip.trimStart)
        player.play()
        Task { await clip.loadStripThumbnails() }
    }

    func selectNeighbor(offset: Int) {
        guard let current = selectedClipID,
              let index = clips.firstIndex(where: { $0.id == current }) else { return }
        let target = index + offset
        guard clips.indices.contains(target) else { return }
        select(clips[target])
    }

    func remove(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips.remove(at: index)
        if selectedClipID == clip.id {
            selectedClipID = nil
            player.replaceCurrentItem(with: nil)
            if let next = clips.indices.contains(index) ? clips[index] : clips.last {
                select(next)
            }
        }
    }

    // MARK: - Playback

    private func playbackTick(_ seconds: Double) {
        currentTime = seconds
        isPlaying = player.rate > 0
        // Preview honours the trim: playback pauses at the out point.
        if let clip = selectedClip, isPlaying, clip.isTrimmed, seconds >= clip.trimEnd {
            player.pause()
            isPlaying = false
        }
    }

    func togglePlay() {
        guard let clip = selectedClip else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
            return
        }
        // Restart inside the trimmed range when the playhead sits at/past the end.
        if currentTime >= clip.trimEnd - 0.05 || currentTime < clip.trimStart {
            seek(to: clip.trimStart)
        }
        player.play()
        isPlaying = true
    }

    /// Scrubs the preview to a specific time (trim strip drags, arrow keys).
    func seek(to seconds: Double) {
        player.pause()
        isPlaying = false
        currentTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        player.pause()
        isPlaying = false
        item.step(byCount: count)
        currentTime = item.currentTime().seconds
    }

    // MARK: - Tools

    func toggleTool(_ tool: Tool) {
        guard let clip = selectedClip else { return }
        activeTool = (activeTool == tool) ? nil : tool
        if activeTool == .crop, !clip.isCropped {
            // Opening Crop with no staged crop: start from the preset's centered frame.
            clip.cropRect = Self.fittedCrop(aspect: clip.cropAspect, in: clip)
        }
        // Crop mode previews the full rotated frame (the overlay shows the crop);
        // any other mode previews the staged edit itself.
        applyPreviewComposition()
    }

    func rotate() {
        guard let clip = selectedClip else { return }
        player.pause()   // rotate against the current still frame, not mid-playback
        isPlaying = false
        clip.rotationSteps += 1
        // A staged crop tracks the content through the rotation instead of being wiped.
        if clip.isCropped {
            clip.cropRect = EditMath.rotatedCrop(clip.cropRect)
        }
        clip.cropAspect = clip.cropAspect.rotated
        applyPreviewComposition()
    }

    func setTrimIn() {
        guard let clip = selectedClip else { return }
        clip.trimStart = max(0, min(currentTime, clip.trimEnd - minTrim))
    }

    func setTrimOut() {
        guard let clip = selectedClip else { return }
        clip.trimEnd = min(clip.duration, max(currentTime, clip.trimStart + minTrim))
    }

    func setCropAspect(_ aspect: CropAspect) {
        guard let clip = selectedClip else { return }
        clip.cropAspect = aspect
        clip.cropRect = Self.fittedCrop(aspect: aspect, in: clip)
    }

    /// Largest centered crop of the preset's aspect, normalized in the rotated frame.
    private static func fittedCrop(aspect: CropAspect, in clip: Clip) -> CGRect {
        guard let ratio = aspect.ratio else { return EditMath.identityCrop }
        // Normalized space is square; fit the ratio against the frame's real aspect.
        let frameAspect = clip.rotatedAspect
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > frameAspect { h = frameAspect / ratio } else { w = ratio / frameAspect }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Reapplies the preview composition for the current clip + tool state.
    /// While cropping: rotation only (the overlay owns the crop). Otherwise: the full
    /// staged edit, so the preview shows exactly what will export.
    func applyPreviewComposition() {
        guard let clip = selectedClip, let item = player.currentItem else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let crop: CGRect? = (activeTool == .crop || !clip.isCropped) ? nil : clip.cropRect
        let quarters = clip.rotationQuarters
        let url = clip.url
        Task {
            let composition = await ClipEditExporter.makeVideoComposition(
                url: url, rotationQuarters: quarters, cropRect: crop)
            guard generation == self.previewGeneration, self.player.currentItem === item else { return }
            item.videoComposition = composition
        }
    }

    // MARK: - Export

    func exportSelected(chooseDestination: Bool = false) {
        guard let clip = selectedClip else { return }
        export(clip, chooseDestination: chooseDestination)
    }

    func export(_ clip: Clip, chooseDestination: Bool = false) {
        guard clip.isLoaded, !clip.exportState.isExporting else { return }
        guard clip.hasEdits else {
            errorMessage = "No edits to export — trim, crop, or rotate first."
            return
        }
        clip.exportState = .exporting
        let range = CMTimeRange(
            start: CMTime(seconds: clip.trimStart, preferredTimescale: 600),
            end: CMTime(seconds: clip.trimEnd, preferredTimescale: 600)
        )
        let crop = clip.isCropped ? clip.cropRect : nil
        let quarters = clip.rotationQuarters
        Task {
            do {
                let temp = try await ClipEditExporter.export(
                    sourceURL: clip.url, timeRange: range, rotationQuarters: quarters, cropRect: crop)
                guard let destination = self.resolveDestination(
                    for: clip, produced: temp, choose: chooseDestination) else {
                    try? FileManager.default.removeItem(at: temp)
                    clip.exportState = .idle
                    return
                }
                try ExportDestination.place(temp, at: destination)
                clip.exportState = .done(destination)
                AppLog.export.info("exported \(clip.url.lastPathComponent, privacy: .public) → \(destination.lastPathComponent, privacy: .public)")
            } catch {
                clip.exportState = .failed(error.localizedDescription)
                self.errorMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    /// Auto-names beside the original, or asks via save panel. nil = user cancelled.
    private func resolveDestination(for clip: Clip, produced temp: URL, choose: Bool) -> URL? {
        let ext = temp.pathExtension
        let auto = ExportDestination.nextAvailable(besides: clip.url, ext: ext)
        guard choose else { return auto }
        let panel = NSSavePanel()
        panel.directoryURL = clip.url.deletingLastPathComponent()
        panel.nameFieldStringValue = auto.lastPathComponent
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
