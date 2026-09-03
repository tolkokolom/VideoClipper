//
//  TimelineTrackView.swift
//  VideoClipper
//
//  Timeline mode's editor: a ruler with the shared playhead over a stack of
//  layer rows (top row = topmost layer). Bar body drags move a layer on the
//  master timeline, edge drags trim it, vertical drags reorder z. The selected
//  row carries duplicate / reverse / delete actions.
//

import SwiftUI

struct TimelineTrackView: View {
    let model: AppModel
    @Bindable var clip: Clip

    private let rowHeight: CGFloat = 24
    /// Explicit gesture space for track rows — drag locations on an .offset bar
    /// are ambiguous, so every zone decision is made in row coordinates.
    private let rowSpace = "timelineTrackRow"

    /// One drag's fixed frame of reference (values at drag start).
    private struct DragOrigin {
        var start: Double
        var sourceIn: Double
        var sourceOut: Double
        var zIndex: Int
    }
    private enum DragKind { case move, trimIn, trimOut }
    @State private var dragOrigin: DragOrigin?
    @State private var dragKind: DragKind?
    /// One undo snapshot per drag, taken when the drag first takes effect (so a
    /// zero-movement selection click never pollutes the history).
    @State private var recordedThisDrag = false
    /// Horizontal timeline zoom (1× = fit). Lane, ruler, and rows share one
    /// zoomed scroll surface; two-finger scroll pans, click-drags still reach
    /// the bars (macOS scroll views don't drag-pan with the pointer).
    @State private var zoom: CGFloat = 1

