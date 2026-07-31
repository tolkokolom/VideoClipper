//
//  FilmstripView.swift
//  VideoClipper
//
//  Horizontal bin of dropped clips along the bottom of the window: poster thumbnail,
//  duration badge, selection outline, export status, and a context menu.
//

import AppKit
import SwiftUI

struct FilmstripView: View {
    let model: AppModel

    private let tileSize = CGSize(width: 96, height: 58)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(model.clips) { clip in
                    tile(clip)
                }
                addTile
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: tileSize.height + 16)
        .background(.black.opacity(0.25))
    }

    private func tile(_ clip: Clip) -> some View {
        ZStack {
            if let poster = clip.posterImage {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.primary.opacity(0.1))
                    .overlay { SkeletonShimmer() }
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            Text(durationString(clip.trimmedDuration > 0 ? clip.trimmedDuration : clip.duration))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(3)
        }
        .overlay(alignment: .topLeading) { statusBadge(clip).padding(3) }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    clip.id == model.selectedClipID ? Color.accentColor : .white.opacity(0.15),
                    lineWidth: clip.id == model.selectedClipID ? 2 : 1
                )
        }
        .contentShape(.rect)
        .onTapGesture { model.select(clip) }
        .contextMenu {
            Button("Export") { model.export(clip) }
                .disabled(!clip.hasEdits || clip.exportState.isExporting)
            if let exported = clip.exportState.exportedURL {
                Button("Show Export in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                }
            }
            Button("Show Original in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([clip.url])
            }
            Divider()
            Button("Remove from Bin", role: .destructive) { model.remove(clip) }
        }
    }

    @ViewBuilder
    private func statusBadge(_ clip: Clip) -> some View {
        switch clip.exportState {
        case .idle:
            if clip.hasEdits {
                Circle().fill(.yellow).frame(width: 7, height: 7).shadow(radius: 1)
            }
        case .exporting:
            ProgressView()
                .controlSize(.small)
                .padding(2)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .shadow(radius: 1)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .shadow(radius: 1)
        }
    }

    private var addTile: some View {
        Button(action: { model.openFiles() }) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
                .frame(width: tileSize.width / 2, height: tileSize.height)
                .overlay {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
        .help("Add videos (⌘O)")
    }

    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
