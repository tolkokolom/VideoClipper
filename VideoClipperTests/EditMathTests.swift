//
//  EditMathTests.swift
//  VideoClipperTests
//

import CoreGraphics
import Foundation
import Testing
@testable import VideoClipper

struct EditMathTests {
    // MARK: - rotation

    @Test func rotationZeroQuartersKeepsSize() {
        let (transform, size) = EditMath.rotation(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            quarters: 0
        )
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(transform == .identity)
    }

    @Test func rotationOneQuarterSwapsRenderSize() {
        let (_, size) = EditMath.rotation(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            quarters: 1
        )
        #expect(abs(size.width - 1080) < 0.001)
        #expect(abs(size.height - 1920) < 0.001)
    }

    @Test func rotationMapsContentIntoPositiveCoordinates() {
        for quarters in 0...3 {
            let natural = CGSize(width: 1920, height: 1080)
            let (transform, renderSize) = EditMath.rotation(
                naturalSize: natural, preferredTransform: .identity, quarters: quarters)
            let mapped = CGRect(origin: .zero, size: natural).applying(transform)
            #expect(abs(mapped.minX) < 0.001)
            #expect(abs(mapped.minY) < 0.001)
            #expect(abs(mapped.width - renderSize.width) < 0.001)
            #expect(abs(mapped.height - renderSize.height) < 0.001)
        }
    }

    // MARK: - applyCrop

    @Test func applyCropShrinksRenderToEvenDimensions() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let (_, size) = EditMath.applyCrop(
            crop, transform: .identity, renderSize: CGSize(width: 1921, height: 1081))
        #expect(size.width.truncatingRemainder(dividingBy: 2) == 0)
        #expect(size.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(abs(size.width - 960) <= 1)
        #expect(abs(size.height - 540) <= 1)
    }

    @Test func applyCropShiftsOriginToCropCorner() {
        let crop = CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let (transform, _) = EditMath.applyCrop(
            crop, transform: .identity, renderSize: CGSize(width: 1000, height: 800))
        let cropOrigin = CGPoint(x: 500, y: 200).applying(transform)
        #expect(abs(cropOrigin.x) < 0.001)
        #expect(abs(cropOrigin.y) < 0.001)
    }

    // MARK: - rotatedCrop

    @Test func rotatedCropMapsQuadrants() {
        // Top-left quadrant rotates CW into the top-right.
        let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let rotated = EditMath.rotatedCrop(topLeft)
        #expect(rotated == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test func rotatedCropFourTimesIsIdentity() {
        var crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for _ in 0..<4 { crop = EditMath.rotatedCrop(crop) }
        #expect(abs(crop.minX - 0.1) < 0.0001)
        #expect(abs(crop.minY - 0.2) < 0.0001)
        #expect(abs(crop.width - 0.3) < 0.0001)
        #expect(abs(crop.height - 0.4) < 0.0001)
    }

    @Test func identityCropDetection() {
        #expect(EditMath.isIdentityCrop(EditMath.identityCrop))
        #expect(!EditMath.isIdentityCrop(CGRect(x: 0, y: 0, width: 0.9, height: 1)))
    }

    // MARK: - fit

    @Test func fitWideAspectInSquareContainer() {
        let rect = EditMath.fit(aspect: 2, in: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func fitTallAspectInSquareContainer() {
        let rect = EditMath.fit(aspect: 0.5, in: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: 25, y: 0, width: 50, height: 100))
    }
}

struct ExportDestinationTests {
    @Test func firstExportGetsEditSuffix() {
        let source = URL(fileURLWithPath: "/tmp/videos/holiday.mov")
        let url = ExportDestination.nextAvailable(besides: source, ext: "mp4") { _ in false }
        #expect(url.path == "/tmp/videos/holiday-edit.mp4")
    }

    @Test func collisionsIncrementSuffix() {
        let source = URL(fileURLWithPath: "/tmp/videos/holiday.mov")
        let taken: Set<String> = ["/tmp/videos/holiday-edit.mp4", "/tmp/videos/holiday-edit-2.mp4"]
        let url = ExportDestination.nextAvailable(besides: source, ext: "mp4") { taken.contains($0.path) }
        #expect(url.path == "/tmp/videos/holiday-edit-3.mp4")
    }
}
