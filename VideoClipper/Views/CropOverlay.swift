//
//  CropOverlay.swift
//  VideoClipper
//
//  Mac-native crop interaction (replaces ClipShot's pinch-to-frame): a draggable crop
//  rectangle with corner resize handles, drawn over the displayed video. The crop rect
//  binding is normalized (0…1, top-left origin) in the displayed post-rotation frame —
//  the exporter's coordinate space — and the aspect is locked to the chosen preset.
//

import SwiftUI

struct CropOverlay: View {
    /// The displayed video's rect in this view's coordinate space.
    let videoRect: CGRect
    /// Locked aspect (w/h) in real display proportions.
    let aspect: CGFloat
    @Binding var cropRect: CGRect
    /// Fired once per move/resize drag, before its first change — the undo hook
    /// (crop drags mutate the binding directly).
    var onEditBegan: () -> Void = {}

    /// Crop at gesture start, in display coordinates; nil when no drag is running.
    @State private var dragStart: CGRect?

    private let handleSize: CGFloat = 12
    private let handleHitSize: CGFloat = 28
    private let minSide: CGFloat = 32

    private var displayCrop: CGRect {
        CGRect(
            x: videoRect.minX + cropRect.minX * videoRect.width,
            y: videoRect.minY + cropRect.minY * videoRect.height,
            width: cropRect.width * videoRect.width,
            height: cropRect.height * videoRect.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming(around: displayCrop)

            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2)
                .frame(width: displayCrop.width, height: displayCrop.height)
                .position(x: displayCrop.midX, y: displayCrop.midY)
                .shadow(radius: 2)

            // Interior: drag to move the crop window.
            Rectangle()
                .fill(.clear)
                .contentShape(.rect)
                .frame(width: displayCrop.width, height: displayCrop.height)
                .position(x: displayCrop.midX, y: displayCrop.midY)
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                let point = corner.point(of: displayCrop)
                Circle()
                    .fill(.white)
                    .frame(width: handleSize, height: handleSize)
                    .shadow(radius: 1.5)
                    .frame(width: handleHitSize, height: handleHitSize)
                    .contentShape(.circle)
                    .position(point)
                    .gesture(resizeGesture(corner: corner))
            }
        }
    }

    // MARK: - Dimming

    @ViewBuilder
    private func dimming(around frame: CGRect) -> some View {
        let dim = Color.black.opacity(0.55)
        // Dim only within the video's rect — outside it the canvas is already black.
        ZStack(alignment: .topLeading) {
            dim.frame(width: videoRect.width, height: max(0, frame.minY - videoRect.minY))
                .offset(x: videoRect.minX, y: videoRect.minY)
            dim.frame(width: videoRect.width, height: max(0, videoRect.maxY - frame.maxY))
                .offset(x: videoRect.minX, y: frame.maxY)
            dim.frame(width: max(0, frame.minX - videoRect.minX), height: frame.height)
                .offset(x: videoRect.minX, y: frame.minY)
            dim.frame(width: max(0, videoRect.maxX - frame.maxX), height: frame.height)
                .offset(x: frame.maxX, y: frame.minY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Move

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { onEditBegan() }
                let start = dragStart ?? displayCrop
                dragStart = start
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.origin.x, videoRect.minX), videoRect.maxX - moved.width)
                moved.origin.y = min(max(moved.origin.y, videoRect.minY), videoRect.maxY - moved.height)
                commit(moved)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - Resize

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        func point(of rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        /// The fixed opposite corner a resize anchors to.
        func anchor(of rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.maxX, y: rect.maxY)
            case .topTrailing: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeading: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomTrailing: CGPoint(x: rect.minX, y: rect.minY)
            }
        }

        var growsTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
        var growsDown: Bool { self == .bottomLeading || self == .bottomTrailing }
    }

    private func resizeGesture(corner: Corner) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil { onEditBegan() }
                let start = dragStart ?? displayCrop
                dragStart = start
                let anchor = corner.anchor(of: start)

                // Span from the anchor to the mouse, projected onto the locked aspect:
                // the dominant axis wins so the corner tracks the cursor naturally.
                let spanW = abs(value.location.x - anchor.x)
                let spanH = abs(value.location.y - anchor.y)
                var width = max(spanW, spanH * aspect)

                // Clamp within the video frame (in the direction this corner grows)
                // and to a usable minimum.
                let maxW = corner.growsTrailing ? videoRect.maxX - anchor.x : anchor.x - videoRect.minX
                let maxH = corner.growsDown ? videoRect.maxY - anchor.y : anchor.y - videoRect.minY
                width = min(width, maxW, maxH * aspect)
                width = max(width, min(minSide, maxW))
                let height = width / aspect

                let resized = CGRect(
                    x: corner.growsTrailing ? anchor.x : anchor.x - width,
                    y: corner.growsDown ? anchor.y : anchor.y - height,
                    width: width,
                    height: height
                )
                commit(resized)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - Commit

    private func commit(_ display: CGRect) {
        guard videoRect.width > 0, videoRect.height > 0 else { return }
        let normalized = CGRect(
            x: (display.minX - videoRect.minX) / videoRect.width,
            y: (display.minY - videoRect.minY) / videoRect.height,
            width: display.width / videoRect.width,
            height: display.height / videoRect.height
        )
        cropRect = CGRect(
            x: min(max(normalized.minX, 0), 1),
            y: min(max(normalized.minY, 0), 1),
            width: min(normalized.width, 1),
            height: min(normalized.height, 1)
        )
    }
}
