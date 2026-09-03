//
//  TrimStrip.swift
//  VideoClipper
//
//  Ported from ClipShot: the scrubber/trim timeline with thumbnails, yellow trim
//  handles while trimming, a passive grey marker once a trim is staged, and a playhead.
//

import SwiftUI

struct TrimStrip: View {
    let thumbnails: [NSImage]
    let duration: Double
    let minTrim: Double
    let isTrimming: Bool
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let playhead: Double
    /// Times of the clip's frame markers — rendered as passive cyan ticks.
    let markers: [Double]
    let onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 14
    private let space = "trimStrip"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let startX = CGFloat(trimStart / max(duration, 0.001)) * width
            let endX = CGFloat(trimEnd / max(duration, 0.001)) * width
            let playheadX = min(max(CGFloat(playhead / max(duration, 0.001)) * width, 0), width)

            ZStack(alignment: .leading) {
                // Skeleton base: keeps the strip from going empty while thumbnails generate.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.08))
                    .overlay { if thumbnails.isEmpty { SkeletonShimmer() } }

                if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(max(1, thumbnails.count)), height: height)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
                }

                // Trim selection. Editable (yellow + draggable handles) while Trim is the active
                // tool; once a trim is set but you've moved to another tool, keep it visible as a
                // passive grey, non-interactive marker — the trim still applies, so it shouldn't
                // silently disappear.
                let isTrimmed = trimStart > 0.05 || trimEnd < duration - 0.05
                if isTrimming || isTrimmed {
                    let selectionColor: Color = isTrimming ? .yellow : .gray
                    let dimOpacity: Double = isTrimming ? 0.55 : 0.4

                    Rectangle().fill(.black.opacity(dimOpacity)).frame(width: max(0, startX))
                    Rectangle().fill(.black.opacity(dimOpacity)).frame(width: max(0, width - endX)).offset(x: endX)

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selectionColor, lineWidth: 3)
                        .frame(width: max(0, endX - startX), height: height)
                        .offset(x: startX)

                    if isTrimming {
                        handle(.yellow).offset(x: startX - handleWidth / 2)
                            .gesture(drag(width: width, isStart: true))
                        handle(.yellow).offset(x: endX - handleWidth / 2)
                            .gesture(drag(width: width, isStart: false))
                    } else {
                        // Passive: no drag, no hit-testing, so the strip still scrubs underneath.
                        handle(.gray).offset(x: startX - handleWidth / 2).allowsHitTesting(false)
                        handle(.gray).offset(x: endX - handleWidth / 2).allowsHitTesting(false)
                    }
                }

                // Marker ticks: passive (jump with ⌥←/⌥→ or the chips row), so the
                // strip still scrubs underneath them.
                ForEach(Array(markers.enumerated()), id: \.offset) { _, time in
                    let x = min(max(CGFloat(time / max(duration, 0.001)) * width, 0), width)
                    UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                        .fill(.cyan)
                        .frame(width: 3, height: 12)
                        .offset(x: x - 1.5, y: -height / 2 + 6)
                        .allowsHitTesting(false)
                }

                // Playhead line + grab knob (both modes).
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: height)
                    .offset(x: playheadX - 1)
                    .allowsHitTesting(false)

                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .offset(x: playheadX - 6)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.22), value: thumbnails.isEmpty)
            .contentShape(.rect)
            .coordinateSpace(name: space)
            // Scrubbing works in both modes. The trim handles' own drags recognize at
            // zero distance, so as deeper views they win over this strip-level gesture
            // when the drag starts on a handle.
            .gesture(scrubGesture(width: width))
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                let fraction = min(max(value.location.x / width, 0), 1)
                onScrub(Double(fraction) * duration)
            }
    }

    private func handle(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: handleWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 2, height: 18)
            )
    }

    private func drag(width: CGFloat, isStart: Bool) -> some Gesture {
        // minimumDistance 0: must recognize instantly, or the strip's zero-distance
        // scrub gesture claims the drag before this one starts.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                let fraction = min(max(value.location.x / width, 0), 1)
                let time = Double(fraction) * duration
                if isStart {
                    trimStart = max(0, min(time, trimEnd - minTrim))
                    onScrub(trimStart)
                } else {
                    trimEnd = min(duration, max(time, trimStart + minTrim))
                    onScrub(trimEnd)
                }
            }
    }
}

struct SkeletonShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.12), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .offset(x: phase * geo.size.width * 1.6)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
