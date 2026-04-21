
//
//  DownloadItem.swift
//  QuestSyndicate
//

import Foundation
import SwiftUI

// MARK: - DownloadStatus

enum DownloadStatus: String, Codable, Hashable, CaseIterable {
    case queued              = "Queued"
    case downloading         = "Downloading"
    case paused              = "Paused"
    case extracting          = "Extracting"
    case installing          = "Installing"
    case completed           = "Completed"
    case error               = "Error"
    case cancelled           = "Cancelled"
    case installError        = "InstallError"
    /// Waiting for user confirmation before doing a full uninstall+reinstall
    /// to resolve a signing-key mismatch. Save data will be backed up first.
    case signatureMismatch   = "SignatureMismatch"

    var displayName: String { rawValue }

    var systemImage: String {
        switch self {
        case .queued:            return "clock"
        case .downloading:       return "arrow.down.circle"
        case .paused:            return "pause.circle"
        case .extracting:        return "archivebox"
        case .installing:        return "square.and.arrow.down"
        case .completed:         return "checkmark.circle.fill"
        case .error:             return "exclamationmark.circle.fill"
        case .cancelled:         return "xmark.circle"
        case .installError:      return "exclamationmark.triangle.fill"
        case .signatureMismatch: return "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .queued:            return .secondary
        case .downloading:       return .blue
        case .paused:            return .orange
        case .extracting:        return .purple
        case .installing:        return .indigo
        case .completed:         return .green
        case .error:             return .red
        case .cancelled:         return .secondary
        case .installError:      return .red
        case .signatureMismatch: return .orange
        }
    }

    var isActive: Bool {
        switch self {
        case .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    var canPause: Bool { self == .downloading }
    var canResume: Bool { self == .paused }
    var canCancel: Bool { isActive || self == .queued || self == .paused }
    var canRetry: Bool { self == .error || self == .cancelled || self == .installError }
    var canDelete: Bool { self == .completed || self == .error || self == .cancelled || self == .installError || self == .signatureMismatch }
}

// MARK: - DownloadItem

struct DownloadItem: Identifiable, Hashable, Codable {
    var id: String { releaseName }
    var gameId: String
    var releaseName: String
    var gameName: String
    var packageName: String
    var status: DownloadStatus
    var progress: Double          // 0–100 overall
    var error: String?
    var downloadPath: String
    var pid: Int?
    var addedDate: TimeInterval   // Date().timeIntervalSince1970
    var thumbnailPath: String?
    var speed: String?
    var eta: String?
    var extractProgress: Double?  // 0–100
    var installProgress: Double?  // 0–100 (APK push progress from adb)
    var installStatus: String?    // live status message during install
    var size: String?
    /// True once the item has been successfully installed to a device via adb.
    var isInstalledToDevice: Bool = false
    /// The local path to the APK that triggered a signature mismatch.
    /// Set when status transitions to .signatureMismatch so confirmReinstall() can pick it up.
    var pendingApkPath: String?

    // MARK: Computed

    var addedDateValue: Date { Date(timeIntervalSince1970: addedDate) }

    var displayProgress: Double {
        let raw: Double
        switch status {
        case .extracting:
            raw = extractProgress ?? progress
        default:
            raw = progress
        }
        // Clamp to 0–100 to prevent ProgressView out-of-bounds warnings
        return min(max(raw, 0), 100)
    }

    var statusDescription: String {
        switch status {
        case .downloading:
            var parts: [String] = []
            if let speed = speed { parts.append(speed) }
            if let eta = eta { parts.append("ETA: \(eta)") }
            return parts.isEmpty ? "Downloading…" : parts.joined(separator: " · ")
        case .extracting:
            if let ep = extractProgress {
                return "Extracting \(Int(ep))%"
            }
            return "Extracting…"
        case .installing:
            if let ip = installProgress, ip > 0 {
                let pct = Int(ip)
                if let msg = installStatus {
                    return "\(msg) \(pct)%"
                }
                return "Installing… \(pct)%"
            }
            return installStatus ?? "Installing…"
        case .error:
            return error ?? "Unknown error"
        case .installError:
            return error ?? "Install failed"
        default:
            return status.displayName
        }
    }
}

// MARK: - DownloadProgress (progress event)

struct DownloadProgressEvent {
    var packageName: String
    var stage: Stage
    var progress: Double

    enum Stage: String {
        case download, extract, copy, install
    }
}
