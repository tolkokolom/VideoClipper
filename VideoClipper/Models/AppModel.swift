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
    /// True while a marker note field has focus — bare-key menu shortcuts
    /// (I/O/M/space/arrows) disable themselves so typing isn't hijacked.
    var isEditingNote = false
    /// Marker hovered in the timeline lane or the panel — the counterpart highlights.
    var highlightedMarkerID: FrameMarker.ID?
    /// One-shot request (consumed by MarkerPanel) to focus a marker's note field.
    var noteFocusRequest: FrameMarker.ID?
    /// Bumped when video interaction (scrub, play) should drop note-field focus, so
    /// M works right after scrubbing without pressing Enter first. MarkerPanel listens.
    private(set) var noteBlurSignal = 0

    /// Drops note-field focus if a note is being edited.
    func endNoteEditing() {
        guard isEditingNote else { return }
        noteBlurSignal += 1
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    /// Guards async preview-composition application against clip switches mid-await.
    @ObservationIgnored private var previewGeneration = 0

    enum Tool { case trim, crop, marker }

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

    /// Adds dropped/opened URLs that look like videos and focuses the editor on the
    /// first clip of the batch. Re-dropping a file already in the bin focuses that
    /// clip instead. Returns true when the drop did something (added or focused).
    @discardableResult
    func addClips(urls: [URL]) -> Bool {
        let accepted = urls.filter { url in
            guard !clips.contains(where: { $0.url == url }) else { return false }
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
        }
        guard !accepted.isEmpty else {
            if let existing = urls.lazy.compactMap({ url in self.clips.first(where: { $0.url == url }) }).first {
                select(existing)
                return true
            }
            return false
        }

        for url in accepted {
            let clip = Clip(url: url)
            clips.append(clip)
            clip.startLoading()
        }
        if let first = clips.first(where: { $0.url == accepted[0] }) {
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

    /// Strip drag: like seek, but also ends note editing — the user has moved on to
    /// navigating the video, and M should mark again without an Enter first.
    func scrub(to seconds: Double) {
        endNoteEditing()
        seek(to: seconds)
    }

    func togglePlay() {
        guard let clip = selectedClip else { return }
        endNoteEditing()
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

    // MARK: - Frame markers

    /// Times within this window count as the same frame when toggling — well under one
    /// frame even at 60 fps, so markers on adjacent stepped frames never collide.
    private let markerEpsilon = 0.01

    /// The marker sitting under the playhead, if any.
    var markerAtPlayhead: FrameMarker? {
        selectedClip?.markers.first { abs($0.time - currentTime) < markerEpsilon }
    }

    private var markerIndexAtPlayhead: Int? {
        selectedClip?.markers.firstIndex { abs($0.time - currentTime) < markerEpsilon }
    }

    /// Adds a marker at the playhead, or removes the one already sitting there.
    func toggleMarker() {
        guard let clip = selectedClip else { return }
        if let index = markerIndexAtPlayhead {
            clip.markers.remove(at: index)
        } else {
            clip.markers.append(FrameMarker(time: currentTime))
            clip.markers.sort { $0.time < $1.time }
        }
    }

    // MARK: - Paint

    /// Swatch used for the next stroke.
    var paintColor: PaintColor = .red
    /// Brush thickness for the next stroke, normalized to the frame width.
    var paintWidth: CGFloat = PaintStroke.defaultWidth
    /// Shape drawn by the next canvas drag.
    var paintShape: PaintShapeKind = .freehand
    /// True while the paint select tool is active — canvas drags select/move/scale
    /// strokes instead of drawing.
    var isSelectingStroke = false
    /// The stroke selected for editing (must belong to the marker under the playhead).
    var selectedStrokeID: PaintStroke.ID?

    /// Adds a freehand stroke (normalized points) to the marker under the playhead,
    /// marking the frame first when it isn't marked yet — drawing implies marking.
    func addStroke(points: [CGPoint]) {
        guard let clip = selectedClip, !points.isEmpty else { return }
        if markerIndexAtPlayhead == nil {
            toggleMarker()
        }
        guard let index = markerIndexAtPlayhead else { return }
        clip.markers[index].strokes.append(
            PaintStroke(kind: paintShape, points: points, color: paintColor, width: paintWidth))
    }

    /// Removes the most recent stroke of the marker under the playhead.
    func undoStroke() {
        guard let clip = selectedClip, let index = markerIndexAtPlayhead,
              !clip.markers[index].strokes.isEmpty else { return }
        clip.markers[index].strokes.removeLast()
    }

    /// Removes every stroke of the marker under the playhead.
    func clearStrokes() {
        guard let clip = selectedClip, let index = markerIndexAtPlayhead else { return }
        clip.markers[index].strokes.removeAll()
        selectedStrokeID = nil
    }

    /// (marker index, stroke index) of the selected stroke — nil when the selection
    /// doesn't belong to the marker under the playhead.
    private var selectedStrokeLocation: (marker: Int, stroke: Int)? {
        guard let clip = selectedClip, let markerIndex = markerIndexAtPlayhead,
              let id = selectedStrokeID,
              let strokeIndex = clip.markers[markerIndex].strokes.firstIndex(where: { $0.id == id })
        else { return nil }
        return (markerIndex, strokeIndex)
    }

    func deleteSelectedStroke() {
        guard let clip = selectedClip, let location = selectedStrokeLocation else { return }
        clip.markers[location.marker].strokes.remove(at: location.stroke)
        selectedStrokeID = nil
    }

    /// Moves the selected stroke by a normalized delta.
    func translateSelectedStroke(by delta: CGPoint) {
        guard let clip = selectedClip, let location = selectedStrokeLocation else { return }
        clip.markers[location.marker].strokes[location.stroke] =
            StrokeGeometry.translated(clip.markers[location.marker].strokes[location.stroke], by: delta)
    }

    /// Scales the selected stroke about a normalized anchor.
    func scaleSelectedStroke(by factors: CGSize, anchor: CGPoint) {
        guard let clip = selectedClip, let location = selectedStrokeLocation,
              factors.width.isFinite, factors.height.isFinite else { return }
        clip.markers[location.marker].strokes[location.stroke] =
            StrokeGeometry.scaled(
                clip.markers[location.marker].strokes[location.stroke],
                by: factors, anchor: anchor)
    }

    /// Timeline pin clicked: show that frame, open the Mark tool, and ask the panel
    /// to put the cursor into the marker's note field.
    func requestNoteFocus(_ marker: FrameMarker) {
        seek(to: marker.time)
        if activeTool != .marker {
            activeTool = .marker
            applyPreviewComposition()   // leaving Crop must restore the staged preview
        }
        noteFocusRequest = marker.id
    }

    /// Return pressed outside a text field: edit the note of the marker under the
    /// playhead (the natural follow-up to M, which leaves the playhead on it).
    func editNoteAtPlayhead() {
        guard let marker = markerAtPlayhead else { return }
        requestNoteFocus(marker)
    }

    /// Seeks to the next (+1) or previous (-1) marker; stays put past the ends.
    func jumpToMarker(offset: Int) {
        guard let clip = selectedClip else { return }
        let times = clip.markers.map(\.time)
        let target = offset > 0
            ? times.first(where: { $0 > currentTime + markerEpsilon })
            : times.last(where: { $0 < currentTime - markerEpsilon })
        if let target { seek(to: target) }
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

    /// Injectable for tests, so a test run never clobbers the real clipboard.
    @ObservationIgnored var writeClipboard: (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Exports the marked frames as a handoff folder and puts the absolute-path
    /// manifest on the clipboard — ready to ⌘V into a coding agent.
    func exportMarkedFrames() {
        guard let clip = selectedClip, clip.isLoaded, !clip.frameExportState.isExporting else { return }
        guard !clip.markers.isEmpty else {
            errorMessage = "No frames marked — press M at the playhead first."
            return
        }
        clip.frameExportState = .exporting
        let markers = clip.markers
        let quarters = clip.rotationQuarters
        let crop = clip.isCropped ? clip.cropRect : nil
        Task {
            do {
                let result = try await FrameHandoffExporter.export(
                    sourceURL: clip.url, markers: markers, rotationQuarters: quarters, cropRect: crop)
                self.writeClipboard(result.clipboardText)
                clip.frameExportState = .done(result.folder)
            } catch {
                clip.frameExportState = .failed(error.localizedDescription)
                self.errorMessage = "Couldn't export frames: \(error.localizedDescription)"
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
