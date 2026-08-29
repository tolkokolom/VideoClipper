//
//  PaintOverlay.swift
//  VideoClipper
//
//  Painting and stroke editing over the canvas while the Mark tool is active.
//  Draw mode: freehand strokes or two-corner rectangle/ellipse shapes (⇧ locks
//  square/circle, applied in view space where pixels are square); drawing on an
//  unmarked frame marks it first. Select mode: click picks the topmost stroke,
//  drag inside its box moves it, corner handles scale it (⇧ uniform), and the ✕
//  badge (or bare ⌫) deletes it. Coordinates are normalized to the fitted video
//  rect, the same space the export bakes from. The drag gesture attaches BEFORE
//  .position — after it, locations would arrive in full-canvas coordinates.
//

import AppKit
import SwiftUI

extension PaintColor {
    var swatch: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

struct PaintOverlay: View {
    let model: AppModel
    let videoRect: CGRect
    @State private var liveStroke: PaintStroke?
    @State private var selectDrag: SelectDrag?

    private enum SelectDrag {
        case move(last: CGPoint)                     // last drag location, view coords
        case scale(anchor: CGPoint, last: CGPoint)   // anchor normalized; last in view coords
        case click                                   // started on empty space
    }

    private var strokes: [PaintStroke] { model.markerAtPlayhead?.strokes ?? [] }
    private var selectedStroke: PaintStroke? {
        guard model.isSelectingStroke, let id = model.selectedStrokeID else { return nil }
        return strokes.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                for stroke in strokes {
                    draw(stroke, in: &context, size: size)
                }
                if let liveStroke {
                    draw(liveStroke, in: &context, size: size)
                }
                if let selected = selectedStroke {
                    drawSelectionChrome(around: selected, in: &context)
                }
            }
            if let selected = selectedStroke {
                let box = selectionBox(selected)
                Button { model.deleteSelectedStroke() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .position(x: box.maxX, y: box.minY)
                .help("Delete this stroke (⌫)")
            }
        }
        .frame(width: videoRect.width, height: videoRect.height)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if model.isSelectingStroke {
                        selectChanged(value)
                    } else {
                        drawChanged(value)
                    }
                }
                .onEnded { value in
                    if model.isSelectingStroke {
                        selectEnded(value)
                    } else {
                        if let liveStroke {
                            model.addStroke(points: liveStroke.points)
                        }
                        liveStroke = nil
                    }
                }
        )
        .position(x: videoRect.midX, y: videoRect.midY)
    }

    // MARK: - Draw mode

    private func drawChanged(_ value: DragGesture.Value) {
        if liveStroke == nil {
            model.endNoteEditing()   // drawing is video interaction
        }
        switch model.paintShape {
        case .freehand:
            var stroke = liveStroke ?? PaintStroke(
                points: [], color: model.paintColor, width: model.paintWidth)
            stroke.points.append(normalized(value.location))
            liveStroke = stroke
        case .rectangle, .ellipse:
            let end = shiftLocked(value.location, from: value.startLocation)
            liveStroke = PaintStroke(
                kind: model.paintShape,
                points: [normalized(value.startLocation), normalized(end)],
                color: model.paintColor, width: model.paintWidth)
        }
    }

    /// ⇧ held: snap the drag end so both view-space deltas match — a square/circle
    /// on screen (and in the export, which shares the preview's aspect).
    private func shiftLocked(_ location: CGPoint, from start: CGPoint) -> CGPoint {
        guard NSEvent.modifierFlags.contains(.shift) else { return location }
        let dx = location.x - start.x, dy = location.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(
            x: start.x + (dx < 0 ? -side : side),
            y: start.y + (dy < 0 ? -side : side))
    }

    // MARK: - Select mode

    private func selectChanged(_ value: DragGesture.Value) {
        if selectDrag == nil {
            selectDrag = beginSelectDrag(at: value.startLocation)
        }
        switch selectDrag {
        case .move(let last):
            model.translateSelectedStroke(by: CGPoint(
                x: (value.location.x - last.x) / max(videoRect.width, 1),
                y: (value.location.y - last.y) / max(videoRect.height, 1)))
            selectDrag = .move(last: value.location)
        case .scale(let anchor, let last):
            let anchorView = CGPoint(x: anchor.x * videoRect.width, y: anchor.y * videoRect.height)
            var fx = safeFactor(value.location.x - anchorView.x, over: last.x - anchorView.x)
            var fy = safeFactor(value.location.y - anchorView.y, over: last.y - anchorView.y)
            if NSEvent.modifierFlags.contains(.shift) {
                let current = hypot(value.location.x - anchorView.x, value.location.y - anchorView.y)
                let previous = hypot(last.x - anchorView.x, last.y - anchorView.y)
                let uniform = previous > 1 ? current / previous : 1
                fx = uniform; fy = uniform
            }
            model.scaleSelectedStroke(by: CGSize(width: fx, height: fy), anchor: anchor)
            selectDrag = .scale(anchor: anchor, last: value.location)
        case .click, nil:
            break
        }
    }

    private func selectEnded(_ value: DragGesture.Value) {
        let moved = hypot(
            value.location.x - value.startLocation.x,
            value.location.y - value.startLocation.y)
        if case .click = selectDrag ?? .click, moved < 4 {
            model.selectedStrokeID = paintedStroke(at: value.location)?.id
        }
        selectDrag = nil
    }

    /// The topmost stroke whose painted outline sits under `point` — interiors of
    /// shapes never count, so a stroke inside a big rectangle stays reachable.
    private func paintedStroke(at point: CGPoint) -> PaintStroke? {
        strokes.reversed().first { stroke in
            StrokeGeometry.hitTest(
                stroke, at: point, in: videoRect.size,
                tolerance: max(8, stroke.width * videoRect.width / 2 + 4))
        }
    }

    private func beginSelectDrag(at start: CGPoint) -> SelectDrag {
        // 1. Corner handles of the current selection scale it.
        if let selected = selectedStroke {
            let box = selectionBox(selected)
            if let corner = corners(of: box).first(where: { hypot($0.x - start.x, $0.y - start.y) <= 9 }) {
                // Scale about the opposite corner (diagonal to the grabbed handle).
                let anchorView = CGPoint(
                    x: box.minX + box.maxX - corner.x,
                    y: box.minY + box.maxY - corner.y)
                let anchor = CGPoint(
                    x: anchorView.x / max(videoRect.width, 1),
                    y: anchorView.y / max(videoRect.height, 1))
                return .scale(anchor: anchor, last: start)
            }
        }
        // 2. Painted geometry under the cursor wins over any selection box: grabbing
        //    a stroke selects it and starts moving it in one gesture — so a path
        //    running through a selected rectangle's empty interior stays grabbable.
        if let hit = paintedStroke(at: start) {
            if hit.id != model.selectedStrokeID {
                model.selectedStrokeID = hit.id
            }
            return .move(last: start)
        }
        // 3. Empty space inside the selected box still drags the selection.
        if let selected = selectedStroke,
           selectionBox(selected).insetBy(dx: -4, dy: -4).contains(start) {
            return .move(last: start)
        }
        return .click
    }

    /// Incremental per-axis scale factor; ~degenerate denominators freeze that axis.
    private func safeFactor(_ numerator: CGFloat, over denominator: CGFloat) -> CGFloat {
        abs(denominator) < 2 ? 1 : numerator / denominator
    }

    // MARK: - Geometry

    /// Overlay-local point → 0…1 in the video frame (top-left origin), clamped so
    /// a drag running off the edge stays on the frame border.
    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(videoRect.width, 1), 0), 1),
            y: min(max(point.y / max(videoRect.height, 1), 0), 1)
        )
    }

    /// The stroke's view-space bounding box, padded for line width and grabbing.
    private func selectionBox(_ stroke: PaintStroke) -> CGRect {
        let box = StrokeGeometry.boundingBox(stroke)
        let viewBox = CGRect(
            x: box.minX * videoRect.width, y: box.minY * videoRect.height,
            width: box.width * videoRect.width, height: box.height * videoRect.height)
        let padding = stroke.width * videoRect.width / 2 + 6
        return viewBox.insetBy(dx: -padding, dy: -padding)
    }

    private func corners(of box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    // MARK: - Rendering

    private func drawSelectionChrome(around stroke: PaintStroke, in context: inout GraphicsContext) {
        let box = selectionBox(stroke)
        context.stroke(
            Path(box),
            with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        for corner in corners(of: box) {
            let handle = CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)
            context.fill(Path(handle), with: .color(.white))
            context.stroke(Path(handle), with: .color(.cyan), lineWidth: 1)
        }
    }

    private func draw(_ stroke: PaintStroke, in context: inout GraphicsContext, size: CGSize) {
        guard let first = stroke.points.first else { return }
        let scale = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: p.y * size.height) }

        var path = Path()
        switch stroke.kind {
        case .freehand:
            path.move(to: scale(first))
            for point in stroke.points.dropFirst() {
                path.addLine(to: scale(point))
            }
            if stroke.points.count == 1 {
                path.addLine(to: scale(first))   // a click leaves a dot (round cap)
            }
        case .rectangle, .ellipse:
            guard stroke.points.count >= 2, let last = stroke.points.last else { return }
            let a = scale(first), b = scale(last)
            let rect = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(a.x - b.x), height: abs(a.y - b.y))
            path = stroke.kind == .rectangle ? Path(rect) : Path(ellipseIn: rect)
        }

        context.stroke(
            path,
            with: .color(stroke.color.swatch),
            style: StrokeStyle(
                lineWidth: max(1, stroke.width * size.width),
                lineCap: .round, lineJoin: .round
            )
        )
    }
}
