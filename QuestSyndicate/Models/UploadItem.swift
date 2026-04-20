
//
//  UploadItem.swift
//  QuestSyndicate
//

import Foundation
import SwiftUI

// MARK: - UploadStatus

enum UploadStatus: String, Codable, Hashable {
    case queued    = "Queued"
    case preparing = "Preparing"
    case uploading = "Uploading"
    case completed = "Completed"
    case error     = "Error"
    case cancelled = "Cancelled"

    var systemImage: String {
        switch self {
        case .queued:    return "clock"
        case .preparing: return "gearshape"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .error:     return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .queued:    return .secondary
        case .preparing: return .orange
        case .uploading: return .blue
        case .completed: return .green
        case .error:     return .red
        case .cancelled: return .secondary
        }
    }

    var isActive: Bool {
        self == .preparing || self == .uploading
    }
}

// MARK: - UploadItem

struct UploadItem: Identifiable, Hashable, Codable {
    var id: String { packageName }
    var packageName: String
    var gameName: String
    var versionCode: Int
    var deviceId: String
    var status: UploadStatus
    var progress: Double       // 0–100
    var stage: String?
    var error: String?
    var addedDate: TimeInterval
    var zipPath: String?

    var addedDateValue: Date { Date(timeIntervalSince1970: addedDate) }

    var statusDescription: String {
        switch status {
        case .preparing:
            return stage ?? "Preparing…"
        case .uploading:
            return "Uploading \(Int(progress))%"
        case .error:
            return error ?? "Upload failed"
        default:
            return status.rawValue
        }
    }
}

// MARK: - UploadPreparationProgress

struct UploadPreparationProgress {
    var packageName: String
    var stage: String
    var progress: Double
}
