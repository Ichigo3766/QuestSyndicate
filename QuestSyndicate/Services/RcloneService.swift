
//
//  RcloneService.swift
//  QuestSyndicate
//
//  Wraps the bundled `rclone` CLI binary for downloads/uploads
//

import Foundation

// MARK: - RcloneProgress

struct RcloneProgress {
    var percent: Double
    var speed: String?
    var eta: String?
    var transferred: String?
}

// MARK: - RcloneService

actor RcloneService {

    private let runner = ProcessRunner()
    private var rclonePath: URL

    init() {
        self.rclonePath = Constants.rclonePath
    }

    func updateRclonePath(_ url: URL) {
        self.rclonePath = url
    }

    // MARK: - Download directory (rclone copy — used for VRP game archives)

    /// Downloads all files from a remote directory into a local destination folder.
    /// Use this for VRP game downloads where the server directory contains .7z.001, .7z.002 etc.
    /// Returns a handle for cancellation; progress is streamed via `onProgress`.
    func downloadDirectory(
        source: String,
        destinationDir: String,
        configPath: String? = nil,
        httpUrl: String? = nil,
        speedLimitKBps: Int = 0,
        onProgress: @escaping @Sendable (RcloneProgress) -> Void
    ) -> StreamingHandle {
        var args: [String] = ["copy", source, destinationDir,
                              "--tpslimit", "1.0", "--tpslimit-burst", "3",
                              "--no-check-certificate", "--progress"]

        if let config = configPath {
            args += ["--config", config]
        } else {
            args += ["--config", devNull()]
        }

        if let url = httpUrl {
            args += ["--http-url", url]
        }

        if speedLimitKBps > 0 {
            args += ["--bwlimit", "\(speedLimitKBps)k"]
        }

        return runner.runStreaming(rclonePath, arguments: args) { chunk in
            if let progress = Self.parseProgress(chunk) {
                onProgress(progress)
            }
        }
    }

    // MARK: - Download single file (rclone copyto — used for meta.7z sync)

    /// Downloads a single file using rclone copyto.
    /// Returns a handle for cancellation; progress is streamed via `onProgress`.
    func download(
        source: String,
        destination: String,
        configPath: String? = nil,
        httpUrl: String? = nil,
        speedLimitKBps: Int = 0,
        onProgress: @escaping @Sendable (RcloneProgress) -> Void
    ) -> StreamingHandle {
        var args: [String] = ["copyto", source, destination,
                              "--tpslimit", "1.0", "--tpslimit-burst", "3",
                              "--no-check-certificate", "--progress"]

        if let config = configPath {
            args += ["--config", config]
        } else {
            args += ["--config", devNull()]
        }

        if let url = httpUrl {
            args += ["--http-url", url]
        }

        if speedLimitKBps > 0 {
            args += ["--bwlimit", "\(speedLimitKBps)k"]
        }

        return runner.runStreaming(rclonePath, arguments: args) { chunk in
            if let progress = Self.parseProgress(chunk) {
                onProgress(progress)
            }
        }
    }

    // MARK: - Upload (copy)

    func upload(
        source: String,
        destination: String,
        configPath: String,
        speedLimitKBps: Int = 0,
        onProgress: @escaping @Sendable (RcloneProgress) -> Void
    ) -> StreamingHandle {
        var args: [String] = ["copy", source, destination,
                              "--config", configPath,
                              "--tpslimit", "1.0", "--tpslimit-burst", "3",
                              "--no-check-certificate", "--progress"]
        if speedLimitKBps > 0 {
            args += ["--bwlimit", "\(speedLimitKBps)k"]
        }
        return runner.runStreaming(rclonePath, arguments: args) { chunk in
            if let progress = Self.parseProgress(chunk) {
                onProgress(progress)
            }
        }
    }

    // MARK: - Test Mirror (lsd)

    func testMirror(remoteName: String, configPath: String) async throws -> TimeInterval {
        let start = Date()
        let args = ["lsd", "\(remoteName):", "--config", configPath,
                    "--no-check-certificate", "--timeout", "10s"]
        _ = try await runner.run(rclonePath, arguments: args)
        return Date().timeIntervalSince(start)
    }

    // MARK: - List directory

    func listDirectory(remote: String, configPath: String) async throws -> [String] {
        let out = try await runner.run(rclonePath, arguments: [
            "lsf", remote, "--config", configPath, "--no-check-certificate"
        ])
        return out.stdout.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
    }

    // MARK: - Progress Parsing

    /// Parses rclone --progress output:
    /// "Transferred:   5.584M / 10.000 MBytes, 56%, 1.000 MBytes/s, ETA 0s"
    static func parseProgress(_ text: String) -> RcloneProgress? {
        // Look for percentage on the "Transferred: N / N, X%" line (not the count line)
        // We need to find "N%" where the line also has a "/" indicating bytes transferred
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            // Match transfer lines like "Transferred:  21.996 MiB / 206.569 MiB, 11%, ..."
            guard line.contains("/") || line.contains("%") else { continue }
            guard let percentRange = line.range(of: #"(\d+)%"#, options: .regularExpression) else { continue }
            let percentStr = String(line[percentRange]).replacingOccurrences(of: "%", with: "")
            guard let percent = Double(percentStr) else { continue }

            // Speed
            var speed: String?
            if let speedRange = line.range(of: #"[\d.]+ [KMGT]i?Bytes/s"#, options: .regularExpression) {
                speed = String(line[speedRange])
            }

            // ETA
            var eta: String?
            if let etaRange = line.range(of: #"ETA (\S+)"#, options: .regularExpression) {
                eta = String(line[etaRange]).replacingOccurrences(of: "ETA ", with: "")
            }

            // Transferred
            var transferred: String?
            if let xferRange = line.range(of: #"Transferred:\s+[\d.]+ \S+"#, options: .regularExpression) {
                transferred = String(line[xferRange])
                    .replacingOccurrences(of: "Transferred:", with: "").trimmed
            }

            // Only return a progress if percent looks valid (0–100)
            if percent >= 0 && percent <= 100 {
                return RcloneProgress(percent: percent, speed: speed, eta: eta, transferred: transferred)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func devNull() -> String {
        "/dev/null"
    }

    /// Generates a temporary rclone config file for the given mirror config.
    func writeTempConfig(remoteName: String, options: [String: String]) throws -> URL {
        let configContent = INIParser.buildRcloneConfig(remoteName: remoteName, options: options)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclone-\(remoteName)-\(UUID().uuidString).conf")
        try configContent.write(to: tmpURL, atomically: true, encoding: .utf8)
        return tmpURL
    }
}
