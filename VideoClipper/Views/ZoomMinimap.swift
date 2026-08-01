//
//  ZoomMinimap.swift
//  VideoClipper
//
//  Corner zoom navigator, ported from the iOS ClipShot editor. White outline = the
//  whole video frame (aspect-matched); yellow box = the part currently on screen.
//

import SwiftUI

struct ZoomMinimap: View {
    let displayedAspect: CGFloat   // w/h of the displayed (rotation+crop-adjusted) video
    let visible: CGRect            // visible region, normalized 0…1

    /// Longest side of the white frame.
    private let maxSide: CGFloat = 90

    private var frameSize: CGSize {
        let a = max(0.01, displayedAspect)
        return a >= 1
            ? CGSize(width: maxSide, height: maxSide / a)
            : CGSize(width: maxSide * a, height: maxSide)
    }

    var body: some View {
        let f = frameSize
        let yellowW = max(6, visible.width * f.width)
        let yellowH = max(6, visible.height * f.height)
        let offX = min(max(0, visible.minX * f.width), f.width - yellowW)
        let offY = min(max(0, visible.minY * f.height), f.height - yellowH)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.5), lineWidth: 2.5)
                .frame(width: f.width, height: f.height)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)                                   // ~frosted backdrop blur
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.yellow.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.yellow, lineWidth: 2.5))
                .frame(width: yellowW, height: yellowH)
                .offset(x: offX, y: offY)
        }
        .frame(width: f.width, height: f.height)
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .animation(.smooth(duration: 0.3), value: displayedAspect)
    }
}
