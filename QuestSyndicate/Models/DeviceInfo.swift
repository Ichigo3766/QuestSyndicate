
//
//  DeviceInfo.swift
//  QuestSyndicate
//

import Foundation

// MARK: - Quest Model Codenames

enum QuestModel: String, CaseIterable, Sendable {
    case monterey  = "monterey"
    case hollywood = "hollywood"
    case seacliff  = "seacliff"
    case eureka    = "eureka"
    case panther   = "panther"
    case sekiu     = "sekiu"

    nonisolated var friendlyName: String {
        switch self {
        case .monterey:  return "Oculus Quest"
        case .hollywood: return "Meta Quest 2"
        case .seacliff:  return "Meta Quest Pro"
        case .eureka:    return "Meta Quest 3"
        case .panther:   return "Meta Quest 3S"
        case .sekiu:     return "Meta XR Simulator"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .monterey, .hollywood, .eureka, .panther, .seacliff:
            return "visionpro"
        case .sekiu:
            return "desktopcomputer"
        }
    }

    nonisolated static func from(codename: String) -> QuestModel? {
        return QuestModel(rawValue: codename.lowercased())
    }
}

// MARK: - Device Type

enum DeviceType: String, Codable, Hashable, Sendable {
    case device        = "device"
    case emulator      = "emulator"
    case offline       = "offline"
    case unauthorized  = "unauthorized"
    case unknown       = "unknown"
    case wifiBookmark  = "wifi-bookmark"
}

// MARK: - Ping Status

enum PingStatus: String, Codable, Hashable, Sendable {
    case checking    = "checking"
    case reachable   = "reachable"
    case unreachable = "unreachable"
    case unknown     = "unknown"
}

// MARK: - DeviceInfo

struct DeviceInfo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var type: DeviceType
    var model: String?
    var isQuestDevice: Bool
    var batteryLevel: Int?
    var storageTotal: String?
    var storageFree: String?
    var friendlyModelName: String?
    var ipAddress: String?
    var pingStatus: PingStatus?
    var pingResponseTime: Int?  // milliseconds

    // Computed helpers
    nonisolated var displayName: String {
        friendlyModelName ?? model ?? id
    }

    nonisolated var isConnectable: Bool {
        type == .device || type == .emulator || type == .wifiBookmark
    }

    nonisolated var isWifi: Bool {
        id.contains(":") || type == .wifiBookmark
    }

    nonisolated var batteryIcon: String {
        guard let level = batteryLevel else { return "battery.0percent" }
        switch level {
        case 0..<20:  return "battery.0percent"
        case 20..<40: return "battery.25percent"
        case 40..<60: return "battery.50percent"
        case 60..<80: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    nonisolated var statusColor: StatusColor {
        switch type {
        case .device:        return .green
        case .emulator:      return .blue
        case .offline:       return .red
        case .unauthorized:  return .orange
        case .unknown:       return .gray
        case .wifiBookmark:
            switch pingStatus {
            case .reachable:    return .green
            case .unreachable:  return .red
            case .checking:     return .orange
            default:            return .gray
            }
        }
    }

    enum StatusColor: Sendable { case green, blue, red, orange, gray }
}

// MARK: - WiFiBookmark

struct WiFiBookmark: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String           // user-facing label (e.g. "Meta Quest 3")
    var ipAddress: String
    var port: Int
    var dateAdded: Date
    var lastConnected: Date?

    // Enriched device metadata — saved after a successful connection
    var deviceModelName: String?   // e.g. "Meta Quest 3"
    var modelCodename: String?     // e.g. "eureka"
    var lastBatteryLevel: Int?
    var lastStorageTotal: String?
    var lastStorageFree: String?

    nonisolated var serial: String { "\(ipAddress):\(port)" }

    /// Display label: device model name if known, otherwise the user-set name, otherwise the IP.
    nonisolated var displayLabel: String {
        deviceModelName ?? (name.isEmpty ? ipAddress : name)
    }

    /// SF Symbol for the model.
    nonisolated var modelSystemImage: String {
        guard let codename = modelCodename,
              let model = QuestModel.from(codename: codename) else {
            return "visionpro"
        }
        return model.systemImage
    }

    init(id: String = UUID().uuidString, name: String, ipAddress: String, port: Int = 5555) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.dateAdded = Date()
    }
}

// MARK: - PackageInfo

struct PackageInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String { packageName }
    var packageName: String
    var versionCode: Int
}
