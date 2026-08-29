//
//  StrokeGeometryTests.swift
//  VideoClipperTests
//
//  Pure geometry for stroke selection/editing: translate and scale in normalized
//  space (identity-preserving), bounding boxes, and view-space hit testing for
//  freehand paths, rectangles, and ellipses.
//

import CoreGraphics
import Foundation
import Testing
@testable import VideoClipper

struct StrokeGeometryTests {
    private func freehand(_ points: [(CGFloat, CGFloat)]) -> PaintStroke {
        PaintStroke(points: points.map { CGPoint(x: $0.0, y: $0.1) }, color: .red)
    }

    private func approx(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func translatedShiftsEveryPointAndKeepsIdentity() {
        let stroke = freehand([(0.2, 0.2), (0.4, 0.6)])
        let moved = StrokeGeometry.translated(stroke, by: CGPoint(x: 0.1, y: -0.1))
        #expect(approx(moved.points[0], CGPoint(x: 0.3, y: 0.1)))
        #expect(approx(moved.points[1], CGPoint(x: 0.5, y: 0.5)))
        #expect(moved.id == stroke.id)
    }

    @Test func scaledGrowsAwayFromTheAnchor() {
        let stroke = freehand([(0.6, 0.6), (0.5, 0.5)])
        let scaled = StrokeGeometry.scaled(
            stroke, by: CGSize(width: 2, height: 2), anchor: CGPoint(x: 0.5, y: 0.5))
        #expect(approx(scaled.points[0], CGPoint(x: 0.7, y: 0.7)))
        #expect(approx(scaled.points[1], CGPoint(x: 0.5, y: 0.5)))   // anchor stays put
        #expect(scaled.id == stroke.id)
    }

    @Test func boundingBoxSpansAllPoints() {
        let box = StrokeGeometry.boundingBox(freehand([(0.2, 0.3), (0.6, 0.5), (0.4, 0.4)]))
        #expect(approx(box.origin, CGPoint(x: 0.2, y: 0.3)))
        #expect(abs(box.width - 0.4) < 1e-9 && abs(box.height - 0.2) < 1e-9)
    }

    @Test func hitTestFreehandRespondsNearThePathOnly() {
        let stroke = freehand([(0.1, 0.5), (0.9, 0.5)])
        let size = CGSize(width: 1000, height: 500)
        #expect(StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 252), in: size, tolerance: 10))
        #expect(!StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 300), in: size, tolerance: 10))
    }

    @Test func hitTestRectangleHitsTheOutlineNotTheInterior() {
        let stroke = PaintStroke(
            kind: .rectangle,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: .red)
        let size = CGSize(width: 1000, height: 1000)
        #expect(StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 205), in: size, tolerance: 10))
        #expect(!StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 500), in: size, tolerance: 10))
    }

    @Test func hitTestEllipseHitsTheOutlineNotCenterOrCorner() {
        let stroke = PaintStroke(
            kind: .ellipse,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: .red)
        let size = CGSize(width: 1000, height: 1000)
        #expect(StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 205), in: size, tolerance: 10))
        #expect(!StrokeGeometry.hitTest(stroke, at: CGPoint(x: 500, y: 500), in: size, tolerance: 10))
        #expect(!StrokeGeometry.hitTest(stroke, at: CGPoint(x: 205, y: 205), in: size, tolerance: 10))
    }
}
