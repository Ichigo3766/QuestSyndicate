
//
//  UploadService.swift
//  QuestSyndicate
//
//  Pulls APK/OBB from device, zips, uploads via rclone
//

import Foundation
import CryptoKit

@Observable
final class UploadService {

    var queue: [UploadItem] = []

    private let adb: ADBService
    private let extraction: ExtractionService
    private let rclone: RcloneService

    private var activeHandles: [String: StreamingHandle] = [:]
    private var isProcessing = false
    private var uploadSpeedLimit: Int = 0

    // Rclone config for uploads — fetched from vrpirates.wiki
    private var uploadConfigPath: String?
    private var uploadRemote: String?

    init(adb: ADBService, extraction: ExtractionService, rclone: RcloneService) {
        self.adb = adb
        self.extraction = extraction
        self.rclone = rclone
    }

    func configure(speedLimit: Int) {
        self.uploadSpeedLimit = speedLimit
    }

    // MARK: - Queue Management

    func addToQueue(packageName: String, gameName: String, versionCode: Int, deviceId: String) {
        guard !queue.contains(where: { $0.packageName == packageName }) else { return }
        let item = UploadItem(
            packageName: packageName, gameName: gameName,
            versionCode: versionCode, deviceId: deviceId,
            status: .queued, progress: 0,
            addedDate: Date().timeIntervalSince1970
        )
        queue.append(item)
        persistQueue()
        processNext()
    }

    func removeFromQueue(packageName: String) {
        cancelUpload(packageName: packageName)
        queue.removeAll { $0.packageName == packageName }
        persistQueue()
    }

    func cancelUpload(packageName: String) {
        activeHandles[packageName]?.cancel()
        activeHandles.removeValue(forKey: packageName)
        updateItem(packageName: packageName) { $0.status = .cancelled }
    }

    // MARK: - Processing

    private func processNext() {
        guard !isProcessing,
              let item = queue.first(where: { $0.status == .queued }) else { return }
        isProcessing = true
        updateItem(packageName: item.packageName) { $0.status = .preparing }
        Task { await runUploadPipeline(for: item) }
    }

    private func runUploadPipeline(for item: UploadItem) async {
        // Capture packageName as a local constant so closures don't capture `item` across concurrency boundaries
        let packageName = item.packageName
        let deviceId = item.deviceId

        defer {
            isProcessing = false
            processNext()
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qs-upload-\(packageName)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        do {
            try FileManager.default.createDirectoryIfNeeded(at: workDir)

            // 1. Pull APK
            updateItem(packageName: packageName) { $0.stage = "Pulling APK…" }
            let apkLocal = workDir.appendingPathComponent("\(packageName).apk")
            let apkRemote = "/data/app/\(packageName)-1.apk"  // best-effort
            _ = try? await adb.pull(serial: deviceId, remotePath: apkRemote, localPath: apkLocal)

            // If above didn't work, get path via pm path
            if !FileManager.default.fileExists(atPath: apkLocal.path) {
                if let apkPath = try? await adb.shell(deviceId, "pm path \(packageName)"),
                   apkPath.hasPrefix("package:") {
                    let actualPath = String(apkPath.dropFirst(8))
                    _ = try? await adb.pull(serial: deviceId, remotePath: actualPath, localPath: apkLocal)
                }
            }

            // 2. Pull OBB folder
            updateItem(packageName: packageName) { $0.stage = "Pulling OBB data…" }
            let obbRemote = "/sdcard/Android/obb/\(packageName)"
            let obbLocal  = workDir.appendingPathComponent("Android/obb/\(packageName)")
            _ = try? await adb.pull(serial: deviceId, remotePath: obbRemote, localPath: obbLocal)

            // 3. Generate HWID.txt
            let hwid = generateHWID(deviceSerial: deviceId)
            let hwidFile = workDir.appendingPathComponent("HWID.txt")
            try hwid.write(to: hwidFile, atomically: true, encoding: .utf8)

            // 4. Compress to zip
            updateItem(packageName: packageName) { $0.stage = "Compressing…"; $0.status = .preparing }
            let zipPath = workDir.appendingPathComponent("\(packageName).zip")
            var sources: [URL] = [hwidFile]
            if FileManager.default.fileExists(atPath: apkLocal.path) { sources.append(apkLocal) }
            let obbParent = workDir.appendingPathComponent("Android")
            if FileManager.default.fileExists(atPath: obbParent.path) { sources.append(obbParent) }

            try await extraction.compress(
                sources: sources,
                destination: zipPath,
                key: "upload-\(packageName)",
                onProgress: { [weak self] pct in
                    Task { @MainActor [weak self] in
                        self?.updateItem(packageName: packageName) {
                            $0.progress = pct * 0.5  // first 50% is compression
                        }
                    }
                }
            )

            // 5. Upload via rclone
            guard let configPath = uploadConfigPath, let remote = uploadRemote else {
                throw NSError(domain: "QS", code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "Upload server not configured"])
            }

            updateItem(packageName: packageName) { $0.status = .uploading; $0.stage = "Uploading…" }
            let uploadHandle = await rclone.upload(
                source: zipPath.path,
                destination: "\(remote):/",
                configPath: configPath,
                speedLimitKBps: uploadSpeedLimit,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateItem(packageName: packageName) {
                            $0.progress = 50 + progress.percent * 0.5  // 50–100%
                        }
                    }
                }
            )
            activeHandles[packageName] = uploadHandle
            _ = try await uploadHandle.waitForCompletion()
            activeHandles.removeValue(forKey: packageName)

            updateItem(packageName: packageName) { $0.status = .completed; $0.progress = 100 }
            persistQueue()

        } catch {
            updateItem(packageName: packageName) {
                $0.status = .error
                $0.error = error.localizedDescription
            }
            persistQueue()
        }
    }

    // MARK: - HWID

    private func generateHWID(deviceSerial: String) -> String {
        let data = Data(deviceSerial.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Item Mutation

    private func updateItem(packageName: String, updates: (inout UploadItem) -> Void) {
        guard let idx = queue.firstIndex(where: { $0.packageName == packageName }) else { return }
        updates(&queue[idx])
    }

    // MARK: - Persistence

    private func persistQueue() {
        let saveable = queue.filter { $0.status != .cancelled }
        if let data = try? JSONEncoder().encode(saveable) {
            try? data.write(to: Constants.uploadQueuePath)
        }
    }
}
