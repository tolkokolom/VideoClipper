//
//  AppModelTests.swift
//  VideoClipperTests
//

import Foundation
import Testing
@testable import VideoClipper

struct AppModelTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/videoclipper-tests/\(name).mov")
    }

    @Test func addClipsFocusesFirstAddedWhenBinEmpty() {
        let model = AppModel()
        model.addClips(urls: [url("a"), url("b")])
        #expect(model.selectedClip?.url == url("a"))
    }

    @Test func addClipsRefocusesOnNewlyAddedClip() {
        let model = AppModel()
        model.addClips(urls: [url("a")])
        model.addClips(urls: [url("b"), url("c")])
        #expect(model.selectedClip?.url == url("b"))
    }

    @Test func duplicateDropFocusesExistingClip() {
        let model = AppModel()
        model.addClips(urls: [url("a"), url("b")]) // focuses a
        let handled = model.addClips(urls: [url("b")])
        #expect(handled)
        #expect(model.selectedClip?.url == url("b"))
    }

    @Test func nonVideoDropIsStillRejected() {
        let model = AppModel()
        let handled = model.addClips(urls: [URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(!handled)
        #expect(model.selectedClip == nil)
    }
}
