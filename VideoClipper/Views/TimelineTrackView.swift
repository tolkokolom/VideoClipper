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

    var body: some View {
        VStack(spacing: 4) {
            ruler.frame(height: 18)
            // Reversed: array end = topmost layer = first row, AE-style.
            ForEach(Array(clip.timelineLayers.enumerated()).reversed(), id: \.element.id) { index, layer in
                trackRow(layer: layer, zIndex: index)
                    .frame(height: rowHeight)
            }
        }
    }

    // MARK: - Ruler

    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.masterDuration, 0.001)
            let step: Double = duration > 20 ? 5 : 1
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
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
                    .frame(width: barWidth)
                    .offset(x: barX)
                    .gesture(barGesture(layer: layer, zIndex: zIndex, barX: barX,
                                        barWidth: barWidth, scale: scale))

                if isSelected {
                    layerActions(layer: layer)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func label(for layer: TimelineLayer, zIndex: Int) -> String {
        let length = layer.sourceOut - layer.sourceIn
        let rendering = layer.reversed && clip.reversedAsset.isRendering
        return "L\(zIndex + 1) · \(String(format: "%.1f", length))s"
            + (rendering ? " · reversing…" : "")
    }

    private func layerActions(layer: TimelineLayer) -> some View {
        HStack(spacing: 8) {
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
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .padding(.trailing, 6)
    }

    /// One gesture covers select, move, edge-trim, and vertical z-reorder. The
    /// zone (edge vs body) is fixed at drag start; edits are absolute against
    /// the drag-start values, so there is no incremental error accumulation.
    private func barGesture(
        layer: TimelineLayer, zIndex: Int, barX: CGFloat, barWidth: CGFloat, scale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    model.selectedLayerID = layer.id
                    model.endNoteEditing()
                    dragOrigin = DragOrigin(
                        start: layer.start, sourceIn: layer.sourceIn,
                        sourceOut: layer.sourceOut, zIndex: zIndex)
                    let grabX = value.startLocation.x - barX
                    dragKind = grabX < 8 ? .trimIn : (grabX > barWidth - 8 ? .trimOut : .move)
                }
                guard let origin = dragOrigin, let kind = dragKind else { return }
                let deltaSeconds = Double(value.translation.width / max(scale, 0.001))
                switch kind {
                case .move:
                    model.setLayerStart(layer.id, seconds: origin.start + deltaSeconds)
                    // Dragging up (negative height) raises the layer, one row per
                    // rowHeight step; moveLayer clamps and ignores no-ops.
                    let steps = Int((-value.translation.height / rowHeight).rounded())
                    model.moveLayer(layer.id, toIndex: origin.zIndex + steps)
                case .trimIn:
                    model.trimLayer(layer.id, sourceIn: origin.sourceIn + deltaSeconds, sourceOut: nil)
                case .trimOut:
                    model.trimLayer(layer.id, sourceIn: nil, sourceOut: origin.sourceOut + deltaSeconds)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragKind = nil
            }
    }
}
