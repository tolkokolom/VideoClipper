//
//  StrokeGeometry.swift
//  VideoClipper
//
//  Pure geometry for selecting and editing paint strokes: translate/scale in
//  normalized space (the stroke keeps its identity), normalized bounding boxes,
//  and hit testing in view space — where pixels are square, so distances mean
//  what the eye expects.
//

import CoreGraphics
import Foundation

nonisolated enum StrokeGeometry {
    static func translated(_ stroke: PaintStroke, by delta: CGPoint) -> PaintStroke {
        var moved = stroke
        moved.points = stroke.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return moved
    }

    /// Scales every point away from `anchor` (normalized) by per-axis factors.
    static func scaled(_ stroke: PaintStroke, by factors: CGSize, anchor: CGPoint) -> PaintStroke {
        var scaled = stroke
        scaled.points = stroke.points.map {
            CGPoint(
                x: anchor.x + ($0.x - anchor.x) * factors.width,
                y: anchor.y + ($0.y - anchor.y) * factors.height)
        }
        return scaled
    }

    /// Normalized bounding box of the stroke's points (no line-width padding).
    static func boundingBox(_ stroke: PaintStroke) -> CGRect {
        guard let first = stroke.points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in stroke.points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// True when `point` (view coordinates) lies within `tolerance` of the stroke's
    /// outline, with the stroke's normalized points mapped into `size`.
    static func hitTest(
        _ stroke: PaintStroke, at point: CGPoint, in size: CGSize, tolerance: CGFloat
    ) -> Bool {
        let scaled = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = scaled.first else { return false }

        switch stroke.kind {
        case .freehand:
            if scaled.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance }
            for index in 0..<(scaled.count - 1)
            where distanceToSegment(point, scaled[index], scaled[index + 1]) <= tolerance {
                return true
            }
            return false

        case .rectangle:
            guard scaled.count >= 2, let last = scaled.last else { return false }
            let rect = CGRect(
                x: min(first.x, last.x), y: min(first.y, last.y),
                width: abs(first.x - last.x), height: abs(first.y - last.y))
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ]
            for index in 0..<4
            where distanceToSegment(point, corners[index], corners[(index + 1) % 4]) <= tolerance {
                return true
            }
            return false

        case .ellipse:
            guard scaled.count >= 2, let last = scaled.last else { return false }
            let a = abs(first.x - last.x) / 2, b = abs(first.y - last.y) / 2
            guard a > 0.5, b > 0.5 else { return false }
            let center = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
            // Radial distance in the unit space where the ellipse is a circle,
            // scaled back by the local radius — close enough for hit testing.
            let ux = (point.x - center.x) / a, uy = (point.y - center.y) / b
            let rho = hypot(ux, uy)
            return abs(rho - 1) * min(a, b) <= tolerance
        }
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }
}
