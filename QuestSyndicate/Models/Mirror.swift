
//
//  Mirror.swift
//  QuestSyndicate
//

import Foundation

// MARK: - MirrorConfig

struct MirrorConfig: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var type: String          // rclone remote type: ftp, http, webdav, etc.
    var host: String
    var port: Int?
    var user: String?
    var pass: String?
    var path: String?
    var md5sumCommand: String?
    var sha1sumCommand: String?
    var additionalOptions: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, user, pass, path
        case md5sumCommand = "md5sum_command"
        case sha1sumCommand = "sha1sum_command"
        case additionalOptions
    }

    init(id: String = UUID().uuidString, name: String, type: String, host: String) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.additionalOptions = [:]
    }
}

// MARK: - MirrorTestStatus

enum MirrorTestStatus: String, Codable, Hashable {
    case untested = "untested"
    case testing  = "testing"
    case success  = "success"
    case failed   = "failed"

    var systemImage: String {
        switch self {
        case .untested: return "questionmark.circle"
        case .testing:  return "arrow.trianglehead.clockwise"
        case .success:  return "checkmark.circle.fill"
        case .failed:   return "xmark.circle.fill"
        }
    }
}

// MARK: - Mirror

struct Mirror: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var config: MirrorConfig
    var isActive: Bool
    var lastTested: Date?
    var testStatus: MirrorTestStatus
    var testError: String?
    var addedDate: Date

    init(id: String = UUID().uuidString, name: String, config: MirrorConfig) {
        self.id = id
        self.name = name
        self.config = config
        self.isActive = false
        self.testStatus = .untested
        self.addedDate = Date()
    }
}

// MARK: - MirrorTestResult

struct MirrorTestResult: Identifiable, Codable {
    var id: String
    var success: Bool
    var responseTime: TimeInterval?
    var error: String?
    var timestamp: Date
}
