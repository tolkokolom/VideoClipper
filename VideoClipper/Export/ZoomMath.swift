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
    static func zoom(_ s: State, anchor: CGPoint, factor: CGFloat) -> State {
        let newZoom = min(maxZoom, max(minZoom, s.zoom * factor))
        let r = visibleRect(s)
        let px = r.minX + anchor.x * r.width
        let py = r.minY + anchor.y * r.height
        let w = 1 / newZoom
        return clamped(State(zoom: newZoom, cx: px - anchor.x * w + w / 2, cy: py - anchor.y * w + w / 2))
    }

    /// Wheel step: exponential in the scroll delta, positive = zoom in.
    static func wheelZoom(_ s: State, anchor: CGPoint, deltaY: CGFloat) -> State {
        zoom(s, anchor: anchor, factor: exp(deltaY * wheelSensitivity))
    }

    /// Pan by a drag expressed as fractions of the view; the content follows
    /// the cursor, so the visible window moves opposite the drag, scaled by
    /// 1/zoom.
    static func pan(_ s: State, dxFrac: CGFloat, dyFrac: CGFloat) -> State {
        clamped(State(zoom: s.zoom, cx: s.cx - dxFrac / s.zoom, cy: s.cy - dyFrac / s.zoom))
    }

    /// Keeps the visible rect inside the frame. At zoom 1 the only valid
    /// center is (0.5, 0.5), which is what makes zoom-out land on identity.
    private static func clamped(_ s: State) -> State {
        let half = 1 / (2 * s.zoom)
        func clamp(_ v: CGFloat) -> CGFloat { min(1 - half, max(half, v)) }
        return State(zoom: s.zoom, cx: clamp(s.cx), cy: clamp(s.cy))
    }
}
