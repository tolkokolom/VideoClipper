//
//  MarkerPanel.swift
//  VideoClipper
//
//  Right sidebar for the Mark tool: the clip's markers as a vertical list (jump,
//  single-line note, remove) plus the "Copy for Agent" action. Notes stay
//  single-line because the manifest is line-based. Bare-key menu shortcuts
//  (I/O/M/space/arrows) must not steal keystrokes while a note is being typed, so
//  note-field focus is mirrored into AppModel.isEditingNote and those menu items
//  disable themselves on it.
//

import SwiftUI

struct MarkerPanel: View {
    let model: AppModel
    @Bindable var clip: Clip
    @FocusState private var focusedNote: FrameMarker.ID?
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Markers")
                .font(.headline)

            if clip.markers.isEmpty {
                Text("Press M at the playhead to mark a frame.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($clip.markers) { $marker in
                            row($marker)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if clip.frameExportState.isExporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            Button {
                model.exportMarkedFrames()
            } label: {
                Label(justCopied ? "Copied" : "Copy for Agent",
                      systemImage: justCopied ? "checkmark" : "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(justCopied ? .green : .cyan)
            .disabled(clip.markers.isEmpty || clip.frameExportState.isExporting)
            .help("Export marked frames beside the video and copy the manifest with absolute paths (⌘E)")
        }
        .padding(12)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onChange(of: focusedNote) { model.isEditingNote = focusedNote != nil }
        .onDisappear { model.isEditingNote = false }
        .onAppear { consumeFocusRequest() }
        .onChange(of: model.noteFocusRequest) { consumeFocusRequest() }
        .onChange(of: model.noteBlurSignal) { focusedNote = nil }
        .onChange(of: clip.frameExportState.exportedURL) { _, url in
            guard url != nil else { return }
            justCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                justCopied = false
            }
        }
    }

    private func row(_ marker: Binding<FrameMarker>) -> some View {
        let index = (clip.markers.firstIndex { $0.id == marker.wrappedValue.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    model.seek(to: marker.wrappedValue.time)
                } label: {
                    Text("\(index) · \(marker.wrappedValue.time, format: .number.precision(.fractionLength(2)))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
                .help("Jump to this frame")

                Spacer()

                Button {
                    clip.markers.removeAll { $0.id == marker.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove marker")
            }

            // Vertical axis wraps long notes; Return still submits (⌥⏎ would insert a
            // newline — the manifest flattens those).
            TextField("note", text: marker.note, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($focusedNote, equals: marker.wrappedValue.id)
                .onSubmit { focusedNote = nil }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.highlightedMarkerID == marker.wrappedValue.id
                ? Color.cyan.opacity(0.18)
                : Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering in
            if hovering {
                model.highlightedMarkerID = marker.wrappedValue.id
            } else if model.highlightedMarkerID == marker.wrappedValue.id {
                model.highlightedMarkerID = nil
            }
        }
    }

    /// A timeline pin was clicked: put the cursor into that marker's note field.
    /// Deferred a beat so it works when the click also just opened this panel
    /// (@FocusState set directly in onAppear is unreliable).
    private func consumeFocusRequest() {
        guard let id = model.noteFocusRequest else { return }
        model.noteFocusRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            focusedNote = id
        }
    }
}
