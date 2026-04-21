
//
//  DownloadPipeline.swift
//  QuestSyndicate
//
//  Concurrent download → extract → install pipeline
//  Max 3 concurrent pipelines.
//
//  VRP server layout:
//    Each game is stored under a directory named after the MD5 hash of its releaseName.
//    The directory may contain multi-part archives: <hash>.7z.001, <hash>.7z.002, …
//    We use `rclone copy` (not copyto) to download the whole directory, then
//    locate the first part (.7z.001 or .7z) and hand it to 7-zip for extraction.
//

import Foundation
import CryptoKit

// MARK: - DownloadPipeline

@Observable
@MainActor
final class DownloadPipeline {

    // MARK: - Published state

    var queue: [DownloadItem] = []

    // MARK: - Private services

    private let rclone: RcloneService
    private let extraction: ExtractionService
    private let installation: InstallationService

    // MARK: - Internal state

    private var vrpConfig: VRPConfig?
    private var activeHandles: [String: StreamingHandle] = [:]
    private var activeCount = 0
    private let maxConcurrent = Constants.maxConcurrentDownloads
    private var connectedDevice: String?
    private var downloadPath: String = AppSettings.default.downloadPath

    private var downloadSpeedLimit: Int = 0

    /// Called on the main actor whenever an install succeeds.
    /// AppState wires this up to `refreshInstalledStatus()`.
    var onInstallComplete: (@MainActor () -> Void)?

    // MARK: - Init

    init(rclone: RcloneService, extraction: ExtractionService, installation: InstallationService) {
        self.rclone = rclone
        self.extraction = extraction
        self.installation = installation
    }

    // MARK: - Configuration

    func configure(vrpConfig: VRPConfig, downloadPath: String, speedLimit: Int = 0) {
        self.vrpConfig = vrpConfig
        self.downloadPath = downloadPath
        self.downloadSpeedLimit = speedLimit
        Task { await self.loadPersistedQueue() }
    }

    func setConnectedDevice(_ deviceId: String?) {
        self.connectedDevice = deviceId
    }

    func setDownloadPath(_ path: String) {
        self.downloadPath = path
    }

    func setSpeedLimit(_ kbps: Int) {
        self.downloadSpeedLimit = kbps
    }

    // MARK: - Queue Operations

    func addToQueue(_ game: GameInfo) {
        // Don't add if already present (unless error/cancelled/completed/installError/signatureMismatch)
        if let existing = queue.first(where: { $0.releaseName == game.releaseName }) {
            if existing.status == .error || existing.status == .cancelled
                || existing.status == .completed || existing.status == .installError
                || existing.status == .signatureMismatch {
                // Do NOT delete files here — runPipeline will check if extracted files exist
                // and skip the download+extract steps if they do.
                queue.removeAll { $0.releaseName == game.releaseName }
            } else {
                return
            }
        }

        let item = DownloadItem(
            gameId: game.id,
            releaseName: game.releaseName,
            gameName: game.name,
            packageName: game.packageName,
            status: .queued,
            progress: 0,
            downloadPath: downloadPath,
            addedDate: Date().timeIntervalSince1970,
            thumbnailPath: game.thumbnailPath,
            size: game.size
        )
        queue.append(item)
        persistQueue()
        processNext()
    }

    func removeFromQueue(releaseName: String) {
        cancelItem(releaseName: releaseName)
        queue.removeAll { $0.releaseName == releaseName }
        deleteFiles(releaseName: releaseName)
        persistQueue()
    }

    func cancelItem(releaseName: String) {
        activeHandles[releaseName]?.cancel()
        activeHandles.removeValue(forKey: releaseName)
        updateItem(releaseName: releaseName, updates: { $0.status = .cancelled; $0.progress = 0 })
    }

    func pauseDownload(releaseName: String) {
        guard let item = queue.first(where: { $0.releaseName == releaseName }),
              item.status == .downloading else { return }
        activeHandles[releaseName]?.cancel()
        activeHandles.removeValue(forKey: releaseName)
        updateItem(releaseName: releaseName, updates: { $0.status = .paused })
        activeCount = max(0, activeCount - 1)
        processNext()
    }

