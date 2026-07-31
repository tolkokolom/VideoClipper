//
//  VideoClipperApp.swift
//  VideoClipper
//

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
        }

        CommandMenu("Clip") {
            Button("Rotate 90° Clockwise") { model.rotate() }
                .keyboardShortcut("r")
                .disabled(model.selectedClip == nil)
            Divider()
            Button("Set Trim In") { model.setTrimIn() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.selectedClip == nil)
            Button("Set Trim Out") { model.setTrimOut() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(model.selectedClip == nil)
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
                .disabled(model.selectedClip == nil)
            Button("Step Backward") { model.stepFrame(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.selectedClip == nil)
            Button("Step Forward") { model.stepFrame(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.selectedClip == nil)
        }
    }
}
