
//
//  DependencyManager.swift
//  QuestSyndicate
//
//  Manages bundled + downloaded CLI binaries (adb, rclone, 7zz)
//

import Foundation
import Network

// MARK: - DependencyStatus

enum DependencyReadiness {
    case unknown, checking, ready, downloading(progress: Double), failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - DependencyManager

@Observable
final class DependencyManager {

    var adbStatus:      DependencyReadiness = .unknown
    var rcloneStatus:   DependencyReadiness = .unknown
    var sevenZipStatus: DependencyReadiness = .unknown
    var overallReady: Bool = false
    var setupError: String?
    var isSettingUp: Bool = false

    private let runner = ProcessRunner()

    // MARK: - Entry point

    func setup() async {
        guard !isSettingUp else { return }
        isSettingUp = true
        setupError = nil

        // Ensure directories exist
        for dir in [Constants.binDirectory, Constants.appSupportDirectory,
                    Constants.vrpDataDirectory, Constants.mirrorsDirectory] {
            try? FileManager.default.createDirectoryIfNeeded(at: dir)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkOrInstallADB() }
            group.addTask { await self.checkOrInstallRclone() }
            group.addTask { await self.checkOrInstall7Zip() }
        }

        let allReady = adbStatus.isReady && rcloneStatus.isReady && sevenZipStatus.isReady
        overallReady = allReady
        isSettingUp = false

        if !allReady {
            setupError = "One or more tools failed to install. Please check your internet connection."
        }
    }

    // MARK: - ADB

    private func checkOrInstallADB() async {
        adbStatus = .checking
        let adbURL = Constants.adbPath

        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil) {
            try? FileManager.default.copyItem(at: bundled, to: adbURL)
            try? setExecutable(at: adbURL)
        }

        if FileManager.default.isExecutableFile(atPath: adbURL.path) {
            adbStatus = .ready
            return
        }

