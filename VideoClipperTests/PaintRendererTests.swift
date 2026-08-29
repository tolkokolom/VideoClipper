//
//  PaintRendererTests.swift
//  VideoClipperTests
//
//  Baking freehand strokes into a CGImage: normalized points must land on the
//  right pixels (top-left-origin convention, like the crop math) in the stroke's
//  color, leaving unpainted pixels untouched.
//

import CoreGraphics
import Foundation
import Testing
@testable import VideoClipper

struct PaintRendererTests {
    /// Solid-white sRGB image.
    private func whiteImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// (r, g, b) of one pixel, 0…1, in top-left-origin coordinates.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var raw = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &raw, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Shift the image so the wanted pixel lands in this 1×1 context.
        // CGContext is bottom-left origin: flip y.
        context.draw(image, in: CGRect(
            x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(raw[0]) / 255, Double(raw[1]) / 255, Double(raw[2]) / 255)
    }

    @Test func bakedStrokePaintsItsPathAndLeavesTheRestAlone() throws {
        let base = try whiteImage(width: 200, height: 100)
        // Horizontal red line across the vertical middle, thick enough to sample safely.
        let stroke = PaintStroke(
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)],
            color: .red, width: 0.05)

        let baked = PaintRenderer.bake(strokes: [stroke], into: base)

        let onPath = try pixel(baked, x: 100, y: 50)
        #expect(onPath.r > 0.8)
        #expect(onPath.g < 0.5)
        let corner = try pixel(baked, x: 5, y: 5)
        #expect(corner.r > 0.95 && corner.g > 0.95 && corner.b > 0.95)
    }

    @Test func bakeRespectsTopLeftOriginForOffCenterStrokes() throws {
        let base = try whiteImage(width: 100, height: 100)
        // Dot near the TOP of the frame (y = 0.1 in top-left-origin normalized space).
        let stroke = PaintStroke(
            points: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.11)],
            color: .black, width: 0.08)

        let baked = PaintRenderer.bake(strokes: [stroke], into: base)

        let top = try pixel(baked, x: 50, y: 10)
        #expect(top.r < 0.2 && top.g < 0.2 && top.b < 0.2)
        let bottom = try pixel(baked, x: 50, y: 90)
        #expect(bottom.r > 0.95)
    }

    @Test func bakedRectangleStrokesItsOutlineNotItsInterior() throws {
        let base = try whiteImage(width: 200, height: 200)
        let stroke = PaintStroke(
            kind: .rectangle,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)],
            color: .red, width: 0.05)

        let baked = PaintRenderer.bake(strokes: [stroke], into: base)

        let topEdge = try pixel(baked, x: 100, y: 40)
        #expect(topEdge.r > 0.8 && topEdge.g < 0.5)
        let center = try pixel(baked, x: 100, y: 100)
        #expect(center.r > 0.95 && center.g > 0.95 && center.b > 0.95)
    }

    @Test func bakedEllipseFollowsItsBoundingBox() throws {
        let base = try whiteImage(width: 200, height: 200)
        let stroke = PaintStroke(
            kind: .ellipse,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)],
            color: .black, width: 0.05)

        let baked = PaintRenderer.bake(strokes: [stroke], into: base)

        // Top of the ellipse sits at the bounding box's top-middle …
        let top = try pixel(baked, x: 100, y: 40)
        #expect(top.r < 0.2 && top.g < 0.2)
        // … while the bounding box corner and the center stay clean.
        let corner = try pixel(baked, x: 40, y: 40)
        #expect(corner.r > 0.95)
        let center = try pixel(baked, x: 100, y: 100)
        #expect(center.r > 0.95)
    }

    @Test func bakeWithoutStrokesReturnsTheImageUntouched() throws {
        let base = try whiteImage(width: 50, height: 50)
        let baked = PaintRenderer.bake(strokes: [], into: base)
        #expect(baked === base)
    }
}
