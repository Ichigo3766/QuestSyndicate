
//
//  ExtractionService.swift
//  QuestSyndicate
//
//  Wraps the bundled `7zz` binary for archive extraction
//

import Foundation

// MARK: - ExtractionError

enum ExtractionError: Error, LocalizedError {
    case binaryNotFound
    case extractionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:          return "7-Zip binary not found"
        case .extractionFailed(let m): return "Extraction failed: \(m)"
        case .cancelled:               return "Extraction cancelled"
        }
    }
}

// MARK: - ExtractionService

actor ExtractionService {

    private let runner = ProcessRunner()
    private var sevenZipPath: URL
    private var activeHandles: [String: StreamingHandle] = [:]

    init() {
        self.sevenZipPath = Constants.sevenZipPath
    }

    func updateSevenZipPath(_ url: URL) {
        self.sevenZipPath = url
    }

    // MARK: - Extract

    /// Extracts an archive with optional password.
    /// - Parameters:
    ///   - archive: Path to .7z archive
    ///   - destination: Directory to extract into
    ///   - password: Optional password (will be base64-decoded)
    ///   - key: Unique key for tracking/cancelling this operation
    ///   - onProgress: Called with 0–100 as extraction progresses
    func extract(
        archive: URL,
        destination: URL,
        password: String? = nil,
        key: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: sevenZipPath.path) else {
            throw ExtractionError.binaryNotFound
        }

        try FileManager.default.createDirectoryIfNeeded(at: destination)

        var args: [String] = ["x", archive.path, "-o\(destination.path)", "-y"]

        if let pwd = password {
            // Decode password from base64 if needed
            let decoded = pwd.base64Decoded ?? pwd
            args.append("-p\(decoded)")
        }

        // -bsp1 enables progress to stdout
        args.append("-bsp1")

        let handle = runner.runStreaming(sevenZipPath, arguments: args) { chunk in
            // Parse progress: "  X% N - filename" or "  X%"
            if let percent = Self.parseProgress(chunk) {
                onProgress(percent)
            }
        }

        activeHandles[key] = handle

        do {
            _ = try await handle.waitForCompletion()
            activeHandles.removeValue(forKey: key)
        } catch {
            activeHandles.removeValue(forKey: key)
            if case ProcessError.cancelled = error {
                throw ExtractionError.cancelled
            }
            throw ExtractionError.extractionFailed(error.localizedDescription)
        }
    }

    // MARK: - Cancel

    func cancel(key: String) {
        if let handle = activeHandles[key] {
            handle.cancel()
            activeHandles.removeValue(forKey: key)
        }
    }

    // MARK: - List Archive Contents

    func listContents(archive: URL, password: String? = nil) async throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: sevenZipPath.path) else {
            throw ExtractionError.binaryNotFound
        }
        var args = ["l", archive.path, "-slt"]
        if let pwd = password {
            args.append("-p\(pwd.base64Decoded ?? pwd)")
        }
        let out = try await runner.run(sevenZipPath, arguments: args)
        return out.stdout.components(separatedBy: "\n")
            .filter { $0.hasPrefix("Path = ") }
            .map { $0.replacingOccurrences(of: "Path = ", with: "").trimmed }
    }

    // MARK: - Compress (for uploads)

    func compress(
        sources: [URL],
        destination: URL,
        password: String? = nil,
        key: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: sevenZipPath.path) else {
            throw ExtractionError.binaryNotFound
        }

        var args: [String] = ["a", destination.path]
        args += sources.map { $0.path }
        if let pwd = password {
            args += ["-p\(pwd)", "-mhe=on"]
        }
        args += ["-bsp1", "-y"]

        let handle = runner.runStreaming(sevenZipPath, arguments: args) { chunk in
            if let percent = Self.parseProgress(chunk) {
                onProgress(percent)
            }
        }
        activeHandles[key] = handle

        do {
            _ = try await handle.waitForCompletion()
            activeHandles.removeValue(forKey: key)
        } catch {
            activeHandles.removeValue(forKey: key)
            throw ExtractionError.extractionFailed(error.localizedDescription)
        }
    }

    // MARK: - Progress Parsing

    /// Parses 7-zip progress output patterns:
    /// "  33% 12 - GameFile.apk"   →  33.0
    /// "  33%"                      →  33.0
    static func parseProgress(_ text: String) -> Double? {
        // Match N% pattern
        guard let range = text.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        let s = String(text[range]).replacingOccurrences(of: "%", with: "")
        return Double(s)
    }
}
