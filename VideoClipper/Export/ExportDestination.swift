//
//  ExportDestination.swift
//  VideoClipper
//
//  Default export naming: the edit lands beside the source file as
//  "<base>-edit.<ext>", auto-incrementing to "-edit-2", "-edit-3", … so an
//  existing export (or the original) is never overwritten.
//

import Foundation

nonisolated enum ExportDestination {
    /// First free "<base>-edit[-N].<ext>" URL beside `source`. `ext` comes from the exported
    /// temp file (mp4 for re-encodes, mov for lossless passthrough). `fileExists` is injectable
    /// for tests.
    static func nextAvailable(
        besides source: URL,
        ext: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let folder = source.deletingLastPathComponent()
        for attempt in 1...10_000 {
            let name = attempt == 1 ? "\(base)-edit.\(ext)" : "\(base)-edit-\(attempt).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileExists(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(base)-edit-\(UUID().uuidString).\(ext)")
    }

    /// Moves the exported temp file into place; falls back to copy+delete across volumes.
    static func place(_ tempURL: URL, at destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: tempURL, to: destination)
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
