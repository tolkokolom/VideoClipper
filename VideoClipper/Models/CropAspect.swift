//
//  CropAspect.swift
//  VideoClipper
//
//  Ported from ClipShot: the crop tool's aspect presets.
//

import CoreGraphics

enum CropAspect: String, CaseIterable, Identifiable {
    case original, square, vertical, landscape, portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .square: "1:1"
        case .vertical: "9:16"
        case .landscape: "16:9"
        case .portrait: "4:5"
        }
    }

    /// Width / height; nil = the video's own displayed aspect.
    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .vertical: 9.0 / 16.0
        case .landscape: 16.0 / 9.0
        case .portrait: 4.0 / 5.0
        }
    }

    /// The crop-frame aspect after a +90° rotation. 16:9 ↔ 9:16; square/original are symmetric;
    /// 4:5 has no 5:4 preset, so it's kept (the restored crop re-fits to 4:5).
    var rotated: CropAspect {
        switch self {
        case .original: .original
        case .square: .square
        case .vertical: .landscape
        case .landscape: .vertical
        case .portrait: .portrait
        }
    }
}
