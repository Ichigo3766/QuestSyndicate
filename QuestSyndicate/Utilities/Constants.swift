
//
//  Constants.swift
//  QuestSyndicate
//

import Foundation

enum Constants {
    // MARK: - App Support Paths

    nonisolated static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuestSyndicate", isDirectory: true)
    }

    nonisolated static var binDirectory: URL {
        appSupportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    nonisolated static var vrpDataDirectory: URL {
        appSupportDirectory.appendingPathComponent("vrp-data", isDirectory: true)
    }

    nonisolated static var mirrorsDirectory: URL {
        appSupportDirectory.appendingPathComponent("mirrors", isDirectory: true)
    }

    // MARK: - Binary Names

    nonisolated static var adbExecutableName: String { "adb" }
    nonisolated static var rcloneExecutableName: String { "rclone" }
    nonisolated static var sevenZipExecutableName: String { "7zz" }

    nonisolated static var adbPath: URL { binDirectory.appendingPathComponent(adbExecutableName) }
    nonisolated static var rclonePath: URL { binDirectory.appendingPathComponent(rcloneExecutableName) }
    nonisolated static var sevenZipPath: URL { binDirectory.appendingPathComponent(sevenZipExecutableName) }

    // MARK: - Config Files

    nonisolated static var serverInfoPath: URL {
        appSupportDirectory.appendingPathComponent("ServerInfo.json")
    }

    nonisolated static var vrpConfigPath: URL {
        vrpDataDirectory.appendingPathComponent("vrp-config.json")
    }

    nonisolated static var customBlacklistPath: URL {
        appSupportDirectory.appendingPathComponent("custom-blacklist.json")
    }

    nonisolated static var wifiBookmarksPath: URL {
        appSupportDirectory.appendingPathComponent("wifi-bookmarks.json")
    }

    nonisolated static var mirrorsConfigPath: URL {
        appSupportDirectory.appendingPathComponent("mirrors.json")
    }

    nonisolated static var downloadQueuePath: URL {
        appSupportDirectory.appendingPathComponent("download-queue.json")
    }

    nonisolated static var uploadQueuePath: URL {
        appSupportDirectory.appendingPathComponent("upload-queue.json")
    }

    nonisolated static var settingsPath: URL {
        appSupportDirectory.appendingPathComponent("settings.json")
    }

    // MARK: - ADB

    nonisolated static let questModels: Set<String> = [
        "monterey", "hollywood", "seacliff", "eureka", "panther", "sekiu"
    ]

    // MARK: - Download

    static let maxConcurrentDownloads = 3
    static let downloadDebounceMs: UInt64 = 300_000_000  // 300ms in nanoseconds

    // MARK: - GitHub

    static let githubRepo = "Ichigo3766/QuestSyndicate"
    static let githubReleasesURL = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
    static let githubReleasesPageURL = URL(string: "https://github.com/\(githubRepo)/releases")!
    static let githubRepoPageURL = URL(string: "https://github.com/\(githubRepo)")!

    // MARK: - ADB Download (Google Platform Tools for macOS)
    static let adbMacDownloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    // MARK: - rclone Download (GitHub)
    static let rcloneReleasesAPI = URL(string: "https://api.github.com/repos/rclone/rclone/releases/latest")!

    // MARK: - 7-Zip Download
    // Use GitHub releases API to find the latest 7-zip release for macOS
    static let sevenZipGitHubReleasesAPI = URL(string: "https://api.github.com/repos/ip7z/7zip/releases/latest")!
    // Fallback direct URL (updated to 24.09)
    static let sevenZipMacDownloadURL = URL(string: "https://github.com/ip7z/7zip/releases/download/24.09/7z2409-mac.tar.xz")!
}
