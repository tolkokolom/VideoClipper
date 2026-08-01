//
//  ZoomMath.swift
//  VideoClipper
//
//  Pure geometry for the inspection zoom (a viewing aid — never part of the
//  export). State is normalized: zoom in [1, 8], (cx, cy) = center of the
//  visible region in 0…1 canvas coordinates with a top-left origin.
//

import CoreGraphics
import Foundation

nonisolated enum ZoomMath {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 8
    static let wheelSensitivity: CGFloat = 0.003

    /// The whole canvas, normalized — the default `within:` for callers with no fitted
    /// video rect (and what every clamp reduces to when the video fills the canvas).
    static let fullCanvas = CGRect(x: 0, y: 0, width: 1, height: 1)

    struct State: Equatable {
        var zoom: CGFloat
        var cx: CGFloat
        var cy: CGFloat

        static let identity = State(zoom: 1, cx: 0.5, cy: 0.5)
    }

    /// Normalized visible region (top-left origin) for a state.
    static func visibleRect(_ s: State) -> CGRect {
        let w = 1 / s.zoom
        return CGRect(x: s.cx - w / 2, y: s.cy - w / 2, width: w, height: w)
    }

    /// Rescale about `anchor` (cursor as a 0…1 fraction of the view): the
    /// content point under the anchor stays put. Shared by wheel and pinch.
    /// `video` is the fitted video's rect, normalized to canvas coordinates
    /// (0…1, top-left origin) — pan/zoom clamp against it, not the full canvas.
    static func zoom(_ s: State, anchor: CGPoint, factor: CGFloat, within video: CGRect = fullCanvas) -> State {
        let newZoom = min(maxZoom, max(minZoom, s.zoom * factor))
        let r = visibleRect(s)
        let px = r.minX + anchor.x * r.width
        let py = r.minY + anchor.y * r.height
        let w = 1 / newZoom
        return clamped(
            State(zoom: newZoom, cx: px - anchor.x * w + w / 2, cy: py - anchor.y * w + w / 2),
            within: video
        )
    }

    /// Wheel step: exponential in the scroll delta, positive = zoom in.
    static func wheelZoom(_ s: State, anchor: CGPoint, deltaY: CGFloat, within video: CGRect = fullCanvas) -> State {
        zoom(s, anchor: anchor, factor: exp(deltaY * wheelSensitivity), within: video)
    }

    /// Pan by a drag expressed as fractions of the view; the content follows
    /// the cursor, so the visible window moves opposite the drag, scaled by
    /// 1/zoom.
    static func pan(_ s: State, dxFrac: CGFloat, dyFrac: CGFloat, within video: CGRect = fullCanvas) -> State {
        clamped(State(zoom: s.zoom, cx: s.cx - dxFrac / s.zoom, cy: s.cy - dyFrac / s.zoom), within: video)
    }

    /// Keeps the visible rect inside `video` (normalized canvas coordinates, top-left
    /// origin), per axis: where the zoomed video overflows the viewport on that axis,
    /// clamp the center inside the video's band; where it doesn't, pin the center to
    /// the video's midpoint on that axis (no pan there — matches iOS
    /// `clampedInspectionPan`, which forces the pan back to centre on a non-overflowing
    /// axis). With `video = .fullCanvas` this reduces exactly to the old frame-relative
    /// clamp (`cx ∈ [half, 1 - half]`; at zoom 1 the only valid center is (0.5, 0.5),
    /// which is what makes zoom-out land on identity).
    private static func clamped(_ s: State, within video: CGRect) -> State {
        let half = 1 / (2 * s.zoom)

        let cx: CGFloat
        if video.width * s.zoom >= 1 {
            cx = min(video.maxX - half, max(video.minX + half, s.cx))
        } else {
            cx = video.midX
        }

        let cy: CGFloat
        if video.height * s.zoom >= 1 {
            cy = min(video.maxY - half, max(video.minY + half, s.cy))
        } else {
            cy = video.midY
        }

        return State(zoom: s.zoom, cx: cx, cy: cy)
    }

    /// The visible region **of the video**, normalized 0…1 in video space — drives the
    /// minimap's yellow box (the iOS `inspectionViewport` math). `canvasVisible` is in
    /// canvas coordinates (as returned by `visibleRect`); `video` is the fitted video's
    /// rect in canvas coordinates, same as passed to `zoom`/`pan`.
    static func videoViewport(canvasVisible: CGRect, video: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return fullCanvas }
        func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        let x0 = clamp01((canvasVisible.minX - video.minX) / video.width)
        let x1 = clamp01((canvasVisible.maxX - video.minX) / video.width)
        let y0 = clamp01((canvasVisible.minY - video.minY) / video.height)
        let y1 = clamp01((canvasVisible.maxY - video.minY) / video.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