        adbStatus = .downloading(progress: 0)
        do {
            let zipURL = Constants.binDirectory.appendingPathComponent("platform-tools.zip")
            try await downloadFile(from: Constants.adbMacDownloadURL, to: zipURL) { p in
                self.adbStatus = .downloading(progress: p)
            }

            let extractDir = Constants.binDirectory.appendingPathComponent("platform-tools-tmp")
            try? FileManager.default.removeItem(at: extractDir)
            try await unzipFile(at: zipURL, to: extractDir)

            let adbSource = extractDir.appendingPathComponent("platform-tools/adb")
            guard FileManager.default.fileExists(atPath: adbSource.path) else {
                throw NSError(domain: "QS", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "adb not found in platform-tools archive"])
            }
            try? FileManager.default.removeItem(at: adbURL)
            try FileManager.default.copyItem(at: adbSource, to: adbURL)
            try setExecutable(at: adbURL)

            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: extractDir)

            adbStatus = .ready
        } catch {
            adbStatus = .failed("ADB download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - rclone

    private func checkOrInstallRclone() async {
        rcloneStatus = .checking
        let rcloneURL = Constants.rclonePath

        if let bundled = Bundle.main.url(forResource: "rclone", withExtension: nil) {
            try? FileManager.default.copyItem(at: bundled, to: rcloneURL)
            try? setExecutable(at: rcloneURL)
        }

        if FileManager.default.isExecutableFile(atPath: rcloneURL.path) {
            rcloneStatus = .ready
            return
        }

        rcloneStatus = .downloading(progress: 0)
        do {
            let releaseData = try await fetchData(from: Constants.rcloneReleasesAPI)
            guard let json = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else {
                throw NSError(domain: "QS", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid rclone release data"])
            }

            let arch = isAppleSilicon() ? "arm64" : "amd64"
            let assetPattern = "rclone-.*-osx-\(arch)\\.zip"

            guard let asset = assets.first(where: {
                let name = $0["name"] as? String ?? ""
                return name.range(of: assetPattern, options: .regularExpression) != nil
            }),
            let downloadURLStr = asset["browser_download_url"] as? String,
            let downloadURL = URL(string: downloadURLStr) else {
                throw NSError(domain: "QS", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "rclone asset not found for \(arch)"])
            }

            let zipURL = Constants.binDirectory.appendingPathComponent("rclone.zip")
            try await downloadFile(from: downloadURL, to: zipURL) { p in
                self.rcloneStatus = .downloading(progress: p)
            }

            let extractDir = Constants.binDirectory.appendingPathComponent("rclone-tmp")
            try? FileManager.default.removeItem(at: extractDir)
            try await unzipFile(at: zipURL, to: extractDir)

            guard let rcloneSource = findFile(named: "rclone", in: extractDir) else {
                throw NSError(domain: "QS", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "rclone binary not found in archive"])
            }

            try? FileManager.default.removeItem(at: rcloneURL)
            try FileManager.default.copyItem(at: rcloneSource, to: rcloneURL)
            try setExecutable(at: rcloneURL)

            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: extractDir)

            rcloneStatus = .ready
        } catch {
            rcloneStatus = .failed("rclone download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 7-Zip

    private func checkOrInstall7Zip() async {
        sevenZipStatus = .checking
        let sevenzURL = Constants.sevenZipPath

        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil) {
            try? FileManager.default.copyItem(at: bundled, to: sevenzURL)
            try? setExecutable(at: sevenzURL)
        }

        if FileManager.default.isExecutableFile(atPath: sevenzURL.path) {
            sevenZipStatus = .ready
            return
        }

        sevenZipStatus = .downloading(progress: 0)
        do {
            let downloadURL = await resolveSevenZipDownloadURL()

            let tarURL = Constants.binDirectory.appendingPathComponent("7z.tar.xz")
            try await downloadFile(from: downloadURL, to: tarURL) { p in
                self.sevenZipStatus = .downloading(progress: p)
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: tarURL.path)[.size] as? Int) ?? 0
            if fileSize < 1000 {
                throw NSError(domain: "QS", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file too small (\(fileSize) bytes) — likely a bad URL"])
            }

            let extractDir = Constants.binDirectory.appendingPathComponent("7z-tmp")
            try? FileManager.default.removeItem(at: extractDir)
            try FileManager.default.createDirectoryIfNeeded(at: extractDir)

            let tarResult = try await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", tarURL.path, "-C", extractDir.path]
            )

            if tarResult.exitCode != 0 {
                throw NSError(domain: "QS", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "tar extraction failed (code \(tarResult.exitCode)): \(tarResult.stderr)"])
            }

            guard let sevenSource = findFile(named: "7zz", in: extractDir) else {
                let allFiles = allFilesInDirectory(extractDir)
                throw NSError(domain: "QS", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "7zz binary not found in archive. Found: \(allFiles.prefix(10).joined(separator: ", "))"])
            }

            try? FileManager.default.removeItem(at: sevenzURL)
            try FileManager.default.copyItem(at: sevenSource, to: sevenzURL)
            try setExecutable(at: sevenzURL)

            try? FileManager.default.removeItem(at: tarURL)
            try? FileManager.default.removeItem(at: extractDir)

            sevenZipStatus = .ready
        } catch {
            sevenZipStatus = .failed("7-Zip download failed: \(error.localizedDescription)")
        }
    }

    /// Try GitHub API first, fall back to hardcoded URL
    private func resolveSevenZipDownloadURL() async -> URL {
        guard let releaseData = try? await fetchData(from: Constants.sevenZipGitHubReleasesAPI),
              let json = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            return Constants.sevenZipMacDownloadURL
        }

        if let asset = assets.first(where: {
            let name = ($0["name"] as? String ?? "").lowercased()
            return name.contains("mac") && name.hasSuffix(".tar.xz")
        }),
        let urlStr = asset["browser_download_url"] as? String,
        let url = URL(string: urlStr) {
            return url
        }

        return Constants.sevenZipMacDownloadURL
    }

    // MARK: - File Search Helpers

    /// Recursively find the first file with the given name in a directory
    private func findFile(named name: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == name {
                return fileURL
            }
        }
        return nil
    }

    /// Return all file names found recursively (for error messages)
    private func allFilesInDirectory(_ directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var names: [String] = []
        for case let fileURL as URL in enumerator {
            names.append(fileURL.lastPathComponent)
        }
        return names
    }

    // MARK: - Process Helper

    private func runProcess(executable: URL, arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.executableURL = executable
            proc.arguments = arguments
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            proc.terminationHandler = { p in
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (p.terminationStatus, out, err))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func setExecutable(at url: URL) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private func isAppleSilicon() -> Bool {
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafeBytes(of: &sysInfo.machine) { rawPtr -> String in
            let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.contains("arm")
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("QuestSyndicate/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func downloadFile(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            var request = URLRequest(url: url)
            request.setValue("QuestSyndicate/1.0", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: request) { tempURL, _, error in
                observation?.invalidate()
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.resume(throwing: NSError(domain: "QS", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No temp file"]))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.observe(\.progress.fractionCompleted) { t, _ in
                progress(t.progress.fractionCompleted * 100)
            }
            task.resume()
        }
    }

    private func unzipFile(at zipURL: URL, to destination: URL) async throws {
        try FileManager.default.createDirectoryIfNeeded(at: destination)
        let result = try await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", zipURL.path, "-d", destination.path]
        )
        if result.exitCode != 0 {
            throw NSError(domain: "QS", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "unzip failed with code \(result.exitCode): \(result.stderr)"])
        }
    }
}