    func resumeDownload(releaseName: String) {
        guard let item = queue.first(where: { $0.releaseName == releaseName }),
              item.status == .paused else { return }
        updateItem(releaseName: releaseName, updates: { $0.status = .queued })
        processNext()
    }

    func retryDownload(releaseName: String) {
        guard let item = queue.first(where: { $0.releaseName == releaseName }),
              item.status.canRetry else { return }

        if item.status == .installError {
            // Files already on disk — just retry the install step, no re-download needed
            guard let deviceId = connectedDevice else {
                // No device — mark as completed so they can install later
                updateItem(releaseName: releaseName, updates: { $0.status = .completed; $0.error = nil })
                return
            }
            Task { await installFromCompleted(releaseName: releaseName, deviceSerial: deviceId) }
        } else {
            // Re-download from scratch
            updateItem(releaseName: releaseName, updates: {
                $0.status = .queued; $0.progress = 0; $0.error = nil
            })
            processNext()
        }
    }

    func deleteFiles(releaseName: String) {
        // Extracted content lives in downloadPath/releaseName/
        let extractDir = URL(fileURLWithPath: downloadPath).appendingPathComponent(releaseName)
        try? FileManager.default.removeItem(at: extractDir)
        // Archive parts staged in downloadPath/.staging/releaseName/
        let stagingDir = URL(fileURLWithPath: downloadPath)
            .appendingPathComponent(".staging")
            .appendingPathComponent(releaseName)
        try? FileManager.default.removeItem(at: stagingDir)
    }

    // MARK: - Install from completed

