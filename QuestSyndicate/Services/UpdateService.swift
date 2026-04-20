//
//  UpdateService.swift
//  QuestSyndicate
//
//  Checks GitHub Releases for a newer version and handles the full
//  download → mount → copy → relaunch update flow.
//

import Foundation
import Observation
import AppKit

// MARK: - GitHub API Response Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?          // changelog / release notes (Markdown)
    let publishedAt: String?
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName      = "tag_name"
        case name
        case body
        case publishedAt  = "published_at"
        case htmlUrl      = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

// MARK: - Update State

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
    case downloading(Double)   // 0.0 – 1.0
    case installing
    case failed(String)
}

// MARK: - UpdateService

@Observable
@MainActor
final class UpdateService {

    // MARK: - Published state

    private(set) var state: UpdateState = .idle
    private(set) var availableUpdate: UpdateInfo? = nil

    // MARK: - Private

    private var downloadTask: URLSessionDownloadTask? = nil
    private var progressObserver: NSKeyValueObservation? = nil

    /// How long to wait before checking again (hours)
    private static let checkIntervalHours: Double = 6

    /// UserDefaults key for last check timestamp
    private static let lastCheckKey = "updateService.lastCheckDate"

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Checks for an update silently (skips if checked recently).
    func checkIfNeeded() async {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date {
            let hoursSince = Date().timeIntervalSince(last) / 3600
            if hoursSince < Self.checkIntervalHours {
                return
            }
        }
        await checkForUpdate()
    }

    /// Forces an immediate check regardless of last-check time.
    func checkForUpdate() async {
        guard state != .checking else { return }
        state = .checking
        availableUpdate = nil

        do {
            let release = try await fetchLatestRelease()
            let remoteVersion = release.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
            let localVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            if isNewer(remote: remoteVersion, than: localVersion) {
                // Find the .dmg asset
                let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })

                let info = UpdateInfo(
                    version:      remoteVersion,
                    releaseNotes: release.body,
                    releaseDate:  release.publishedAt,
                    downloadUrl:  dmgAsset?.browserDownloadUrl,
                    commits:      nil
                )
                availableUpdate = info
                state = .available(info)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads the DMG and replaces the running app, then relaunches.
    func downloadAndInstall() async {
        guard case .available(let info) = state,
              let urlString = info.downloadUrl,
              let url = URL(string: urlString) else { return }

        state = .downloading(0)

        do {
            let dmgURL = try await downloadDMG(from: url)
            state = .installing
            try await installFromDMG(dmgURL)
            relaunch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Dismisses the available-update state (user chose "Later").
    func dismissUpdate() {
        if case .available = state {
            state = .upToDate
        }
        if case .failed = state {
            state = .idle
        }
    }

    // MARK: - Fetch

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Constants.githubReleasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Version Comparison

    /// Returns true if `remote` is a strictly newer semver than `local`.
    private func isNewer(remote: String, than local: String) -> Bool {
        let rv = semver(remote)
        let lv = semver(local)
        // Compare component-by-component (major, minor, patch)
        for (r, l) in zip(rv, lv) {
            if r > l { return true  }
            if r < l { return false }
        }
        return rv.count > lv.count  // 1.0.1 > 1.0
    }

    private func semver(_ s: String) -> [Int] {
        s.components(separatedBy: ".").compactMap { Int($0.filter(\.isNumber)) }
    }

    // MARK: - Download

    private func downloadDMG(from url: URL) async throws -> URL {
        // Use async/await download with progress reporting
        let (localURL, response) = try await URLSession.shared.download(for: URLRequest(url: url)) { [weak self] bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
            guard let self else { return }
            let progress: Double = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            Task { @MainActor in
                self.state = .downloading(progress)
            }
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        // Move to a stable temp path with .dmg extension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestSyndicateUpdate.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: localURL, to: dest)
        return dest
    }

    // MARK: - Install

    /// Mounts the DMG, copies the .app over the running bundle, then unmounts.
    private func installFromDMG(_ dmgURL: URL) async throws {
        let tempMount = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestSyndicateMount_\(UUID().uuidString)")

        // 1. Mount the DMG
        try await run("/usr/bin/hdiutil", args: [
            "attach", dmgURL.path,
            "-mountpoint", tempMount.path,
            "-nobrowse", "-quiet"
        ])

        defer {
            // Always try to unmount, even on failure
            Task.detached(priority: .utility) {
                try? await self.run("/usr/bin/hdiutil", args: [
                    "detach", tempMount.path, "-force", "-quiet"
                ])
            }
        }

        // 2. Find the .app inside the mounted volume
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempMount,
            includingPropertiesForKeys: nil
        )
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFoundInDMG
        }

        // 3. Determine destination (replace current running app)
        //    We use the bundle's parent directory — this handles both /Applications/
        //    and wherever the user placed the app.
        let currentBundle = Bundle.main.bundleURL
        let destination   = currentBundle.deletingLastPathComponent()
            .appendingPathComponent(appURL.lastPathComponent)

        // 4. Use a helper script so the replacement survives the running process:
        //    The script waits for this process to exit, then copies and relaunches.
        let script = makeUpdateScript(
            source: appURL.path,
            dest:   destination.path,
            mount:  tempMount.path,
            pid:    Int(ProcessInfo.processInfo.processIdentifier)
        )

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("questsyndicate_update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        // 5. Launch the script detached from this process (so it survives our exit)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [scriptURL.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try task.run()
        // Don't wait — we'll quit and the script continues
    }

    // MARK: - Update Script

    private func makeUpdateScript(source: String, dest: String, mount: String, pid: Int) -> String {
        // Escape paths for shell safety
        let src  = source.replacingOccurrences(of: "'", with: "'\\''")
        let dst  = dest.replacingOccurrences(of: "'", with: "'\\''")
        let mnt  = mount.replacingOccurrences(of: "'", with: "'\\''")

        return """
        #!/bin/zsh
        # QuestSyndicate auto-update helper
        # Waits for the old process to exit, replaces the app, relaunches.

        PID=\(pid)

        # Wait for the app to quit (up to 30 s)
        for i in {1..60}; do
            kill -0 $PID 2>/dev/null || break
            sleep 0.5
        done

        # Replace the app bundle
        rm -rf '\(dst)'
        cp -R '\(src)' '\(dst)'
        xattr -rc '\(dst)'         # clear quarantine flag

        # Unmount the DMG
        hdiutil detach '\(mnt)' -force -quiet 2>/dev/null || true

        # Relaunch
        open '\(dst)'

        # Clean up this script
        rm -f "$0"
        """
    }

    // MARK: - Relaunch

    private func relaunch() {
        NSApp.terminate(nil)
    }

    // MARK: - Shell Helper

    @discardableResult
    private func run(_ executable: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = pipe
            task.terminationHandler = { t in
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if t.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(
                        throwing: UpdateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
                    )
                }
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case appNotFoundInDMG
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG:
            return "Could not find the app inside the downloaded update package."
        case .commandFailed(let msg):
            return "Update command failed: \(msg)"
        }
    }
}

// MARK: - URLSession download with progress (back-compat helper)

private extension URLSession {
    func download(
        for request: URLRequest,
        progressHandler: @Sendable @escaping (Int64, Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.downloadTask(with: request) { url, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url, let response {
                    continuation.resume(returning: (url, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            // Observe progress
            let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let total = task.countOfBytesExpectedToReceive
                progressHandler(
                    task.countOfBytesReceived,
                    task.countOfBytesReceived,
                    total > 0 ? total : -1
                )
            }
            task.resume()
            // Keep observation alive for task lifetime (will be released on task completion)
            _ = observation
        }
    }
}