    private var stackHeight: CGFloat {
        // lane 16 + ruler 18 + rows, with the VStack's 4 pt gaps.
        38 + CGFloat(clip.timelineLayers.count) * (rowHeight + 4)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                VStack(spacing: 4) {
                    trimActionLane.frame(height: 16)
                    ruler.frame(height: 18)
                    // Reversed: array end = topmost layer = first row, AE-style.
                    ForEach(Array(clip.timelineLayers.enumerated()).reversed(), id: \.element.id) { index, layer in
                        trackRow(layer: layer, zIndex: index)
                            .frame(height: rowHeight)
                    }
                }
                .frame(width: max(geo.size.width, geo.size.width * zoom))
            }
            .scrollIndicators(zoom > 1 ? .visible : .hidden)
        }
        .frame(height: stackHeight)
        .overlay(alignment: .topTrailing) { zoomControls }
        .onChange(of: model.selectedClipID) { zoom = 1 }
    }

    /// Fixed toolbar (never scrolls with the zoomed timeline): actions for the
    /// selected layer, then the zoom buttons.
    private var zoomControls: some View {
        HStack(spacing: 8) {
            if let id = model.selectedLayerID,
               let layer = clip.timelineLayers.first(where: { $0.id == id }) {
                Button { model.duplicateLayer(layer.id) } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate layer")
                Button { model.toggleReverse(layer.id) } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(layer.reversed ? Color.cyan : Color.secondary)
                }
                .help(layer.reversed ? "Play forward" : "Reverse layer")
                Button { model.deleteLayer(layer.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete layer (⌫)")

                Divider().frame(height: 10)
            }

            Button { model.workAreaEnabled.toggle() } label: {
                Image(systemName: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
                    .foregroundStyle(model.workAreaEnabled ? Color.cyan : Color.secondary)
            }
            .help("Work area — playback runs between the layers' first in and last out")

            Divider().frame(height: 10)

            Button { zoom = max(1, zoom / 1.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= 1)
            .help("Zoom timeline out")
            Button { zoom = min(16, zoom * 1.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= 16)
            .help("Zoom timeline in")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
        .padding(.trailing, 2)
    }

    // MARK: - Trim-to-playhead lane

    /// Quick actions riding the playhead above the ruler (like Trim mode's [ / ]):
    /// trim the selected layer so it starts / ends at the playhead.
    private var trimActionLane: some View {
        GeometryReader { geo in
            if model.selectedLayerID != nil {
                let width = geo.size.width
                let duration = max(model.masterDuration, 0.001)
                let x = min(max(CGFloat(model.currentTime / duration) * width, 26), width - 26)
                HStack(spacing: 4) {
                    laneButton("[", help: "Selected layer starts at playhead") {
                        model.trimSelectedLayerInToPlayhead()
                    }
                    laneButton("]", help: "Selected layer ends at playhead") {
                        model.trimSelectedLayerOutToPlayhead()
                    }
                }
                .position(x: x, y: 8)
            }
        }
    }

    private func laneButton(
        _ label: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 14)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Ruler

    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.masterDuration, 0.001)
            let step: Double = duration > 20 ? 5 : 1
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))

                // Work area: a tinted band between the layers' first in and last
                // out, with bound markers. Bounds derive live from the layers.
                if let bounds = model.workAreaBounds {
                    let x1 = CGFloat(bounds.start / duration) * width
                    let x2 = CGFloat(bounds.end / duration) * width
                    Rectangle().fill(Color.cyan.opacity(0.14))
                        .frame(width: max(0, x2 - x1), height: 18)
                        .offset(x: x1)
                        .allowsHitTesting(false)
                    ForEach([x1, x2], id: \.self) { x in
                        Rectangle().fill(Color.cyan)
                            .frame(width: 2, height: 18)
                            .offset(x: x - 1)
                            .allowsHitTesting(false)
                    }
                }

                ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { tick in
                    let x = CGFloat(tick / duration) * width
                    Rectangle().fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 6)
                        .offset(x: x, y: 6)
                    Text("\(Int(tick))s")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: x + 2, y: -2)
                }
                let playheadX = min(max(CGFloat(model.currentTime / duration) * width, 0), width)
                Rectangle().fill(.white).frame(width: 2, height: 18)
                    .offset(x: playheadX - 1)
                    .allowsHitTesting(false)
                Circle().fill(.white).frame(width: 10, height: 10)
                    .offset(x: playheadX - 5, y: 4)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                    model.scrub(to: Double(fraction) * duration)
                }
            )
        }
    }

    // MARK: - Track rows

    private func trackRow(layer: TimelineLayer, zIndex: Int) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.masterDuration, 0.001)
            let scale = width / CGFloat(duration)
            let barX = CGFloat(layer.start) * scale
            let barWidth = max(CGFloat(layer.end - layer.start) * scale, 8)
            let isSelected = model.selectedLayerID == layer.id

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))

                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.cyan.opacity(0.75) : Color.cyan.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.white : Color.cyan, lineWidth: 1))
                    .overlay(alignment: .leading) {
                        HStack(spacing: 4) {
                            if layer.reversed {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            Text(label(for: layer, zIndex: zIndex))
                                .font(.system(size: 9).monospacedDigit())
                                .lineLimit(1)
                        }
                        .foregroundStyle(.black)
                        .padding(.leading, 10)
                    }
                    .overlay {
                        // Visible trim handles on the selected bar — the affordance
                        // for the edge zones the gesture actually uses.
                        if isSelected, barWidth >= 30 {
                            HStack {
                                trimHandleChip
                                Spacer()
                                trimHandleChip
                            }
                            .padding(.horizontal, 2)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: barWidth)
                    .offset(x: barX)
                    .gesture(barGesture(layer: layer, zIndex: zIndex, barX: barX,
                                        barWidth: barWidth, scale: scale))

            }
            .coordinateSpace(name: rowSpace)
        }
    }

    private var trimHandleChip: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(width: 5, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.cyan)
                    .frame(width: 1, height: 8))
            .shadow(radius: 0.5)
    }

    private func label(for layer: TimelineLayer, zIndex: Int) -> String {
        let length = layer.sourceOut - layer.sourceIn
        let rendering = layer.reversed && clip.reversedAsset.isRendering
        return "L\(zIndex + 1) · \(String(format: "%.1f", length))s"
            + (rendering ? " · reversing…" : "")
    }

    /// One gesture covers select, move, edge-trim, and vertical z-reorder. The
    /// zone (edge vs body) is fixed at drag start; edits are absolute against
    /// the drag-start values, so there is no incremental error accumulation.
    private func barGesture(
        layer: TimelineLayer, zIndex: Int, barX: CGFloat, barWidth: CGFloat, scale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(rowSpace))
            .onChanged { value in
                if dragOrigin == nil {
                    let wasSelected = model.selectedLayerID == layer.id
                    model.selectedLayerID = layer.id
                    model.endNoteEditing()
                    dragOrigin = DragOrigin(
                        start: layer.start, sourceIn: layer.sourceIn,
                        sourceOut: layer.sourceOut, zIndex: zIndex)
                    // Locations arrive in the row's named space, so bar-local is an
                    // explicit subtraction — never inferred from .offset behavior
                    // (drags on a moved bar used to misclassify as edge trims).
                    let grabX = value.startLocation.x - barX
                    // Zones cap at a third of the bar so a movable middle always
                    // survives on thin bars; matches the visible handle chips.
                    let edgeZone = min(14, barWidth / 3)
                    if !wasSelected || barWidth < 30 {
                        // Grabbing an unselected bar always selects-and-moves — the
                        // trim zones only exist where their handles are visible.
                        // Near-minimum-width bars stay movable; zoom in to trim them.
                        dragKind = .move
                    } else {
                        dragKind = grabX < edgeZone
                            ? .trimIn
                            : (grabX > barWidth - edgeZone ? .trimOut : .move)
                    }
                }
                guard let origin = dragOrigin, let kind = dragKind else { return }
                let deltaSeconds = Double(value.translation.width / max(scale, 0.001))
                // Snapshot the pre-drag state exactly once, at the moment the drag
                // first moves far enough to change anything.
                if !recordedThisDrag,
                   abs(deltaSeconds) > 0.001 || abs(value.translation.height) > rowHeight / 2 {
                    model.recordUndo()
                    recordedThisDrag = true
                }
                switch kind {
                case .move:
                    // Snap within ~6 screen pixels, whatever the zoom.
                    model.setLayerStart(layer.id, seconds: origin.start + deltaSeconds,
                                        snapTolerance: 6 / max(scale, 0.001))
                    // Dragging up (negative height) raises the layer, one row per
                    // rowHeight step; moveLayer clamps and ignores no-ops.
                    let steps = Int((-value.translation.height / rowHeight).rounded())
                    model.moveLayer(layer.id, toIndex: origin.zIndex + steps)
                case .trimIn:
                    model.trimLayerLeadingEdge(layer.id, sourceIn: origin.sourceIn + deltaSeconds)
                    // Playhead + preview follow the edge being trimmed.
                    if let fresh = clip.timelineLayers.first(where: { $0.id == layer.id }) {
                        model.seek(to: fresh.start)
                    }
                case .trimOut:
                    model.trimLayer(layer.id, sourceIn: nil, sourceOut: origin.sourceOut + deltaSeconds)
                    if let fresh = clip.timelineLayers.first(where: { $0.id == layer.id }) {
                        model.seek(to: fresh.end)
                    }
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragKind = nil
                recordedThisDrag = false
            }
    }
}
