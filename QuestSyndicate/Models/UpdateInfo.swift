
//
//  UpdateInfo.swift
//  QuestSyndicate
//

import Foundation

struct CommitInfo: Identifiable, Codable, Equatable {
    var id: String { sha }
    var sha: String
    var message: String
    var author: String
    var date: String
    var url: String
}

struct UpdateInfo: Codable, Equatable {
    var version: String
    var releaseNotes: String?
    var releaseDate: String?
    var downloadUrl: String?
    var commits: [CommitInfo]?

    init(
        version: String,
        releaseNotes: String? = nil,
        releaseDate: String? = nil,
        downloadUrl: String? = nil,
        commits: [CommitInfo]? = nil
    ) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.releaseDate = releaseDate
        self.downloadUrl = downloadUrl
        self.commits = commits
    }
}

struct AppSettings: Codable {
    var downloadPath: String
    var downloadSpeedLimit: Int   // KB/s, 0 = unlimited
    var uploadSpeedLimit: Int     // KB/s, 0 = unlimited
    var hideAdultContent: Bool
    var colorScheme: AppColorScheme

    enum AppColorScheme: String, Codable, CaseIterable {
        case system = "system"
        case light  = "light"
        case dark   = "dark"

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
    }

    static var `default`: AppSettings {
        AppSettings(
            downloadPath: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads",
            downloadSpeedLimit: 0,
            uploadSpeedLimit: 0,
            hideAdultContent: false,
            colorScheme: .system
        )
    }
}

