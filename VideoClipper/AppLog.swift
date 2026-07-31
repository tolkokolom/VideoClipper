//
//  AppLog.swift
//  VideoClipper
//

import os

nonisolated enum AppLog {
    static let app = Logger(subsystem: "cc.kolom.VideoClipper", category: "app")
    static let editor = Logger(subsystem: "cc.kolom.VideoClipper", category: "editor")
    static let export = Logger(subsystem: "cc.kolom.VideoClipper", category: "export")
}
