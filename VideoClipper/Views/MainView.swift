//
//  MainView.swift
//  VideoClipper
//
//  Window layout: video canvas on top, transport + trim strip + tool row beneath,
//  filmstrip bin along the bottom. The whole window is a drop target for video files.
//

import SwiftUI

struct MainView: View {
    let model: AppModel
    @State private var isDropTargeted = false
    /// Inspection-zoom state for the canvas — a viewing aid, reset on clip
    /// switch, rotation, and entering Crop. Never touches the staged edits.
    @State private var zoomState = ZoomMath.State.identity
    /// True while the wheel/pinch/drag is engaging the zoom — the minimap is only up
    /// while interacting, with a short linger after release (iOS ClipShot semantics).
    @State private var minimapVisible = false
    @State private var minimapHideTask: Task<Void, Never>?
    /// Pop animation for the navigator — gentle, low overshoot.
    private let minimapSpring: Animation = .spring(response: 0.3, dampingFraction: 0.85)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                if let clip = model.selectedClip {
                    ControlsView(model: model, clip: clip)
                }
                FilmstripView(model: model)
            }
            if model.activeTool == .marker, let clip = model.selectedClip {
                MarkerPanel(model: model, clip: clip)
            }
        }
        .background(.black)
        .dropDestination(for: URL.self) { urls, _ in
            model.addClips(urls: urls)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let clip = model.selectedClip, clip.isLoaded {
                    PlayerCanvasView(
                        player: model.player,
                        visibleRect: ZoomMath.visibleRect(zoomState),
                        onWheel: { deltaY, anchor in
                            guard model.activeTool != .crop, model.activeTool != .marker else { return }
                            zoomState = ZoomMath.wheelZoom(
                                zoomState, anchor: anchor, deltaY: deltaY,
                                within: videoFrac(for: clip, in: geo.size)
                            )
                            minimapEngaged(hideAfter: 0.6)
                        },
                        onPinch: { factor, anchor in
                            guard model.activeTool != .crop, model.activeTool != .marker else { return }
                            zoomState = ZoomMath.zoom(
                                zoomState, anchor: anchor, factor: factor,
                                within: videoFrac(for: clip, in: geo.size)
                            )
                            minimapEngaged(hideAfter: nil)
                        },
                        onPan: { dxFrac, dyFrac in
                            guard model.activeTool != .crop, model.activeTool != .marker,
                                  zoomState.zoom > 1 else { return }
                            zoomState = ZoomMath.pan(
                                zoomState, dxFrac: dxFrac, dyFrac: dyFrac,
                                within: videoFrac(for: clip, in: geo.size)
                            )
                            minimapEngaged(hideAfter: nil)
                        },
                        onInteractionEnd: { minimapScheduleHide(after: 0.2) }
                    )
                    if model.activeTool == .crop {
                        CropOverlay(
                            videoRect: EditMath.fit(aspect: clip.rotatedAspect, in: geo.size),
                            aspect: clip.cropAspect.ratio ?? clip.rotatedAspect,
                            cropRect: Bindable(clip).cropRect
                        )
                    }
                    if model.activeTool == .marker {
                        PaintOverlay(
                            model: model,
                            videoRect: EditMath.fit(aspect: clip.previewAspect, in: geo.size)
                        )
                    }
                } else if model.clips.isEmpty {
                    dropHint
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .topLeading) {
                if model.activeTool != .crop, let clip = model.selectedClip, clip.isLoaded {
                    ZoomMinimap(
                        displayedAspect: clip.previewAspect,
                        visible: ZoomMath.videoViewport(
                            canvasVisible: ZoomMath.visibleRect(zoomState),
                            video: videoFrac(for: clip, in: geo.size)
                        )
                    )
                        .scaleEffect(minimapVisible ? 1 : 0.5)
                        .opacity(minimapVisible ? 1 : 0)
                        .padding(14)
                        .allowsHitTesting(false)
                        .animation(minimapSpring, value: minimapVisible)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedClipID) { resetZoom() }
        .onChange(of: model.selectedClip?.rotationQuarters) { resetZoom() }
        .onChange(of: model.activeTool) {
            // Crop and Mark both need the unzoomed frame (Mark: paint coordinates
            // map straight onto the fitted rect only at 1x).
            if model.activeTool == .crop || model.activeTool == .marker { resetZoom() }
        }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Drop videos here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or press ⌘O to open files")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    /// Show the minimap now (if actually zoomed in); optionally schedule a hide —
    /// wheel events have no "release", so each tick re-arms a 0.6s linger.
    private func minimapEngaged(hideAfter delay: Double?) {
        minimapHideTask?.cancel()
        if zoomState.zoom > 1.05 {
            withAnimation(minimapSpring) { minimapVisible = true }
        }
        if let delay { minimapScheduleHide(after: delay) }
    }

    /// Hide with a linger; a quick re-engagement cancels the pending hide, so the
    /// pop reverses smoothly mid-dissolve instead of restarting.
    private func minimapScheduleHide(after delay: Double) {
        minimapHideTask?.cancel()
        minimapHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(minimapSpring) { minimapVisible = false }
        }
    }

    private func resetZoom() {
        zoomState = .identity
        minimapHideTask?.cancel()
        minimapVisible = false
    }

    /// The fitted video's rect, normalized to canvas coordinates (0…1, top-left origin) —
    /// zoom/pan clamp against this instead of the full canvas, and the minimap maps its
    /// yellow box onto it. `previewAspect` matches what's actually rendered (rotation +
    /// staged crop), same aspect the minimap's white frame already uses.
    private func videoFrac(for clip: Clip, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return ZoomMath.fullCanvas }
        let r = EditMath.fit(aspect: clip.previewAspect, in: size)
        return CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }
}

