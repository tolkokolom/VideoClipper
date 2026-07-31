//
//  EditMath.swift
//  VideoClipper
//
//  Pure geometry shared by the exporter, the preview composition, and the crop UI.
//  Crop rects are normalized (0…1) in the displayed, post-rotation video with a
//  top-left origin — the same coordinate space AVMutableVideoComposition renders in.
//

import CoreGraphics

nonisolated enum EditMath {
    static let identityCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func isIdentityCrop(_ crop: CGRect) -> Bool {
        crop.minX <= 0.001 && crop.minY <= 0.001 && crop.width >= 0.999 && crop.height >= 0.999
    }

    /// Layer transform (source orientation + user rotation) and the resulting render size,
    /// normalized so the rotated content sits in positive coordinates.
    static func rotation(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        quarters: Int
    ) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let angle = CGFloat(quarters) * (.pi / 2)
        var transform = preferredTransform.concatenating(CGAffineTransform(rotationAngle: angle))
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let renderSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        return (transform, renderSize)
    }

    /// Applies a normalized crop to a rotated render: shifts the cropped region to the origin
    /// and shrinks the render to the crop's size (rounded to even dimensions for the encoder).
    static func applyCrop(
        _ crop: CGRect,
        transform: CGAffineTransform,
        renderSize: CGSize
    ) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let cropX = crop.minX * renderSize.width
        let cropY = crop.minY * renderSize.height
        let shifted = transform.concatenating(CGAffineTransform(translationX: -cropX, y: -cropY))
        let evenWidth = max(2, (crop.width * renderSize.width / 2).rounded() * 2)
        let evenHeight = max(2, (crop.height * renderSize.height / 2).rounded() * 2)
        return (shifted, CGSize(width: evenWidth, height: evenHeight))
    }

    /// Rotate a normalized crop rect by the same +90° clockwise step as the Rotate button, so a
    /// pending crop tracks the content through a rotation instead of being wiped. Point map for
    /// +90° CW (origin top-left, y down): (x,y) → (1−y, x); a rect's width/height swap.
    static func rotatedCrop(_ crop: CGRect) -> CGRect {
        CGRect(x: 1 - crop.minY - crop.height, y: crop.minX, width: crop.height, height: crop.width)
    }

    /// Largest centered rect of `aspect` (w/h) that fits in `size`.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let containerAspect = size.width / size.height
        var w = size.width, h = size.height
        if aspect > containerAspect { h = w / aspect } else { w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
