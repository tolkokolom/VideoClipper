//
//  ZoomMathTests.swift
//  VideoClipperTests
//

import CoreGraphics
import Foundation
import Testing
@testable import VideoClipper

struct ZoomMathTests {
    private func close(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool {
        abs(a - b) < eps
    }

    @Test func visibleRectIdentity() {
        #expect(ZoomMath.visibleRect(.identity) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func visibleRectAt2xCentered() {
        let r = ZoomMath.visibleRect(ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5))
        #expect(close(r.minX, 0.25) && close(r.minY, 0.25))
        #expect(close(r.width, 0.5) && close(r.height, 0.5))
    }

    @Test func wheelZoomInOnPositiveDelta() {
        let s = ZoomMath.wheelZoom(.identity, anchor: CGPoint(x: 0.5, y: 0.5), deltaY: 200)
        #expect(close(s.zoom, exp(200 * ZoomMath.wheelSensitivity)))
        #expect(close(s.cx, 0.5) && close(s.cy, 0.5))
    }

    @Test func zoomKeepsAnchorContentPointFixed() {
        let before = ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5)
        let anchor = CGPoint(x: 0.25, y: 0.75)
        let rb = ZoomMath.visibleRect(before)
        let px = rb.minX + anchor.x * rb.width
        let py = rb.minY + anchor.y * rb.height
        let after = ZoomMath.zoom(before, anchor: anchor, factor: 1.35) // stays clear of the clamps
        let ra = ZoomMath.visibleRect(after)
        #expect(close(ra.minX + anchor.x * ra.width, px))
        #expect(close(ra.minY + anchor.y * ra.height, py))
    }

    @Test func zoomClampsAtMax() {
        let s = ZoomMath.zoom(
            ZoomMath.State(zoom: 7.9, cx: 0.5, cy: 0.5),
            anchor: CGPoint(x: 0.5, y: 0.5),
            factor: 100
        )
        #expect(s.zoom == ZoomMath.maxZoom)
    }

    @Test func zoomOutReturnsToExactIdentity() {
        let s = ZoomMath.zoom(
            ZoomMath.State(zoom: 1.3, cx: 0.4, cy: 0.6),
            anchor: CGPoint(x: 0.1, y: 0.1),
            factor: 0.01
        )
        #expect(s == .identity)
    }

    @Test func panShiftsOppositeTheDragScaledByZoom() {
        let s = ZoomMath.pan(ZoomMath.State(zoom: 4, cx: 0.5, cy: 0.5), dxFrac: 0.1, dyFrac: -0.2)
        #expect(close(s.cx, 0.5 - 0.1 / 4))
        #expect(close(s.cy, 0.5 + 0.2 / 4))
    }

    @Test func panClampsAtTheEdges() {
        let s = ZoomMath.pan(ZoomMath.State(zoom: 2, cx: 0.5, cy: 0.5), dxFrac: 5, dyFrac: 5)
        let r = ZoomMath.visibleRect(s)
        #expect(close(s.cx, 0.25) && close(s.cy, 0.25))
        #expect(close(r.minX, 0) && close(r.minY, 0))
    }

    @Test func panAt1xStaysCentered() {
        #expect(ZoomMath.pan(.identity, dxFrac: 0.3, dyFrac: 0.3) == .identity)
    }
}
