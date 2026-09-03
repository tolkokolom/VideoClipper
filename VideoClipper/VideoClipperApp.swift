//
//  VideoClipperApp.swift
//  VideoClipper
//

import AppKit
import SwiftUI

@main
struct VideoClipperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(minWidth: 720, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .commands {
            AppCommands(model: model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // While a note field has focus, ⌘Z belongs to the text system —
            // forward to the responder chain instead of the edit history.
            Button("Undo") {
                if model.isEditingNote {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z")
            .disabled(!model.isEditingNote && !model.canUndo)
            Button("Redo") {
                if model.isEditingNote {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.isEditingNote && !model.canRedo)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Videos…") { model.openFiles() }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export") { model.exportSelected() }
                .keyboardShortcut("s")
                .disabled(model.selectedClip == nil)
            Button("Export As…") { model.exportSelected(chooseDestination: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.selectedClip == nil)
            Button("Copy Frames for Agent") { model.exportMarkedFrames() }
                .keyboardShortcut("e")
                .disabled(model.selectedClip?.markers.isEmpty ?? true)
        }

        CommandMenu("Clip") {
            Button("Rotate 90° Clockwise") { model.rotate() }
                .keyboardShortcut("r")
                .disabled(model.selectedClip == nil)
            Divider()
            Button("Set Trim In") { model.setTrimIn() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Button("Set Trim Out") { model.setTrimOut() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Divider()
            Button("Mark Frame") { model.toggleMarker() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Button("Edit Marker Note") { model.editNoteAtPlayhead() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Button(model.activeTool == .timeline ? "Delete Layer" : "Delete Selected Stroke") {
                if model.activeTool == .timeline {
                    model.deleteSelectedLayer()
                } else {
                    model.deleteSelectedStroke()
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.isEditingNote || (model.activeTool == .timeline
                ? model.selectedLayerID == nil
                : model.selectedStrokeID == nil))
            Button("Previous Marker") { model.jumpToMarker(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Button("Next Marker") { model.jumpToMarker(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(model.selectedClip == nil || model.isEditingNote || model.activeTool == .timeline)
            Divider()
            Button("Previous Clip") { model.selectNeighbor(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Clip") { model.selectNeighbor(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            Button("Remove Clip") { model.selectedClip.map { model.remove($0) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedClip == nil)
        }

        CommandMenu("Playback") {
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote)
            Button("Step Backward") { model.stepFrame(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote)
            Button("Step Forward") { model.stepFrame(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.selectedClip == nil || model.isEditingNote)
        }
    }
}