/// Transport, trim strip, and the tool row for the selected clip.
private struct ControlsView: View {
    let model: AppModel
    @Bindable var clip: Clip

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { model.togglePlay() }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")

                Text("\(timeString(playheadDisplayTime)) / \(timeString(clip.trimmedDuration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if model.activeTool == .crop {
                    Picker("Aspect", selection: aspectBinding) {
                        ForEach(CropAspect.allCases) { aspect in
                            Text(aspect.label).tag(aspect)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // In Mark mode the lane is always up — it carries the mark-here button.
            if !clip.markers.isEmpty || model.activeTool == .marker {
                markerNoteLane
            }

            TrimStrip(
                thumbnails: clip.stripThumbnails,
                duration: clip.duration,
                minTrim: model.minTrim,
                isTrimming: model.activeTool == .trim,
                trimStart: $clip.trimStart,
                trimEnd: $clip.trimEnd,
                playhead: model.currentTime,
                markers: clip.markers.map(\.time),
                onScrub: { model.scrub(to: $0) }
            )
            .frame(height: 44)

            HStack(spacing: 8) {
                toolButton("Rotate", systemImage: "rotate.right", isActive: false, hasEdit: clip.isRotated) {
                    model.rotate()
                }
                .help("Rotate 90° clockwise (⌘R)")

                toolButton("Trim", systemImage: "scissors", isActive: model.activeTool == .trim, hasEdit: clip.isTrimmed) {
                    model.toggleTool(.trim)
                }
                .help("Trim — drag handles, or I/O at the playhead")

                toolButton("Crop", systemImage: "crop", isActive: model.activeTool == .crop, hasEdit: clip.isCropped) {
                    model.toggleTool(.crop)
                }
                .help("Crop — drag the frame, resize from corners")

                toolButton("Mark", systemImage: "bookmark", isActive: model.activeTool == .marker,
                           hasEdit: !clip.markers.isEmpty, dotColor: .cyan) {
                    model.toggleTool(.marker)
                }
                .help("Frame markers — M at the playhead; ⌘E copies frames for an agent")

                Spacer()

                if clip.exportState.isExporting {
                    ProgressView().controlSize(.small)
                }

                Menu {
                    Button("Export As…") { model.exportSelected(chooseDestination: true) }
                    if let exported = clip.exportState.exportedURL {
                        Button("Show Export in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([exported])
                        }
                    }
                    Divider()
                    Button("Copy Frames for Agent") { model.exportMarkedFrames() }
                        .disabled(clip.markers.isEmpty)
                    if let folder = clip.frameExportState.exportedURL {
                        Button("Show Frames in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                } label: {
                    Text("Export")
                } primaryAction: {
                    model.exportSelected()
                }
                .fixedSize()
                .disabled(!clip.hasEdits || clip.exportState.isExporting)
                .help("Export beside the original (⌘S); Export As… (⇧⌘S)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    /// Playhead time relative to the (possibly trimmed) range, clamped — so the readout
    /// reads `0:00 / trimmedDuration` regardless of where the scrub seeks the player.
    private var playheadDisplayTime: Double {
        min(max(model.currentTime - clip.trimStart, 0), clip.trimmedDuration)
    }

    private var aspectBinding: Binding<CropAspect> {
        Binding(
            get: { clip.cropAspect },
            set: { model.setCropAspect($0) }
        )
    }

    private func toolButton(
        _ title: String,
        systemImage: String,
        isActive: Bool,
        hasEdit: Bool,
        dotColor: Color = .yellow,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .overlay(alignment: .topTrailing) {
                    if hasEdit {
                        Circle().fill(dotColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 8, y: -4)
                    }
                }
        }
        .buttonStyle(.bordered)
        .tint(isActive ? Color.accentColor : nil)
    }

    /// Thin lane above the strip: one pin per marker at its timeline position.
    /// Hover highlights the marker's row in the side panel (and vice versa); click
    /// shows the frame, opens the Mark tool, and focuses the note field.
    private var markerNoteLane: some View {
        GeometryReader { geo in
            ForEach(clip.markers) { marker in
                let fraction = marker.time / max(clip.duration, 0.001)
                let x = min(max(CGFloat(fraction) * geo.size.width, 8), geo.size.width - 8)
                let isHighlighted = model.highlightedMarkerID == marker.id
                Image(systemName: "pin.fill")
                    .font(.system(size: isHighlighted ? 12 : 9))
                    .foregroundStyle(isHighlighted ? Color.white : .cyan)
                    .frame(width: 14, height: 16)
                    .contentShape(.rect)
                    .position(x: x, y: 8)
                    .onHover { hovering in
                        if hovering {
                            model.highlightedMarkerID = marker.id
                        } else if model.highlightedMarkerID == marker.id {
                            model.highlightedMarkerID = nil
                        }
                    }
                    .onTapGesture { model.requestNoteFocus(marker) }
                    .help(marker.note.isEmpty ? "Click to add a note" : marker.note)
            }

            // Quick action riding the playhead: mark this frame (or unmark, when
            // the playhead already sits on a marker). Same action as M.
            if model.activeTool == .marker {
                let x = min(max(
                    CGFloat(model.currentTime / max(clip.duration, 0.001)) * geo.size.width,
                    14), geo.size.width - 14)
                let onMarker = model.markerAtPlayhead != nil
                Button { model.toggleMarker() } label: {
                    Image(systemName: onMarker ? "xmark" : "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(onMarker ? .white : .black)
                        .frame(width: 24, height: 14)
                        .background(
                            onMarker ? Color.gray.opacity(0.65) : Color.cyan,
                            in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .position(x: x, y: 8)
                .help(onMarker ? "Remove this marker (M)" : "Mark this frame (M)")
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: model.highlightedMarkerID)
    }

    private func timeString(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let tenths = Int((clamped - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
    }
}
