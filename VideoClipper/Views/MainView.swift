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

    var body: some View {
        VStack(spacing: 0) {
            canvas
            if let clip = model.selectedClip {
                ControlsView(model: model, clip: clip)
            }
            FilmstripView(model: model)
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
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.wheelZoom(zoomState, anchor: anchor, deltaY: deltaY)
                        },
                        onPinch: { factor, anchor in
                            guard model.activeTool != .crop else { return }
                            zoomState = ZoomMath.zoom(zoomState, anchor: anchor, factor: factor)
                        },
                        onPan: { dxFrac, dyFrac in
                            guard model.activeTool != .crop, zoomState.zoom > 1 else { return }
                            zoomState = ZoomMath.pan(zoomState, dxFrac: dxFrac, dyFrac: dyFrac)
                        },
                        onInteractionEnd: {}
                    )
                    if model.activeTool == .crop {
                        CropOverlay(
                            videoRect: EditMath.fit(aspect: clip.rotatedAspect, in: geo.size),
                            aspect: clip.cropAspect.ratio ?? clip.rotatedAspect,
                            cropRect: Bindable(clip).cropRect
                        )
                    }
                } else if model.clips.isEmpty {
                    dropHint
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedClipID) { zoomState = .identity }
        .onChange(of: model.selectedClip?.rotationQuarters) { zoomState = .identity }
        .onChange(of: model.activeTool) {
            if model.activeTool == .crop { zoomState = .identity }
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

            TrimStrip(
                thumbnails: clip.stripThumbnails,
                duration: clip.duration,
                minTrim: model.minTrim,
                isTrimming: model.activeTool == .trim,
                trimStart: $clip.trimStart,
                trimEnd: $clip.trimEnd,
                playhead: model.currentTime,
                onScrub: { model.seek(to: $0) }
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .overlay(alignment: .topTrailing) {
                    if hasEdit {
                        Circle().fill(.yellow)
                            .frame(width: 6, height: 6)
                            .offset(x: 8, y: -4)
                    }
                }
        }
        .buttonStyle(.bordered)
        .tint(isActive ? Color.accentColor : nil)
    }

    private func timeString(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let tenths = Int((clamped - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
    }
}
