
//
//  ProcessRunner.swift
//  QuestSyndicate
//
//  Async/await wrapper around Foundation.Process
//  Handles stdout streaming, cancellation, and timeouts.
//

import Foundation

// MARK: - ProcessError

enum ProcessError: Error, LocalizedError {
    case executableNotFound(URL)
    case processTerminated(exitCode: Int32, stderr: String)
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "Executable not found: \(url.path)"
        case .processTerminated(let code, let err):
            return "Process exited \(code): \(err)"
        case .cancelled:
            return "Process was cancelled"
        case .timeout:
            return "Process timed out"
        }
    }
}

// MARK: - ProcessOutput

struct ProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - ProcessRunner

actor ProcessRunner {

    // MARK: - Simple run (collect all output)

    func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.executableNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process    = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL   = executable
            process.arguments       = arguments
            process.standardOutput  = stdoutPipe
            process.standardError   = stderrPipe
            if let env = environment {
                process.environment = env
            }

            process.terminationHandler = { proc in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""

                let code = proc.terminationStatus
                if code == 0 {
                    continuation.resume(returning: ProcessOutput(exitCode: code, stdout: stdout, stderr: stderr))
                } else {
                    continuation.resume(throwing: ProcessError.processTerminated(exitCode: code, stderr: stderr))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Streaming run (real-time stdout callback)

    /// Runs a process and streams stdout lines as they arrive.
    /// Returns a cancellable handle. Throws on non-zero exit.
    nonisolated func runStreaming(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) -> StreamingHandle {
        let handle = StreamingHandle()
        handle.startProcess(executable: executable, arguments: arguments,
                            environment: environment, onOutput: onOutput)
        return handle
    }

    // MARK: - Convenience: run and return stdout string (non-throwing)

    func runSilent(
        _ executable: URL,
        arguments: [String] = []
    ) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        do {
            let out = try await run(executable, arguments: arguments)
            return out.stdout.trimmed
        } catch {
            return nil
        }
    }
}

// MARK: - StreamingHandle

/// A handle returned by runStreaming — can be used to await completion or cancel.
/// Uses NSLock internally for thread safety; marked @unchecked Sendable.
final class StreamingHandle: @unchecked Sendable {

    // All mutable state is protected by `lock`
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var continuation: CheckedContinuation<ProcessOutput, Error>?
    nonisolated(unsafe) private var stdoutAccum = ""
    nonisolated(unsafe) private var stderrAccum = ""
    nonisolated(unsafe) private(set) var isRunning = false

    // MARK: - Public API

    nonisolated init() {}

    /// Await process completion. May only be called once.
    nonisolated func waitForCompletion() async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            self.continuation = cont
            lock.unlock()
        }
    }

    /// Terminate the underlying process.
    nonisolated func cancel() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }

    // MARK: - Internal: launch process

    nonisolated func startProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        let proc       = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL  = executable
        proc.arguments      = arguments
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe
        if let env = environment { proc.environment = env }

        // Stream stdout in real time (readabilityHandler runs on a background thread)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                self.lock.lock()
                self.stdoutAccum += text
                self.lock.unlock()
                onOutput(text)
            }
        }

        // Stream stderr in real time too — adb install writes [XX%] progress to stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                self.lock.lock()
                self.stderrAccum += text
                self.lock.unlock()
                onOutput(text)
            }
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }

            // Stop streaming handlers before draining to avoid double-reading
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Drain any final bytes not caught by the readability handler
            let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: remainingStdout, encoding: .utf8), !text.isEmpty {
                self.lock.lock(); self.stdoutAccum += text; self.lock.unlock()
            }
            if let text = String(data: remainingStderr, encoding: .utf8), !text.isEmpty {
                self.lock.lock(); self.stderrAccum += text; self.lock.unlock()
            }

            self.lock.lock()
            let stdout = self.stdoutAccum
            let stderr = self.stderrAccum
            let code   = p.terminationStatus
            let cont   = self.continuation
            self.continuation = nil
            self.isRunning    = false
            self.lock.unlock()

            guard let cont else { return }
            let output = ProcessOutput(exitCode: code, stdout: stdout, stderr: stderr)
            if code == 0 {
                cont.resume(returning: output)
            } else {
                cont.resume(throwing: ProcessError.processTerminated(exitCode: code, stderr: stderr))
            }
        }

        lock.lock()
        self.process  = proc
        self.isRunning = true
        lock.unlock()

        do {
            try proc.run()
        } catch {
            lock.lock()
            let cont = self.continuation
            self.continuation = nil
            self.isRunning    = false
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }
}
