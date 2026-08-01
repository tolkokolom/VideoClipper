//
//  PlayerCanvasView.swift
//  VideoClipper
//
//  Plays video through an AVPlayerLayer (no system controls — the trim strip is the only
//  scrubber). Rotation and staged crops are previewed via AVPlayerItem.videoComposition,
//  so the layer itself stays untransformed and `resizeAspect` handles the fitting.
//
//  Inspection zoom: the host view also captures wheel/pinch/drag events (reported via
//  closures — policy lives in MainView) and renders the zoom by sizing the player layer
//  to bounds × zoom and offsetting it so `visibleRect` fills the view. The host clips.
//

@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct PlayerCanvasView: NSViewRepresentable {
    let player: AVPlayer
    var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var onWheel: ((_ deltaY: CGFloat, _ anchor: CGPoint) -> Void)?
    var onPinch: ((_ factor: CGFloat, _ anchor: CGPoint) -> Void)?
    var onPan: ((_ dxFrac: CGFloat, _ dyFrac: CGFloat) -> Void)?
    var onInteractionEnd: (() -> Void)?

    func makeNSView(context: Context) -> PlayerHostNSView {
        let view = PlayerHostNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.onWheel = onWheel
        nsView.onPinch = onPinch
        nsView.onPan = onPan
        nsView.onInteractionEnd = onInteractionEnd
        nsView.zoomVisibleRect = visibleRect
    }
}

final class PlayerHostNSView: NSView {
    let playerLayer = AVPlayerLayer()

    var onWheel: ((CGFloat, CGPoint) -> Void)?
    var onPinch: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onInteractionEnd: (() -> Void)?

    /// Normalized (0…1, top-left origin) region of the canvas to show. Full rect = no zoom.
    /// Named distinctly from `NSView.visibleRect` (a read-only AppKit property this would
    /// otherwise collide with).
    var zoomVisibleRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { if zoomVisibleRect != oldValue { applyZoom() } }
    }

    private var lastDragPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        applyZoom()
    }

    /// Sizes the player layer to bounds × zoom and offsets it so `visibleRect` fills the
    /// view. AppKit layer coordinates have a bottom-left origin, hence the maxY flip.
    private func applyZoom() {
        let zoom = 1 / max(zoomVisibleRect.width, 0.001)
        let w = bounds.width * zoom
        let h = bounds.height * zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = CGRect(x: -zoomVisibleRect.minX * w, y: -(1 - zoomVisibleRect.maxY) * h, width: w, height: h)
        CATransaction.commit()
    }

    /// Cursor position as a 0…1 fraction of the view, top-left origin.
    private func anchor(for event: NSEvent) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / bounds.width, y: 1 - p.y / bounds.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onWheel, let anchor = anchor(for: event) else {
            super.scrollWheel(with: event)
            return
        }
        var deltaY = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { deltaY *= 16 }
        onWheel(deltaY, anchor)
    }

    override func magnify(with event: NSEvent) {
        guard let onPinch, let anchor = anchor(for: event) else {
            super.magnify(with: event)
            return
        }
        onPinch(1 + event.magnification, anchor)
        if event.phase == .ended || event.phase == .cancelled { onInteractionEnd?() }
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint, bounds.width > 0, bounds.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        // View y grows upward; the pan math expects top-left-origin deltas.
        onPan?((p.x - last.x) / bounds.width, -(p.y - last.y) / bounds.height)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        onInteractionEnd?()
    }
}
