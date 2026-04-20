
//
//  GameInfo.swift
//  QuestSyndicate
//

import Foundation

// MARK: - GameInfo

struct GameInfo: Identifiable, Hashable, Codable {
    /// Stable unique identity — always the Android package name.
    /// (releaseName can collide across entries; packageName is unique per app.)
    var id: String { packageName }
    var name: String
    var packageName: String
    var version: String
    var size: String
    var lastUpdated: String
    var releaseName: String
    var downloads: Int
    var thumbnailPath: String
    var notePath: String
    var isInstalled: Bool

    // MARK: - Codable id exclusion (id is computed, not stored)
    private enum CodingKeys: String, CodingKey {
        case name, packageName, version, size, lastUpdated
        case releaseName, downloads, thumbnailPath, notePath
        case isInstalled, deviceVersionCode, hasUpdate
    }
    var deviceVersionCode: Int?
    var hasUpdate: Bool?

    // MARK: - Cached parsed date (not Codable — derived from lastUpdated on init)
    /// Pre-parsed `Date` from `lastUpdated` string. Avoids repeated string parsing in
    /// `isRecentlyUpdated`, sort comparisons, and `formattedLastUpdated`. Set once by
    /// `GameLibraryService.parseGameList`; nil for device-only synthetic entries.
    var parsedDate: Date?

    // MARK: - Static shared formatter (P0-3: avoid allocating DateFormatter per call)
    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    // MARK: Computed

    var displaySize: String {
        if size.isEmpty { return "Unknown" }
        return size
    }

    var sizeInMB: Double {
        // Parses "1.5 GB" or "500 MB" style
        let components = size.split(separator: " ")
        guard components.count >= 2,
              let value = Double(components[0]) else { return 0 }
        let unit = String(components[1]).uppercased()
        switch unit {
        case "GB": return value * 1024
        case "MB": return value
        case "KB": return value / 1024
        default:   return value
        }
    }

    var formattedLastUpdated: String {
        // P0-3: Use cached parsedDate + static formatter — no allocation per call
        if let date = parsedDate {
            return Self.mediumDateFormatter.string(from: date)
        }
        return lastUpdated
    }

    var installStatus: InstallStatus {
        if isInstalled {
            return (hasUpdate == true) ? .updateAvailable : .installed
        }
        return .notInstalled
    }

    enum InstallStatus {
        case installed, updateAvailable, notInstalled

        var label: String {
            switch self {
            case .installed:       return "Installed"
            case .updateAvailable: return "Update"
            case .notInstalled:    return "Not Installed"
            }
        }

        var systemImage: String {
            switch self {
            case .installed:       return "checkmark.circle.fill"
            case .updateAvailable: return "arrow.down.circle.fill"
            case .notInstalled:    return "circle"
            }
        }
    }
}

// MARK: - BlacklistEntry

struct BlacklistEntry: Identifiable, Hashable, Codable {
    var id: String { "\(packageName)-\(versionString)" }
    var packageName: String
    var version: BlacklistVersion

    var versionString: String {
        switch version {
        case .any:           return "any"
        case .specific(let v): return String(v)
        }
    }

    enum BlacklistVersion: Hashable, Codable {
        case any
        case specific(Int)

        var description: String {
            switch self {
            case .any:           return "All Versions"
            case .specific(let v): return "v\(v)"
            }
        }
    }
}

// MARK: - UploadCandidate

struct UploadCandidate: Identifiable, Hashable {
    var id: String { packageName }
    var packageName: String
    var gameName: String
    var versionCode: Int
    var reason: CandidateReason
    var storeVersion: String?

    enum CandidateReason {
        case missing, newer

        var description: String {
            switch self {
            case .missing: return "Not in library"
            case .newer:   return "Newer version available"
            }
        }
    }
}