    func installFromCompleted(releaseName: String, deviceSerial: String) async {
        guard let item = queue.first(where: { $0.releaseName == releaseName }),
              item.status == .completed || item.status == .installError else { return }

        let extractedDir = URL(fileURLWithPath: item.downloadPath).appendingPathComponent(item.releaseName)
        updateItem(releaseName: releaseName, updates: {
            $0.status = .installing; $0.installStatus = nil; $0.installProgress = 0; $0.error = nil
        })

        do {
            _ = try await installation.install(
                extractedDirectory: extractedDir,
                packageName: item.packageName,
                deviceSerial: deviceSerial,
                onStatus: { [weak self] statusMsg in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                              self.queue[idx].status == .installing else { return }
                        self.queue[idx].installStatus = statusMsg
                    }
                },
                onProgress: { [weak self] pct in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                              self.queue[idx].status == .installing else { return }
                        self.queue[idx].installProgress = pct
                    }
                }
            )
            updateItem(releaseName: releaseName, updates: {
                $0.status = .completed; $0.installStatus = nil; $0.installProgress = nil; $0.isInstalledToDevice = true
            })
            persistQueue()
            onInstallComplete?()
        } catch let adbError as ADBError {
            if case .signatureMismatch = adbError {
                // Find the first APK in the extracted dir for the reinstall path
                let apkPath = Self.findFirstAPK(in: extractedDir)
                updateItem(releaseName: releaseName, updates: {
                    $0.status = .signatureMismatch
                    $0.installStatus = nil
                    $0.installProgress = nil
                    $0.error = "This game was signed with a different key. Reinstall required to update."
                    $0.pendingApkPath = apkPath?.path
                })
                persistQueue()
            } else {
                updateItem(releaseName: releaseName, updates: {
                    $0.status = .installError
                    $0.error = adbError.localizedDescription
                    $0.installStatus = nil
                    $0.installProgress = nil
                })
                persistQueue()
            }
        } catch {
            updateItem(releaseName: releaseName, updates: {
                $0.status = .installError
                $0.error = error.localizedDescription
                $0.installStatus = nil
                $0.installProgress = nil
            })
            persistQueue()
        }
    }

    // MARK: - Queue Processing

    private func processNext() {
        while activeCount < maxConcurrent {
            guard let item = queue.first(where: { $0.status == .queued }) else { break }
            activeCount += 1
            updateItem(releaseName: item.releaseName, updates: { $0.status = .downloading; $0.progress = 0 })
            Task { await runPipeline(for: item) }
        }
    }

    // MARK: - Pipeline

    private func runPipeline(for item: DownloadItem) async {
        defer {
            activeCount = max(0, activeCount - 1)
            processNext()
        }

        guard let config = vrpConfig else {
            updateItem(releaseName: item.releaseName, updates: {
                $0.status = .error; $0.error = "Server not configured"
            })
            return
        }

        // Extracted content lives at downloadPath/releaseName/
        let extractDir = URL(fileURLWithPath: item.downloadPath).appendingPathComponent(item.releaseName)

        // Check if extracted files already exist on disk (e.g. user disabled auto-delete).
        // If APKs are present, skip the download + extract steps entirely.
        if Self.hasAPKFiles(in: extractDir) {
            // Jump straight to the install step — files are already ready.
            updateItem(releaseName: item.releaseName, updates: {
                $0.status = .installing; $0.progress = 100; $0.installStatus = "Using existing files…"
            })
        } else {
            // 1. Download — archive parts land in a SEPARATE staging dir (.staging/releaseName/)
            //    so the cleanup after extraction doesn't delete the extracted APK files.
            let stagingDir = URL(fileURLWithPath: item.downloadPath)
                .appendingPathComponent(".staging")
                .appendingPathComponent(item.releaseName)

            do {
                try await downloadStep(item: item, config: config, stagingDir: stagingDir)
            } catch {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("cancel") {
                    return
                }
                let userMessage = Self.friendlyDownloadError(error)
                updateItem(releaseName: item.releaseName, updates: {
                    $0.status = .error; $0.error = userMessage
                })
                return
            }

            // 2. Extract — find the first part of the multi-part (or single) archive
            guard let archivePath = Self.findArchive(in: stagingDir) else {
                updateItem(releaseName: item.releaseName, updates: {
                    $0.status = .error; $0.error = "No archive found after download"
                })
                return
            }

            do {
                try await extractStep(item: item, archivePath: archivePath,
                                       extractDir: extractDir, password: config.password)
            } catch {
                updateItem(releaseName: item.releaseName, updates: {
                    $0.status = .error; $0.error = error.localizedDescription
                })
                return
            }
        }

        // 3. Install (only if device connected AND auto-install is enabled)
        let autoInstall = UserDefaults.standard.bool(forKey: "autoInstallAfterDownload")
        let autoDelete  = UserDefaults.standard.bool(forKey: "autoDeleteAfterInstall")

        if let deviceId = connectedDevice, autoInstall {
            updateItem(releaseName: item.releaseName, updates: {
                $0.status = .installing; $0.installStatus = nil; $0.installProgress = 0
            })
            let releaseName = item.releaseName
            do {
                _ = try await installation.install(
                    extractedDirectory: extractDir,
                    packageName: item.packageName,
                    deviceSerial: deviceId,
                    onStatus: { [weak self] statusMsg in
                        guard let self else { return }
                        Task { @MainActor in
                            guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                                  self.queue[idx].status == .installing else { return }
                            self.queue[idx].installStatus = statusMsg
                        }
                    },
                    onProgress: { [weak self] pct in
                        guard let self else { return }
                        Task { @MainActor in
                            guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                                  self.queue[idx].status == .installing else { return }
                            self.queue[idx].installProgress = pct
                        }
                    }
                )
                updateItem(releaseName: item.releaseName, updates: {
                    $0.status = .completed; $0.progress = 100; $0.installStatus = nil
                    $0.installProgress = nil; $0.isInstalledToDevice = true
                })
                onInstallComplete?()

                // Delete the extracted game folder + staging dir after a successful install
                if autoDelete {
                    deleteFiles(releaseName: item.releaseName)
                }
            } catch let adbError as ADBError {
                if case .signatureMismatch = adbError {
                    // Pause the pipeline and surface to the user for confirmation
                    let apkPath = Self.findFirstAPK(in: extractDir)
                    updateItem(releaseName: item.releaseName, updates: {
                        $0.status = .signatureMismatch
                        $0.installStatus = nil
                        $0.installProgress = nil
                        $0.error = "This game was signed with a different key. Reinstall required to update."
                        $0.pendingApkPath = apkPath?.path
                    })
                } else {
                    updateItem(releaseName: item.releaseName, updates: {
                        $0.status = .installError
                        $0.error = adbError.localizedDescription
                        $0.installStatus = nil
                        $0.installProgress = nil
                    })
                }
            } catch {
                updateItem(releaseName: item.releaseName, updates: {
                    $0.status = .installError
                    $0.error = error.localizedDescription
                    $0.installStatus = nil
                    $0.installProgress = nil
                })
            }
        } else {
            // No device connected or auto-install off — mark completed so user can install manually
            updateItem(releaseName: item.releaseName, updates: { $0.status = .completed; $0.progress = 100 })
        }

        persistQueue()
    }

    // MARK: - Download Step
    //
    // VRP server stores each game under:  <baseUri>/<md5(releaseName)>/
    // The directory contains files named: <md5(releaseName)>.7z.001  (and .002, .003, …)
    // We use `rclone copy` to download the entire directory into a local staging folder.

    private func downloadStep(item: DownloadItem, config: VRPConfig, stagingDir: URL) async throws {
        try? FileManager.default.createDirectoryIfNeeded(at: stagingDir)

        // The remote directory name is the lowercase MD5 hash of the releaseName
        let hash = Self.md5(item.releaseName)

        // rclone :http: source — needs leading slash: ":http:/<hash>/"
        let source = ":http:/\(hash)/"

        let releaseName = item.releaseName
        let handle = await rclone.downloadDirectory(
            source: source,
            destinationDir: stagingDir.path,
            httpUrl: config.baseUri,
            speedLimitKBps: downloadSpeedLimit,
            onProgress: { [weak self] progress in
                guard let self else { return }
                Task { @MainActor in
                    // Only update progress if still downloading — don't overwrite error/cancelled state
                    guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                          self.queue[idx].status == .downloading else { return }
                    self.queue[idx].progress = progress.percent
                    self.queue[idx].speed = progress.speed
                    self.queue[idx].eta = progress.eta
                }
            }
        )

        activeHandles[item.releaseName] = handle
        _ = try await handle.waitForCompletion()
        activeHandles.removeValue(forKey: item.releaseName)
    }

    // MARK: - Extract Step

    private func extractStep(item: DownloadItem, archivePath: URL,
                              extractDir: URL, password: String) async throws {
        updateItem(releaseName: item.releaseName, updates: {
            $0.status = .extracting; $0.extractProgress = 0
        })

        let releaseName = item.releaseName
        try await extraction.extract(
            archive: archivePath,
            destination: extractDir,
            password: password,
            key: item.releaseName,
            onProgress: { [weak self] pct in
                guard let self else { return }
                Task { @MainActor in
                    // Only update extract progress if still extracting
                    guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                          self.queue[idx].status == .extracting else { return }
                    self.queue[idx].extractProgress = pct
                }
            }
        )

        // Clean up the whole staging directory (contains all archive parts) after extraction
        try? FileManager.default.removeItem(at: archivePath.deletingLastPathComponent())
    }

    // MARK: - Item Mutation

    /// Copy-mutate-assign ensures the @Observable property setter fires,
    /// which guarantees SwiftUI re-renders immediately on every status change.
    private func updateItem(releaseName: String, updates: (inout DownloadItem) -> Void) {
        guard let idx = queue.firstIndex(where: { $0.releaseName == releaseName }) else { return }
        var item = queue[idx]
        updates(&item)
        queue[idx] = item   // explicit assignment → @Observable sees the write
    }

    // MARK: - Persistence

    private func persistQueue() {
        let saveable = queue.filter { $0.status != .cancelled }
        if let data = try? JSONEncoder().encode(saveable) {
            try? data.write(to: Constants.downloadQueuePath)
        }
    }

    private func loadPersistedQueue() async {
        guard let data = try? Data(contentsOf: Constants.downloadQueuePath),
              var saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }

        // Reset active states to queued on restart
        for i in saved.indices {
            let s = saved[i].status
            if s == .downloading || s == .extracting || s == .installing {
                saved[i].status = .queued
                saved[i].progress = 0
            }
        }
        queue = saved
        processNext()
    }

    // MARK: - Helpers

    /// Returns the MD5 hex digest of a string (lowercase), matching VRP server directory naming.
    /// VRP server computes: md5(releaseName + "\n") — the trailing newline is required.
    static func md5(_ string: String) -> String {
        let data = Data((string + "\n").utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true if `directory` contains at least one .apk file (recursively).
    /// Used to detect whether a previous download+extract run left files on disk.
    static func hasAPKFiles(in directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "apk" { return true }
        }
        return false
    }

    /// Finds the extraction entry-point archive inside a staging directory.
    /// Prefers .7z.001 (first part of multi-part) then falls back to .7z (single part).
    static func findArchive(in directory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        // Sort so .001 comes before .002 etc.
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Prefer multi-part first part
        if let part1 = sorted.first(where: { $0.pathExtension == "001" }) {
            return part1
        }
        // Fall back to single .7z
        if let single = sorted.first(where: { $0.pathExtension == "7z" }) {
            return single
        }
        return nil
    }

    // MARK: - Confirm Reinstall (signature mismatch flow)

    /// Called after the user confirms the signature-mismatch reinstall dialog.
    /// Picks up the pending APK path stored on the item and runs reinstallWithSaveBackup().
    func confirmReinstall(releaseName: String, deviceSerial: String) async {
        guard let item = queue.first(where: { $0.releaseName == releaseName }),
              item.status == .signatureMismatch else { return }

        guard let apkPathStr = item.pendingApkPath else {
            // No APK path stored — fall back to install-from-completed so user can try again
            updateItem(releaseName: releaseName, updates: {
                $0.status = .installError
                $0.error = "Could not find APK to reinstall. Please retry."
                $0.pendingApkPath = nil
            })
            persistQueue()
            return
        }

        let apkPath = URL(fileURLWithPath: apkPathStr)
        let packageName = item.packageName

        updateItem(releaseName: releaseName, updates: {
            $0.status = .installing
            $0.installStatus = "Preparing reinstall…"
            $0.installProgress = 0
            $0.error = nil
            $0.pendingApkPath = nil
        })

        do {
            _ = try await installation.reinstallWithSaveBackup(
                apkPath: apkPath,
                packageName: packageName,
                deviceSerial: deviceSerial,
                onStatus: { [weak self] statusMsg in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                              self.queue[idx].status == .installing else { return }
                        self.queue[idx].installStatus = statusMsg
                    }
                },
                onProgress: { [weak self] pct in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let idx = self.queue.firstIndex(where: { $0.releaseName == releaseName }),
                              self.queue[idx].status == .installing else { return }
                        self.queue[idx].installProgress = pct
                    }
                }
            )
            updateItem(releaseName: releaseName, updates: {
                $0.status = .completed
                $0.installStatus = nil
                $0.installProgress = nil
                $0.isInstalledToDevice = true
            })
            persistQueue()
            onInstallComplete?()
        } catch {
            updateItem(releaseName: releaseName, updates: {
                $0.status = .installError
                $0.error = error.localizedDescription
                $0.installStatus = nil
                $0.installProgress = nil
            })
            persistQueue()
        }
    }

    /// Returns the first .apk file found (recursively) in a directory, sorted by name.
    static func findFirstAPK(in directory: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var apks: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "apk" { apks.append(url) }
        }
        return apks.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Converts a raw rclone/process download error into a user-friendly message.
    ///
    /// rclone exit code 3 means the remote directory was not found — this happens when
    /// a game is listed in GameList.txt but its files haven't been uploaded to the VRP
    /// server yet (or were removed). Surface a clear, actionable message instead of the
    /// raw "Process exited 3: … error listing "": directory not found" string.
    static func friendlyDownloadError(_ error: Error) -> String {
        let raw   = error.localizedDescription
        let lower = raw.lowercased()

        // rclone exit 3 — remote directory does not exist on the server
        if lower.contains("directory not found") || lower.contains("error listing") {
            return "Game files not found on this server. This version may not have been uploaded yet — try switching mirrors in Settings or try again later."
        }

        // Network / connectivity issues
        if lower.contains("timeout") || lower.contains("timed out") {
            return "Download timed out. Check your internet connection and try again."
        }
        if lower.contains("connection refused") || lower.contains("no route to host")
            || lower.contains("network is unreachable") {
            return "Could not reach the server. Check your internet connection or try a different mirror."
        }

        // Generic rclone non-zero exit (some other server-side error)
        if lower.contains("process exited") {
            return "Download failed — the server returned an error. Try switching mirrors in Settings."
        }

        return raw
    }
}
