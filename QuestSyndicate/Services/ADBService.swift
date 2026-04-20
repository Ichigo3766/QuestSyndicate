
//
//  ADBService.swift
//  QuestSyndicate
//
//  Wraps the bundled `adb` CLI binary via Foundation.Process
//

import Foundation

// MARK: - ADB Errors

enum ADBError: Error, LocalizedError {
    case notInitialized
    case deviceNotFound(String)
    case installFailed(String)
    case commandFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:          return "ADB service not initialized"
        case .deviceNotFound(let s):   return "Device not found: \(s)"
        case .installFailed(let msg):  return "Install failed: \(msg)"
        case .commandFailed(let msg):  return "ADB command failed: \(msg)"
        case .exportFailed(let msg):   return "Export failed: \(msg)"
        }
    }
}

// MARK: - Device Event

enum DeviceEvent {
    case added(DeviceInfo)
    case removed(String)   // serial
    case changed(DeviceInfo)
    case error(String)
}

// MARK: - ADBService

actor ADBService {

    private let runner = ProcessRunner()
    private var adbPath: URL
    private var trackingTask: Task<Void, Never>?
    private var deviceEventContinuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
    private var aaptPushed = false
    /// Tracks how many consecutive reconnect attempts have been made for each WiFi serial.
    private var wifiReconnectAttempts: [String: Int] = [:]
    /// Max number of silent reconnect attempts before we broadcast the offline state.
    /// Set to 0 so the UI goes offline immediately on first detection — reconnect still
    /// happens silently in the background (see pollDevices).
    private let maxWifiReconnectAttempts = 0
    /// Tracks recently intentionally-connected WiFi serials with the timestamp of connection.
    /// Used to give the poller a grace period so it does NOT tear down a freshly-established
    /// connection with the stale-socket disconnect/reconnect check.
    private var recentlyConnectedSerials: [String: Date] = [:]
    /// How long (in seconds) a freshly-connected serial is exempt from the stale-socket check.
    private let recentConnectionGracePeriod: TimeInterval = 15

    init() {
        self.adbPath = Constants.adbPath
    }

    // MARK: - Binary path update

    func updateADBPath(_ url: URL) {
        self.adbPath = url
        self.aaptPushed = false
    }

    // MARK: - ADB helper

    private func adb(_ args: String...) async throws -> String {
        let out = try await runner.run(adbPath, arguments: Array(args))
        return out.stdout.trimmed
    }

    private func adbSilent(_ args: String...) async -> String {
        return await runner.runSilent(adbPath, arguments: Array(args)) ?? ""
    }

    // MARK: - List Devices

    func listDevices() async throws -> [DeviceInfo] {
        let output = try await adb("devices", "-l")
        return parseDevicesOutput(output)
    }

    private func parseDevicesOutput(_ output: String) -> [DeviceInfo] {
        var devices: [DeviceInfo] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines.dropFirst() {  // skip "List of devices attached"
            let trimmed = line.trimmed
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let typeStr = parts[1]
            let type: DeviceType
            switch typeStr {
            case "device":       type = .device
            case "emulator":     type = .emulator
            case "offline":      type = .offline
            case "unauthorized": type = .unauthorized
            default:             type = .unknown
            }
            devices.append(DeviceInfo(
                id: serial, type: type, model: nil, isQuestDevice: false,
                batteryLevel: nil, storageTotal: nil, storageFree: nil,
                friendlyModelName: nil, ipAddress: nil
            ))
        }
        return devices
    }

    // MARK: - Device Details

    func getDeviceDetails(serial: String) async -> DeviceInfo {
        // For WiFi serials (contain ":"), retry once if the first attempt returns
        // empty data — the ADB daemon may not be fully ready immediately after connect.
        let maxAttempts = serial.contains(":") ? 2 : 1
        var mfr = ""
        var code = ""
        var ip = ""
        var bat = ""
        var stor = ""

        for attempt in 1...maxAttempts {
            async let manufacturer = shellSilent(serial, "getprop ro.product.manufacturer")
            async let codename     = shellSilent(serial, "getprop ro.product.device")
            async let ipRoute      = shellSilent(serial, "ip route")
            async let battery      = shellSilent(serial, "dumpsys battery | grep level")
            async let storage      = shellSilent(serial, "df -h /data")

            mfr  = await manufacturer.lowercased()
            code = await codename.lowercased()
            ip   = await ipRoute
            bat  = await battery
            stor = await storage

            // If we got meaningful data, stop retrying
            if !mfr.isEmpty || !code.isEmpty || bat.contains("level") {
                break
            }

            // First attempt returned empty — wait and retry
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            }
        }

        let isQuest = (mfr == "oculus") && Constants.questModels.contains(code)
        let model = QuestModel.from(codename: code)
        let friendlyName: String
        if isQuest, let qm = model {
            friendlyName = qm.friendlyName
        } else if !mfr.isEmpty || !code.isEmpty {
            friendlyName = "\(mfr.capitalized) \(code)".trimmed
        } else {
            friendlyName = serial
        }

        // Parse IP from "src 192.168.1.x"
        var ipAddress: String?
        if let range = ip.range(of: #"src\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) {
            let match = String(ip[range])
            ipAddress = match.components(separatedBy: .whitespaces).last
        }

        // Parse battery
        var batteryLevel: Int?
        if let range = bat.range(of: #"level:\s*(\d+)"#, options: .regularExpression) {
            let s = String(bat[range]).components(separatedBy: .whitespaces).last ?? ""
            batteryLevel = Int(s)
        }

        // Parse storage  "Filesystem Size Used Avail Use% Mounted"
        var storageTotal: String?
        var storageFree: String?
        let storLines = stor.components(separatedBy: "\n")
        if storLines.count > 1 {
            let parts = storLines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 4 {
                storageTotal = parts[1]
                storageFree  = parts[3]
            }
        }

        return DeviceInfo(
            id: serial, type: .device, model: code.isEmpty ? nil : code,
            isQuestDevice: isQuest, batteryLevel: batteryLevel,
            storageTotal: storageTotal, storageFree: storageFree,
            friendlyModelName: friendlyName, ipAddress: ipAddress
        )
    }

    // MARK: - Track Devices (polling-based AsyncStream)

    func trackDevices() -> AsyncStream<DeviceEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.deviceEventContinuations[id] = continuation
            continuation.onTermination = { [id] _ in
                Task { await self.removeDeviceEventContinuation(id: id) }
            }
            // Start polling if not already running
            if self.trackingTask == nil {
                self.trackingTask = Task { await self.pollDevices() }
            }
        }
    }

    private func removeDeviceEventContinuation(id: UUID) {
        deviceEventContinuations.removeValue(forKey: id)
        if deviceEventContinuations.isEmpty {
            trackingTask?.cancel()
            trackingTask = nil
        }
    }

    private func broadcast(_ event: DeviceEvent) {
        for cont in deviceEventContinuations.values {
            cont.yield(event)
        }
    }

    private func pollDevices() async {
        var knownDevices: [String: DeviceInfo] = [:]
        while !Task.isCancelled {
            do {
                let current = try await listDevices()
                let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

                // Added devices
                for (serial, device) in currentMap where knownDevices[serial] == nil {
                    if device.type == .device || device.type == .emulator {
                        // WiFi ADB connections (serial contains ":") need a stabilization
                        // delay — the TCP connection is accepted but the ADB daemon on the
                        // device may not be ready to answer shell commands yet.
                        if serial.contains(":") {
                            // Skip the stale-socket check if this serial was just intentionally
                            // connected (by connectTcp or enableWifiADB) within the grace period.
                            // Tearing it down immediately would race against the fresh connection.
                            let isRecent: Bool = {
                                guard let ts = recentlyConnectedSerials[serial] else { return false }
                                return Date().timeIntervalSince(ts) < recentConnectionGracePeriod
                            }()

                            if !isRecent {
                                // At startup ADB may have a stale cached TCP connection from a
                                // previous session. The kernel TCP socket can remain in ESTABLISHED
                                // state for minutes until keepalive fires, so ADB reports the serial
                                // as "device" even though the headset is off.
                                //
                                // Fix: force-disconnect first, then fresh `adb connect`.
                                _ = await adbSilent("disconnect", serial)
                                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s — let socket close

                                _ = await adbSilent("connect", serial)
                                try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s — daemon stabilise

                                // Verify the fresh connection is actually responsive.
                                let check = await shellSilent(serial, "echo ok")
                                if !check.contains("ok") {
                                    // Still not reachable — clean up and skip entirely.
                                    _ = await adbSilent("disconnect", serial)
                                    continue
                                }
                            }
                            // Expire old grace-period entries to avoid unbounded growth.
                            recentlyConnectedSerials = recentlyConnectedSerials.filter {
                                Date().timeIntervalSince($0.value) < recentConnectionGracePeriod
                            }
                        }
                        let detailed = await getDeviceDetails(serial: serial)
                        knownDevices[serial] = detailed
                        broadcast(.added(detailed))
                    } else {
                        knownDevices[serial] = device
                        broadcast(.added(device))
                    }
                }

                // Active health check for connected WiFi devices.
                // ADB's TCP keepalive can take 5-30s to detect a dead connection, making
                // the UI lag badly when a headset is powered off mid-session. We probe
                // each known-online WiFi device with a quick shell round-trip on every
                // poll cycle. If it fails, we immediately force-disconnect and broadcast
                // offline — bypassing ADB's slow keepalive entirely.
                for (serial, knownDevice) in knownDevices
                    where serial.contains(":") && (knownDevice.type == .device || knownDevice.type == .emulator) {
                    // Only probe if ADB still considers it online (skip if it's already
                    // been caught by the "Changed" section in this same iteration).
                    let stillOnline = currentMap[serial].map { $0.type == .device || $0.type == .emulator } ?? false
                    guard stillOnline else { continue }

                    let probe = await shellSilent(serial, "echo ok")
                    if !probe.contains("ok") {
                        // Device stopped responding — tear down the connection so ADB
                        // removes it from its device list on the next poll.
                        _ = await adbSilent("disconnect", serial)
                        knownDevices.removeValue(forKey: serial)
                        broadcast(.removed(serial))
                    }
                }

                // Removed devices
                for serial in knownDevices.keys where currentMap[serial] == nil {
                    knownDevices.removeValue(forKey: serial)
                    broadcast(.removed(serial))
                }

                // Changed devices (type changed e.g., offline → device)
                for (serial, newDevice) in currentMap {
                    if let old = knownDevices[serial], old.type != newDevice.type {
                        if newDevice.type == .offline && serial.contains(":") {
                            // WiFi device went offline. Try to reconnect silently up to
                            // maxWifiReconnectAttempts times. After that, broadcast the
                            // offline state so the UI updates immediately.
                            let attempts = (wifiReconnectAttempts[serial] ?? 0) + 1
                            wifiReconnectAttempts[serial] = attempts

                            if attempts <= maxWifiReconnectAttempts {
                                // Still within retry budget — attempt silent reconnect,
                                // do NOT update knownDevices so UI stays stable during transient drops.
                                _ = await adbSilent("connect", serial)
                            } else {
                                // Retry budget exhausted — the device is genuinely offline.
                                // Update stored state and broadcast so the UI goes offline immediately.
                                knownDevices[serial] = newDevice
                                wifiReconnectAttempts[serial] = 0
                                broadcast(.changed(newDevice))
                            }
                        } else if newDevice.type == .device || newDevice.type == .emulator {
                            // Device recovered — reset retry counter, enrich with fresh details.
                            wifiReconnectAttempts[serial] = 0
                            let detailed = await getDeviceDetails(serial: serial)
                            knownDevices[serial] = detailed
                            broadcast(.changed(detailed))
                        } else {
                            knownDevices[serial] = newDevice
                            broadcast(.changed(newDevice))
                        }
                    }
                }
            } catch {
                broadcast(.error(error.localizedDescription))
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 second poll
        }
    }

    // MARK: - Shell Command

    func shell(_ serial: String, _ command: String) async throws -> String {
        let out = try await runner.run(adbPath, arguments: ["-s", serial, "shell", command])
        return out.stdout.trimmed
    }

    // MARK: - Raw ADB Command (for Terminal)

    /// Runs any ADB command with arbitrary args and returns combined stdout+stderr.
    /// Pass `serial` to auto-prepend `-s <serial>`, or pass nil for global commands.
    /// Always returns a non-empty string suitable for display in the terminal.
    func runADB(serial: String?, args: [String]) async -> String {
        var fullArgs: [String] = []
        if let serial = serial {
            fullArgs += ["-s", serial]
        }
        fullArgs += args
        return await runCombined(adbPath, arguments: fullArgs)
    }

    /// Runs `adb -s <serial> shell <command>` and returns combined output (non-throwing).
    func runShell(serial: String, command: String) async -> String {
        return await runCombined(adbPath, arguments: ["-s", serial, "shell", command])
    }

    /// Internal helper: runs a process and returns stdout+stderr combined, never throws.
    private func runCombined(_ executable: URL, arguments: [String]) async -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "Error: executable not found at \(executable.path)"
        }
        return await withCheckedContinuation { continuation in
            let process    = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL  = executable
            process.arguments      = arguments
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            process.terminationHandler = { _ in
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [out.trimmingCharacters(in: .whitespacesAndNewlines),
                                err.trimmingCharacters(in: .whitespacesAndNewlines)]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                continuation.resume(returning: combined.isEmpty ? "(no output)" : combined)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func shellSilent(_ serial: String, _ command: String) async -> String {
        return await runner.runSilent(adbPath, arguments: ["-s", serial, "shell", command]) ?? ""
    }

    // MARK: - Enable WiFi ADB

    /// Switches a USB-connected device to TCP/IP mode and immediately connects wirelessly.
    /// Steps: tcpip 5555 → get IP → adb connect <ip>:5555
    /// - Returns: The IP address that was connected to (e.g. "192.168.1.42")
    /// - Throws: ADBError.commandFailed if any step fails
    func enableWifiADB(serial: String) async throws -> String {
        // Step 1: Switch to TCP/IP mode on port 5555
        let tcpipResult = await runCombined(adbPath, arguments: ["-s", serial, "tcpip", "5555"])
        guard tcpipResult.contains("restarting") || tcpipResult.contains("5555") else {
            throw ADBError.commandFailed("tcpip switch failed: \(tcpipResult)")
        }

        // Brief pause to let the device restart its ADB daemon in TCP mode
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        // Step 2: Get the device's WiFi IP
        guard let ip = await getDeviceIP(serial: serial), !ip.isEmpty else {
            throw ADBError.commandFailed("Could not determine device IP address. Make sure the device is connected to WiFi.")
        }

        // Step 3: Connect wirelessly
        let connectResult = await runCombined(adbPath, arguments: ["connect", "\(ip):5555"])
        guard connectResult.contains("connected") else {
            throw ADBError.commandFailed("adb connect failed: \(connectResult)")
        }

        // Record this serial so the poller won't immediately tear it down with the
        // stale-socket check during the grace period.
        let wifiSerial = "\(ip):5555"
        recentlyConnectedSerials[wifiSerial] = Date()

        return ip
    }

    // MARK: - TCP Connect / Disconnect

    func connectTcp(ip: String, port: Int = 5555) async throws -> Bool {
        let serial = "\(ip):\(port)"
        let result = await adbSilent("connect", serial)
        guard result.contains("connected") else { return false }

        // The ADB daemon needs time to restart in TCP mode before it can answer
        // shell commands. Without this delay "echo ok" races the daemon startup
        // and consistently fails, making the connection appear broken.
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s stabilization

        // Verify the device is truly responsive — retry up to 3 times to handle
        // the window where the daemon is still initialising.
        var verified = false
        for _ in 0..<3 {
            let check = await shellSilent(serial, "echo ok")
            if check.contains("ok") {
                verified = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s between retries
        }
        guard verified else {
            _ = await adbSilent("disconnect", serial)
            return false
        }

        // Record this serial so the poller won't immediately tear it down with the
        // stale-socket check during the grace period.
        recentlyConnectedSerials[serial] = Date()
        return true
    }

    func disconnectTcp(ip: String, port: Int = 5555) async throws -> Bool {
        let result = await adbSilent("disconnect", "\(ip):\(port)")
        return result.contains("disconnected")
    }

    // MARK: - Installed Packages

    func getInstalledPackages(serial: String) async throws -> [PackageInfo] {
        let output = try await shell(serial, "pm list packages --show-versioncode -3")
        return output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("package:") }
            .compactMap { line -> PackageInfo? in
                guard let pkgMatch = line.range(of: #"package:(\S+)"#, options: .regularExpression) else { return nil }
                let pkg = String(line[pkgMatch]).replacingOccurrences(of: "package:", with: "")
                let ver: Int
                if let verMatch = line.range(of: #"versionCode:(\d+)"#, options: .regularExpression) {
                    ver = Int(String(line[verMatch]).replacingOccurrences(of: "versionCode:", with: "")) ?? 0
                } else {
                    ver = 0
                }
                return PackageInfo(packageName: pkg.trimmed, versionCode: ver)
            }
    }

    /// Returns count of third-party packages installed on the device.
    func getInstalledPackageCount(serial: String) async -> Int {
        let output = await shellSilent(serial, "pm list packages -3")
        return output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("package:") }
            .count
    }

    // MARK: - Install APK

    /// Installs an APK using `adb install` — works for USB and WiFi connections.
    /// Streams real-time progress via `onProgress` (0–100). Lines from adb contain `[XX%]`.
    /// For WiFi serials (ip:port), refreshes the ADB TCP connection first to prevent
    /// "connect failed: closed" errors during large file transfers.
    func install(
        serial: String,
        apkPath: URL,
        flags: [String] = ["-r", "-g", "-d"],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        // For WiFi devices, refresh the TCP connection so the daemon is ready.
        if serial.contains(":") {
            _ = await adbSilent("connect", serial)
        }

        // `adb install` streams the APK over the ADB protocol directly — no temp file needed,
        // and it's reliable over both USB and WiFi.
        let args = ["-s", serial, "install"] + flags + [apkPath.path]

        // Use streaming so we can parse real-time [XX%] progress from adb's output.
        // The streaming callback accumulates output; we also capture it after completion.
        let handle = runner.runStreaming(adbPath, arguments: args) { line in
            // adb prints lines like: "Performing Streamed Install\n[10%] 1.2 MB/s …\n[100%] …\nSuccess"
            // Parse percentage tokens of the form [XX%]
            if let onProgress {
                let pattern = #"\[(\d{1,3})%\]"#
                if let range = line.range(of: pattern, options: .regularExpression) {
                    let token = String(line[range])          // e.g. "[42%]"
                    let digits = token.filter { $0.isNumber }
                    if let pct = Double(digits) {
                        onProgress(min(pct, 100))
                    }
                }
            }
        }

        // `waitForCompletion()` throws ProcessError.processTerminated when exit code ≠ 0.
        // However the actual adb failure message (INSTALL_FAILED_*, etc.) is written to
        // stdout/stderr BEFORE the process exits, so the streaming handler has already
        // accumulated it. We need to capture that output even on failure.
        let combinedOutput: String
        do {
            let output = try await handle.waitForCompletion()
            combinedOutput = (output.stdout + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Process exited non-zero — but the streaming callbacks already captured the
            // full output in stdoutAccum/stderrAccum. Re-read it from the error if possible,
            // otherwise reconstruct from what we know.
            // ProcessError.processTerminated carries stderr; stdout was streamed live.
            let stderrMsg: String
            if let pe = error as? ProcessError,
               case ProcessError.processTerminated(_, let stderr) = pe {
                stderrMsg = stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            } else {
                stderrMsg = error.localizedDescription
            }
            // Run a quick synchronous check — if stderr itself contains the result, use it.
            // Otherwise fall through to throw with the best message we have.
            combinedOutput = stderrMsg
        }

        if combinedOutput.contains("Success") { return true }

        // Handle INSTALL_FAILED_UPDATE_INCOMPATIBLE — signature mismatch between installed and
        // new APK (different keystore). We MUST uninstall first, but we preserve game data by:
        //   1. Pulling /sdcard/Android/data/<pkg> and /sdcard/Android/obb/<pkg> to a temp dir
        //   2. Uninstalling (APK only — not deleting sdcard data)
        //   3. Installing the new APK
        //   4. Pushing the backed-up data/obb back
        //   5. Cleaning up the temp dir
        // The error text is: "Existing package <pkg> signatures do not match"
        if combinedOutput.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE"),
           let pkgMatch = combinedOutput.range(of: #"(?i)package\s+(\S+)\s+signatures"#, options: .regularExpression) {
            // Extract the package name from between "package " and " signatures"
            let fullMatch = String(combinedOutput[pkgMatch])
            let parts = fullMatch.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let pkg = parts.count >= 2 ? parts[1] : fullMatch

            // Temp backup directory on the Mac
            let backupDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuestSyndicate_backup_\(pkg)_\(Int(Date().timeIntervalSince1970))")
            let backupDataDir = backupDir.appendingPathComponent("data")
            let backupObbDir  = backupDir.appendingPathComponent("obb")
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

            // 1. Backup /sdcard/Android/data/<pkg> if it exists
            let hasData = await shellSilent(serial, "[ -d /sdcard/Android/data/\(pkg) ] && echo yes") == "yes"
            if hasData {
                try? FileManager.default.createDirectory(at: backupDataDir, withIntermediateDirectories: true)
                _ = try? await runner.run(adbPath, arguments: ["-s", serial, "pull",
                    "/sdcard/Android/data/\(pkg)", backupDataDir.path])
            }

            // 2. Backup /sdcard/Android/obb/<pkg> if it exists
            let hasObb = await shellSilent(serial, "[ -d /sdcard/Android/obb/\(pkg) ] && echo yes") == "yes"
            if hasObb {
                try? FileManager.default.createDirectory(at: backupObbDir, withIntermediateDirectories: true)
                _ = try? await runner.run(adbPath, arguments: ["-s", serial, "pull",
                    "/sdcard/Android/obb/\(pkg)", backupObbDir.path])
            }

            // 3. Uninstall APK only (do NOT remove sdcard data — we already have a backup,
            //    and removing it now is redundant since we'll overwrite it after reinstall)
            _ = try? await shell(serial, "pm uninstall \(pkg)")

            // 4. Install the new APK
            let retryHandle = runner.runStreaming(adbPath, arguments: args) { line in
                if let onProgress {
                    let pattern = #"\[(\d{1,3})%\]"#
                    if let range = line.range(of: pattern, options: .regularExpression) {
                        let token = String(line[range])
                        let digits = token.filter { $0.isNumber }
                        if let pct = Double(digits) { onProgress(min(pct, 100)) }
                    }
                }
            }
            let retryOutput: String
            do {
                let retryResult = try await retryHandle.waitForCompletion()
                retryOutput = (retryResult.stdout + retryResult.stderr).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            } catch {
                if let pe = error as? ProcessError,
                   case ProcessError.processTerminated(_, let stderr) = pe {
                    retryOutput = stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                } else {
                    retryOutput = error.localizedDescription
                }
            }

            // 5. Restore backed-up data (regardless of install success — don't leave user without saves)
            if hasData {
                let pulledDataDir = backupDataDir.appendingPathComponent(pkg)
                let srcPath = FileManager.default.fileExists(atPath: pulledDataDir.path)
                    ? pulledDataDir.path : backupDataDir.path
                _ = try? await runner.run(adbPath, arguments: ["-s", serial, "push",
                    srcPath, "/sdcard/Android/data/\(pkg)"])
            }
            if hasObb {
                let pulledObbDir = backupObbDir.appendingPathComponent(pkg)
                let srcPath = FileManager.default.fileExists(atPath: pulledObbDir.path)
                    ? pulledObbDir.path : backupObbDir.path
                _ = try? await runner.run(adbPath, arguments: ["-s", serial, "push",
                    srcPath, "/sdcard/Android/obb/\(pkg)"])
            }

            // 6. Clean up temp backup
            try? FileManager.default.removeItem(at: backupDir)

            if retryOutput.contains("Success") { return true }
            throw ADBError.installFailed(retryOutput)
        }

        throw ADBError.installFailed(combinedOutput)
    }

    // MARK: - Uninstall

    func uninstall(serial: String, packageName: String) async throws -> Bool {
        _ = try? await shell(serial, "pm uninstall \(packageName)")
        _ = try? await shell(serial, "rm -r /sdcard/Android/obb/\(packageName)")
        _ = try? await shell(serial, "rm -r /sdcard/Android/data/\(packageName)")
        return true
    }

    // MARK: - Push

    func push(serial: String, localPath: URL, remotePath: String) async throws -> Bool {
        _ = try await runner.run(adbPath, arguments: ["-s", serial, "push", localPath.path, remotePath])
        return true
    }

    // MARK: - Pull

    func pull(serial: String, remotePath: String, localPath: URL) async throws -> Bool {
        _ = try await runner.run(adbPath, arguments: ["-s", serial, "pull", remotePath, localPath.path])
        return true
    }

    // MARK: - Get APK Path on Device

    /// Returns the on-device path to a package's APK, e.g. `/data/app/com.example/.../base.apk`.
    func getApkPath(serial: String, packageName: String) async -> String? {
        let output = await shellSilent(serial, "pm path \(packageName)")
        // Output format: "package:/data/app/com.example/base.apk"
        let trimmed = output.trimmed
        guard trimmed.hasPrefix("package:") else { return nil }
        return String(trimmed.dropFirst("package:".count)).trimmed
    }

    // MARK: - Export Game (APK + OBB)

    /// Pulls the APK and OBB folder for a package to the destination folder.
    /// Returns an array of local URLs for all exported files.
    func exportGame(
        serial: String,
        packageName: String,
        destinationFolder: URL,
        includeObb: Bool = true
    ) async throws -> [URL] {
        var exportedFiles: [URL] = []

        // 1. Get the on-device APK path
        guard let apkDevicePath = await getApkPath(serial: serial, packageName: packageName) else {
            throw ADBError.exportFailed("Could not locate APK for \(packageName) on device")
        }

        // 2. Pull the APK
        let apkFileName = "\(packageName).apk"
        let apkDestination = destinationFolder.appendingPathComponent(apkFileName)
        do {
            _ = try await runner.run(
                adbPath,
                arguments: ["-s", serial, "pull", apkDevicePath, apkDestination.path]
            )
            exportedFiles.append(apkDestination)
        } catch {
            throw ADBError.exportFailed("Failed to pull APK: \(error.localizedDescription)")
        }

        // 3. Pull the OBB folder (optional — non-fatal if missing)
        if includeObb {
            let obbRemotePath = "/sdcard/Android/obb/\(packageName)"
            let obbDestination = destinationFolder.appendingPathComponent("obb_\(packageName)")
            // Only pull if the directory actually exists on device
            let checkObb = await shellSilent(serial, "[ -d \"\(obbRemotePath)\" ] && echo exists")
            if checkObb.contains("exists") {
                do {
                    _ = try await runner.run(
                        adbPath,
                        arguments: ["-s", serial, "pull", obbRemotePath, obbDestination.path]
                    )
                    exportedFiles.append(obbDestination)
                } catch {
                    // OBB pull failure is non-fatal — log and continue
                    print("[ADBService] OBB pull failed for \(packageName): \(error.localizedDescription)")
                }
            }
        }

        return exportedFiles
    }

    // MARK: - Get Device IP

    func getDeviceIP(serial: String) async -> String? {
        let output = await shellSilent(serial, "ip route")
        guard let range = output.range(of: #"src\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range]).components(separatedBy: .whitespaces).last
    }

    // MARK: - Get/Set Username

    func getUserName(serial: String) async -> String {
        let name = await shellSilent(serial, "settings get global username").trimmed
        return (name.isEmpty || name == "null") ? "[Unset]" : name
    }

    func setUserName(serial: String, name: String) async throws {
        _ = try await shell(serial, "settings put global username \"\(name.trimmed)\"")
    }

    // MARK: - Ping

    func pingDevice(ip: String) async -> (reachable: Bool, responseTime: Int?) {
        let result = await runner.runSilent(
            URL(fileURLWithPath: "/sbin/ping"),
            arguments: ["-c", "1", "-W", "3", ip]
        ) ?? ""
        if result.contains("1 packets received") || result.contains("1 received") {
            if let range = result.range(of: #"time=(\d+\.?\d*)"#, options: .regularExpression) {
                let t = Double(String(result[range]).replacingOccurrences(of: "time=", with: "")) ?? 0
                return (true, Int(t))
            }
            return (true, nil)
        }
        return (false, nil)
    }

}
