//
//  PaintRenderer.swift
//  VideoClipper
//
//  Bakes freehand paint strokes into a frame image. Stroke points and width are
//  normalized to the displayed frame (top-left origin, like the crop math), so
//  the same strokes render correctly at any export resolution.
//

import CoreGraphics
import Foundation

nonisolated enum PaintRenderer {
    /// Returns `image` with the strokes drawn on top; the input comes back
    /// untouched when there is nothing to draw.
    static func bake(strokes: [PaintStroke], into image: CGImage) -> CGImage {
        guard !strokes.isEmpty else { return image }
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let rgb = stroke.color.rgb
            context.setStrokeColor(CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
            context.setLineWidth(max(1, stroke.width * CGFloat(width)))

            switch stroke.kind {
            case .freehand:
                context.beginPath()
                context.move(to: pixelPoint(first, width: width, height: height))
                for point in stroke.points.dropFirst() {
                    context.addLine(to: pixelPoint(point, width: width, height: height))
                }
                if stroke.points.count == 1 {
                    // A click without a drag still leaves a visible dot (round cap).
                    context.addLine(to: pixelPoint(first, width: width, height: height))
                }
                context.strokePath()
            case .rectangle:
                if let rect = pixelRect(of: stroke, width: width, height: height) {
                    context.stroke(rect)
                }
            case .ellipse:
                if let rect = pixelRect(of: stroke, width: width, height: height) {
                    context.strokeEllipse(in: rect)
                }
            }
        }
        return context.makeImage() ?? image
    }

    /// Bounding box of a two-corner shape stroke in CG pixel coordinates.
    private static func pixelRect(of stroke: PaintStroke, width: Int, height: Int) -> CGRect? {
        guard let a = stroke.points.first, let b = stroke.points.last, stroke.points.count >= 2 else {
            return nil
        }
        let p1 = pixelPoint(a, width: width, height: height)
        let p2 = pixelPoint(b, width: width, height: height)
        return CGRect(
            x: min(p1.x, p2.x), y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    /// Normalized top-left-origin point → CG (bottom-left origin) pixel coordinates.
    private static func pixelPoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height))
    }
}
