
//
//  InstallationService.swift
//  QuestSyndicate
//
//  Serialised APK installation pipeline — natural via Swift actor
//
//  Flow:
//    1. Look for install.txt / Install.txt → execute line-by-line (mirrors ApprenticeVR)
//    2. Otherwise: standard install
//       a. Find all APKs recursively → adb install each (with streaming [XX%] progress)
//       b. Find OBB folder recursively → push file-by-file with progress (50-100%)
//

import Foundation

actor InstallationService {

    private let adb: ADBService

    init(adb: ADBService) {
        self.adb = adb
    }

    // MARK: - Install from extracted directory

    /// Installs a game from an already-extracted directory.
    /// Checks for install.txt first; falls back to standard APK+OBB install.
    /// - onStatus:   Called with human-readable status strings
    /// - onProgress: Called with 0–100 overall progress
    func install(
        extractedDirectory: URL,
        packageName: String,
        deviceSerial: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {

        // 1. Check for install.txt script (ApprenticeVR compatibility)
        let scriptURL = findInstallScript(in: extractedDirectory)
        if let scriptURL {
            onStatus("Running install script…")
            return try await executeInstallScript(
                scriptURL: scriptURL,
                baseDirectory: extractedDirectory,
                deviceSerial: deviceSerial,
                onStatus: onStatus,
                onProgress: onProgress
            )
        }

        // 2. Standard install
        return try await executeStandardInstall(
            extractedDirectory: extractedDirectory,
            packageName: packageName,
            deviceSerial: deviceSerial,
            onStatus: onStatus,
            onProgress: onProgress
        )
    }

    // MARK: - Install manual APK

    func installManualAPK(apkPath: URL, deviceSerial: String) async throws -> Bool {
        return try await adb.install(serial: deviceSerial, apkPath: apkPath, flags: ["-r", "-g"])
    }

    // MARK: - Reinstall With Save Backup (signature mismatch flow)

    /// Called after the user confirms they want to reinstall a game that has a signing key
    /// mismatch. Backs up save data, uninstalls, reinstalls, then restores saves.
    func reinstallWithSaveBackup(
        apkPath: URL,
        packageName: String,
        deviceSerial: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        return try await adb.reinstallWithSaveBackup(
            serial: deviceSerial,
            apkPath: apkPath,
            packageName: packageName,
            flags: ["-r", "-g"],
            onStatus: onStatus,
            onProgress: onProgress
        )
    }

    // MARK: - Copy OBB folder

    func copyOBBFolder(folderPath: URL, packageName: String, deviceSerial: String) async throws -> Bool {
        let remotePath = "/sdcard/Android/obb/\(packageName)"
        return try await pushDirectoryWithProgress(
            localDir: folderPath,
            remotePath: remotePath,
            serial: deviceSerial,
            onProgress: nil
        )
    }

    // MARK: - Standard Install

    private func executeStandardInstall(
        extractedDirectory: URL,
        packageName: String,
        deviceSerial: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Bool {

        // Single-pass scan: collect APKs and locate the OBB folder in one
        // FileManager.enumerator traversal instead of the previous 3 passes.
        let (apkPaths, obbFolder) = scanExtractedDirectory(extractedDirectory, packageName: packageName)
        guard !apkPaths.isEmpty else {
            throw NSError(domain: "QS", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "No APK files found in \(extractedDirectory.lastPathComponent)"])
        }

        let hasOBB = obbFolder != nil

        // Phase split: APK installs = 0–(hasOBB ? 50 : 100)%, OBB push = 50–100%
        let apkPhaseEnd: Double = hasOBB ? 50.0 : 100.0

        // Install each APK
        for (index, apkPath) in apkPaths.enumerated() {
            let apkLabel = apkPath.lastPathComponent
            onStatus("Installing \(apkLabel) (\(index + 1)/\(apkPaths.count))…")
            onProgress?(Double(index) / Double(apkPaths.count) * apkPhaseEnd)

            let success = try await adb.install(
                serial: deviceSerial,
                apkPath: apkPath,
                flags: ["-r", "-g"],
                onProgress: { pct in
                    let n = Double(apkPaths.count)
                    let base = Double(index) / n
                    let scaled = base + (pct / 100.0) / n
                    onProgress?(scaled * apkPhaseEnd)
                }
            )
            if !success {
                throw NSError(domain: "QS", code: 21,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to install \(apkPath.lastPathComponent)"])
            }
        }
        onProgress?(apkPhaseEnd)

        // Push OBB folder file-by-file with progress (50–100%)
        if let obbDir = obbFolder {
            onStatus("Pushing OBB data…")
            let remotePath = "/sdcard/Android/obb/\(packageName)"

            // Ensure base OBB directory exists on device
            _ = try? await adb.shell(deviceSerial, "mkdir -p /sdcard/Android/obb")

            let pushed = try await pushDirectoryWithProgress(
                localDir: obbDir,
                remotePath: remotePath,
                serial: deviceSerial,
                onProgress: { fraction in
                    // Map 0–1 to 50–100%
                    onProgress?(apkPhaseEnd + fraction * (100.0 - apkPhaseEnd))
                }
            )
            if !pushed {
                throw NSError(domain: "QS", code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to push OBB folder to device"])
            }
        }

        onProgress?(100)
        return true
    }

    // MARK: - Install Script (install.txt)

    /// Executes an install.txt script line-by-line, mirroring ApprenticeVR's installationProcessor.
    /// Supports: adb install, adb push, adb shell
    private func executeInstallScript(
        scriptURL: URL,
        baseDirectory: URL,
        deviceSerial: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Bool {

        let content: String
        do {
            content = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw NSError(domain: "QS", code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read install.txt: \(error.localizedDescription)"])
        }

        let commands = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !commands.isEmpty else {
            // Empty script — fall back to standard install
            return false
        }

        for (idx, command) in commands.enumerated() {
            let progressFraction = Double(idx) / Double(commands.count)
            onProgress?(progressFraction * 100)

            // Tokenise, respecting quoted strings
            let parts = tokenise(command)
            guard parts.count >= 2, parts[0].lowercased() == "adb" else {
                // Skip non-adb lines
                continue
            }

            let subcommand = parts[1].lowercased()
            let args = Array(parts.dropFirst(2))

            switch subcommand {

            case "install":
                // adb install [-r] [-g] <file.apk>
                guard let apkArg = args.last(where: { $0.lowercased().hasSuffix(".apk") }) else {
                    continue
                }
                let apkURL = baseDirectory.appendingPathComponent(apkArg)
                guard FileManager.default.fileExists(atPath: apkURL.path) else {
                    throw NSError(domain: "QS", code: 31,
                        userInfo: [NSLocalizedDescriptionKey: "APK not found: \(apkArg)"])
                }
                let flags = args.filter { $0.hasPrefix("-") }
                let combinedFlags = Array(Set(["-r", "-g"] + flags))
                onStatus("Installing \(apkURL.lastPathComponent)…")
                let ok = try await adb.install(
                    serial: deviceSerial,
                    apkPath: apkURL,
                    flags: combinedFlags,
                    onProgress: { pct in
                        let base = progressFraction
                        let step = 1.0 / Double(commands.count)
                        onProgress?((base + step * pct / 100.0) * 100)
                    }
                )
                if !ok {
                    throw NSError(domain: "QS", code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to install \(apkArg) from script"])
                }

            case "push":
                // adb push <local> <remote>
                guard args.count >= 2 else { continue }
                let localRel = args[0]
                let remotePath = args[1]
                let localURL = baseDirectory.appendingPathComponent(localRel)
                guard FileManager.default.fileExists(atPath: localURL.path) else {
                    // Non-fatal — log and continue
                    onStatus("Warning: push source not found: \(localRel)")
                    continue
                }
                onStatus("Pushing \(localURL.lastPathComponent)…")
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
                if isDir.boolValue {
                    _ = try await pushDirectoryWithProgress(
                        localDir: localURL,
                        remotePath: remotePath,
                        serial: deviceSerial,
                        onProgress: nil
                    )
                } else {
                    _ = try await adb.push(serial: deviceSerial, localPath: localURL, remotePath: remotePath)
                }

            case "shell":
                // adb shell <command...>
                guard !args.isEmpty else { continue }
                let shellCmd = args.joined(separator: " ")
                onStatus("Running: \(shellCmd)")
                _ = try? await adb.shell(deviceSerial, shellCmd)

            default:
                // Unsupported adb subcommand — skip
                break
            }
        }

        onProgress?(100)
        return true
    }

    // MARK: - Push Directory File-by-File with Progress

    /// Pushes every file inside `localDir` to `remotePath/<filename>` on the device.
    /// `onProgress` receives a fraction 0.0–1.0.
    private func pushDirectoryWithProgress(
        localDir: URL,
        remotePath: String,
        serial: String,
        onProgress: ((@Sendable (Double) -> Void))?
    ) async throws -> Bool {

        // Collect all files with their sizes
        let fileInfos = collectFiles(in: localDir)
        guard !fileInfos.isEmpty else { return true }   // empty OBB dir — not an error

        let totalBytes = fileInfos.reduce(0) { $0 + $1.size }
        var transferredBytes: Int64 = 0

        for info in fileInfos {
            // Compute relative path within localDir
            let relative = info.url.path
                .replacingOccurrences(of: localDir.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Compute remote file path
            let remoteFile: String
            if relative.isEmpty {
                remoteFile = remotePath + "/" + info.url.lastPathComponent
            } else {
                remoteFile = remotePath + "/" + relative
            }

            // Ensure parent directory exists on device
            let remoteDir = (remoteFile as NSString).deletingLastPathComponent
            _ = try? await adb.shell(serial, "mkdir -p \"\(remoteDir)\"")

            // Push the individual file
            _ = try await adb.push(serial: serial, localPath: info.url, remotePath: remoteFile)

            transferredBytes += info.size
            let fraction = totalBytes > 0 ? Double(transferredBytes) / Double(totalBytes) : 1.0
            onProgress?(fraction)
        }

        return true
    }

    // MARK: - Helpers

    private func findInstallScript(in directory: URL) -> URL? {
        for name in ["install.txt", "Install.txt"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Also check one level deep (some archives extract into a sub-folder)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return nil }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                for name in ["install.txt", "Install.txt"] {
                    let url = entry.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    /// Single-pass scan of `directory`:
    /// - Collects every .apk file (sorted by name).
    /// - Finds the best OBB folder for `packageName` using these priority rules:
    ///     1. A directory whose path ends with `…/Android/obb/<packageName>`
    ///        (canonical layout used by most games).
    ///     2. A directory named exactly `<packageName>` that contains at least
    ///        one .obb file (non-standard but common alternative layout).
    ///
    /// Replaces the previous three separate `FileManager.enumerator` calls
    /// (`findAPKs`, `findOBBFolder` → `findCanonicalOBBPath` + `containsOBBFile`).
    private func scanExtractedDirectory(
        _ directory: URL,
        packageName: String
    ) -> (apks: [URL], obbFolder: URL?) {

        var apks: [URL] = []

        // OBB candidates — we keep track of both priority levels so we can
        // pick the best one after the single enumeration pass completes.
        var canonicalOBB: URL? = nil          // …/Android/obb/<packageName>
        var fallbackOBBCandidate: URL? = nil  // dir named <packageName> — confirmed below

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], nil) }

        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            else { continue }

            if vals.isRegularFile == true {
                let ext = url.pathExtension.lowercased()
                if ext == "apk" {
                    apks.append(url)
                } else if ext == "obb", fallbackOBBCandidate == nil {
                    // An .obb file found → its parent directory is our fallback OBB folder
                    // if the parent is named <packageName>.
                    let parent = url.deletingLastPathComponent()
                    if parent.lastPathComponent == packageName {
                        fallbackOBBCandidate = parent
                    }
                }
            } else if vals.isDirectory == true {
                // Check for canonical Android/obb/<packageName> layout
                if canonicalOBB == nil {
                    let components = url.pathComponents
                    if components.count >= 3 {
                        let last3 = components.suffix(3)
                        if last3.first?.lowercased() == "android"
                            && last3.dropFirst().first?.lowercased() == "obb"
                            && last3.last == packageName {
                            canonicalOBB = url
                        }
                    }
                }
            }
        }

        let obbFolder = canonicalOBB ?? fallbackOBBCandidate
        return (apks.sorted { $0.lastPathComponent < $1.lastPathComponent }, obbFolder)
    }

    /// Collects all regular files under `directory` with their sizes.
    private func collectFiles(in directory: URL) -> [(url: URL, size: Int64)] {
        var result: [(url: URL, size: Int64)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            let size = Int64(vals?.fileSize ?? 0)
            result.append((url: url, size: size))
        }
        return result
    }

    /// Splits a shell-style command line into tokens, respecting double-quoted strings.
    private func tokenise(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
