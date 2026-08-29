//
//  FrameHandoff.swift
//  VideoClipper
//
//  Naming and manifest text for the frame handoff export. The manifest is written
//  twice from the same formatter: with relative filenames into the folder's
//  frames.md, and with absolute paths onto the clipboard — so one ⌘V into a coding
//  agent hands over the timing context plus paths it can open itself.
//

import Foundation

nonisolated enum FrameHandoff {
    /// "01_t0.00s.jpg" — index keeps the sequence sortable, the timestamp keeps each
    /// file self-describing when dragged out on its own.
    static func frameFilename(index: Int, time: Double) -> String {
        String(format: "%02d_t%.2fs.jpg", index, time)
    }

    /// First free "<base>-frames[-N]" folder beside `source`, never overwriting an
    /// earlier export. `fileExists` is injectable for tests.
    static func nextAvailableFolder(
        besides source: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let parent = source.deletingLastPathComponent()
        for attempt in 1...10_000 {
            let name = attempt == 1 ? "\(base)-frames" : "\(base)-frames-\(attempt)"
            let candidate = parent.appendingPathComponent(name)
            if !fileExists(candidate) { return candidate }
        }
        return parent.appendingPathComponent("\(base)-frames-\(UUID().uuidString)")
    }

    /// Markdown manifest: header, then one entry per marker with the timestamp, the
    /// delta to the previous frame, the frame's path, and the note (when non-empty).
    /// `basePath` nil emits bare filenames; a folder path emits absolute paths.
    static func manifest(
        sourceName: String,
        duration: Double,
        markers: [FrameMarker],
        basePath: String?
    ) -> String {
        let plural = markers.count == 1 ? "frame" : "frames"
        var lines = [
            String(format: "Frames from screen recording %@ (%.1fs, %d %@ marked):",
                   sourceName, duration, markers.count, plural),
            "",
        ]
        for (offset, marker) in markers.enumerated() {
            let filename = frameFilename(index: offset + 1, time: marker.time)
            let path = basePath.map { "\($0)/\(filename)" } ?? filename
            var line = String(format: "%d. t=%.2fs", offset + 1, marker.time)
            if offset > 0 {
                line += String(format: " (Δ+%.2fs)", marker.time - markers[offset - 1].time)
            }
            lines.append(line + " — " + path)
            // The manifest is line-based: a newline typed into a note (⌥⏎) must not
            // break the entry structure, so inner newlines flatten to spaces.
            let note = marker.note
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            if !note.isEmpty {
                lines.append("   note: \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
