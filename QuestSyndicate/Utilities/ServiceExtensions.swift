import SwiftUI
import Foundation

// MARK: - GameInfo formattedSize (size is already a String like "1.5 GB")
extension GameInfo {
    var formattedSize: String {
        size.isEmpty ? "Unknown" : size
    }

    /// versionCode as Int for Table sorting
    var versionCode: Int {
        Int(version) ?? 0
    }

    var versionName: String? {
        version.isEmpty ? nil : version
    }
}

// MARK: - DeviceInfo UI helpers
extension DeviceInfo {
    /// Serial = id in the model
    var serial: String { id }

    /// Whether connected via TCP/WiFi (serial contains ":")
    var isWireless: Bool {
        id.contains(":")
    }

    /// Parsed storage free in GB
    var storageFreeGB: Double? {
        storageFree.flatMap { parseStorageGB($0) }
    }

    /// Parsed storage total in GB
    var storageTotalGB: Double? {
        storageTotal.flatMap { parseStorageGB($0) }
    }

    private func parseStorageGB(_ s: String) -> Double? {
        let upper = s.uppercased()
        if upper.hasSuffix("G"), let v = Double(upper.dropLast()) { return v }
        if upper.hasSuffix("M"), let v = Double(upper.dropLast()) { return v / 1024.0 }
        if upper.hasSuffix("K"), let v = Double(upper.dropLast()) { return v / 1024.0 / 1024.0 }
        return Double(s)
    }
}

// MARK: - DownloadItem UI helpers
extension DownloadItem {
    /// Formatted download speed string
    var downloadSpeed: String? { speed }

    /// Total bytes from size string
    var totalBytes: Int64? {
        guard let s = size, !s.isEmpty else { return nil }
        let upper = s.uppercased()
        if upper.hasSuffix(" GB"), let v = Double(upper.dropLast(3)) { return Int64(v * 1_073_741_824) }
        if upper.hasSuffix(" MB"), let v = Double(upper.dropLast(3)) { return Int64(v * 1_048_576) }
        if upper.hasSuffix("GB"), let v = Double(upper.dropLast(2)) { return Int64(v * 1_073_741_824) }
        if upper.hasSuffix("MB"), let v = Double(upper.dropLast(2)) { return Int64(v * 1_048_576) }
        return nil
    }

    /// Normalised progress 0–1 for ProgressView
    var progressFraction: Double {
        (displayProgress / 100.0).clamped(to: 0...1)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

// MARK: - DownloadPipeline public API adapters
extension DownloadPipeline {
    /// Read the speed limit from UserDefaults (written by @AppStorage in views)
    var speedLimit: Int {
        UserDefaults.standard.integer(forKey: "downloadSpeedLimit")
    }

    /// Accept a URL and forward to the real String-based method on the pipeline
    func setDownloadPath(_ url: URL) {
        setDownloadPath(url.path)
    }

    // ID-based wrappers so views don't need to track releaseName separately
    func pauseDownload(id: String) { pauseDownload(releaseName: id) }
    func resumeDownload(id: String) { resumeDownload(releaseName: id) }
    func retryDownload(id: String) { retryDownload(releaseName: id) }
    func cancelItem(id: String) { cancelItem(releaseName: id) }
    func removeFromQueue(id: String) { removeFromQueue(releaseName: id) }
    func installFromCompleted(id: String, device: DeviceInfo) async {
        await installFromCompleted(releaseName: id, deviceSerial: device.id)
    }
}

// MARK: - UploadService public API adapters
extension UploadService {
    func addToQueue(candidate: UploadCandidate, deviceSerial: String) {
        addToQueue(packageName: candidate.packageName,
                   gameName: candidate.gameName,
                   versionCode: candidate.versionCode,
                   deviceId: deviceSerial)
    }

    func removeFromQueue(id: String) { removeFromQueue(packageName: id) }
    func cancelUpload(id: String) { cancelUpload(packageName: id) }
}

// MARK: - MirrorService adapters
extension MirrorService {
    /// Convenience sync wrapper – fires-and-forgets an async add
    func addMirrorAsync(configContent: String) {
        Task {
            _ = await addMirror(configContent: configContent)
        }
    }
}

// MARK: - GameLibraryService observable bridge
// Since GameLibraryService is an actor, we need an @Observable wrapper
@Observable
final class GameLibraryViewModel {
    private let service: GameLibraryService

    var games: [GameInfo] = []
    var vrpConfig: VRPConfig? = nil
    var isLoading = false
    var serverBlacklistCount = 0

    init(service: GameLibraryService) {
        self.service = service
    }

    func initialize() async {
        isLoading = true
        await service.initialize()
        await reload()
        isLoading = false
    }

    func forceSync(mirrorConfigPath: String? = nil, activeMirrorRemote: String? = nil) async throws {
        isLoading = true
        // Reload config first so that a freshly-saved ServerInfo.json is picked up
        await service.initialize()
        do {
            _ = try await service.forceSync(mirrorConfigPath: mirrorConfigPath,
                                            activeMirrorRemote: activeMirrorRemote)
        } catch {
            await reload()
            isLoading = false
            throw error
        }
        await reload()
        isLoading = false
    }

    func updateInstalledStatus(installedPackages: [PackageInfo]) async {
        await service.updateInstalledStatus(installedPackages: installedPackages)
        let updated = await service.getGames()
        await MainActor.run { self.games = updated }
    }

    func getNote(releaseName: String) async -> String? {
        let note = await service.getNote(releaseName: releaseName)
        return note.isEmpty ? nil : note
    }

    func getTrailerVideoId(releaseName: String) async -> String? {
        guard let game = games.first(where: { $0.releaseName == releaseName }) else { return nil }
        return await service.getTrailerVideoId(gameName: game.name)
    }

    func reloadBlacklist() async {
        await service.initialize()
        await reload()
    }

    private func reload() async {
        let g = await service.getGames()
        let config = await service.getConfig()
        let blacklistCount = await service.serverBlacklistCount()
        await MainActor.run {
            self.games = g
            self.vrpConfig = config
            self.serverBlacklistCount = blacklistCount
        }
    }
}

// MARK: - PackageInfo isThirdParty helper
extension PackageInfo {
    var isThirdParty: Bool {
        let systemPrefixes = ["com.android.", "com.oculus.os", "com.meta.os",
                              "android.", "com.qualcomm."]
        return !systemPrefixes.contains(where: { packageName.hasPrefix($0) })
    }
}

// MARK: - ADBService connectTcp throwing convenience
// The real connectTcp(ip:port:) returns Bool. This wrapper throws on failure.
extension ADBService {
    func connectTcpThrowing(ip: String, port: Int) async throws {
        let connected = try? await connectTcp(ip: ip, port: port)
        if connected != true {
            throw NSError(domain: "ADB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to connect to \(ip):\(port)"])
        }
    }
}

// MARK: - InstallStatus label
extension GameInfo.InstallStatus {
    var badgeLabel: String {
        switch self {
        case .installed: return "Installed"
        case .updateAvailable: return "Update"
        case .notInstalled: return "Available"
        }
    }
}

