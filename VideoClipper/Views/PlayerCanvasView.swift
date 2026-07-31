//
//  PlayerCanvasView.swift
//  VideoClipper
//
//  Plays video through an AVPlayerLayer (no system controls — the trim strip is the only
//  scrubber). Rotation and staged crops are previewed via AVPlayerItem.videoComposition,
//  so the layer itself stays untransformed and `resizeAspect` handles the fitting.
//

@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct PlayerCanvasView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostNSView {
        let view = PlayerHostNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerHostNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
