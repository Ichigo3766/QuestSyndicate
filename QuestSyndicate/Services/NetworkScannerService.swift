//
//  NetworkScannerService.swift
//  QuestSyndicate
//
//  Scans the local subnet for ADB-enabled Quest devices by probing TCP port 5555.
//

import Foundation
import Network
import Observation

// MARK: - Discovered Device

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    var id: String { "\(ipAddress):\(port)" }
    var ipAddress: String
    var port: Int = 5555
    var pingMs: Int?
    var isReachable: Bool = false
    var isConnecting: Bool = false
    var isConnected: Bool = false
    var friendlyName: String?

    nonisolated var serial: String { "\(ipAddress):\(port)" }

    nonisolated var statusLabel: String {
        if isConnected { return "Connected" }
        if isConnecting { return "Connecting…" }
        if let ms = pingMs { return "Online (\(ms)ms)" }
        return "Online"
    }
}

// MARK: - NetworkScannerService

@Observable
@MainActor
final class NetworkScannerService {

    // MARK: - Published State
    var discoveredDevices: [DiscoveredDevice] = []
    var isScanning: Bool = false
    var lastScanDate: Date? = nil
    var scanError: String? = nil

    // MARK: - Private
    private var scanTask: Task<Void, Never>? = nil

    // MARK: - Scan

    /// Starts a new subnet scan. Cancels any previous scan first.
    func scan() {
        scanTask?.cancel()
        discoveredDevices = []
        isScanning = true
        scanError = nil

        scanTask = Task { [weak self] in
            await self?.performScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Core Scan Logic

    private func performScan() async {
        // 1. Get the local subnet prefix (e.g. "192.168.1")
        guard let subnetPrefix = await Self.localSubnetPrefix() else {
            scanError = "Could not determine local subnet"
            isScanning = false
            return
        }

        // 2. Probe all 254 addresses concurrently in batches
        var found: [DiscoveredDevice] = []
        let addresses = (1...254).map { "\(subnetPrefix).\($0)" }

        await withTaskGroup(of: DiscoveredDevice?.self) { group in
            // Limit concurrency: launch in batches of 50
            var index = 0
            let batchSize = 50

            func launchNext() {
                while index < addresses.count && group.isEmpty == false || index < min(batchSize, addresses.count) {
                    guard index < addresses.count else { return }
                    let ip = addresses[index]
                    index += 1
                    group.addTask {
                        return await Self.probeDevice(ip: ip, port: 5555)
                    }
                }
            }

            // Initial batch
            for i in 0..<min(batchSize, addresses.count) {
                let ip = addresses[i]
                index = i + 1
                group.addTask {
                    return await Self.probeDevice(ip: ip, port: 5555)
                }
            }

            // Process results and launch more as slots open
            for await result in group {
                if Task.isCancelled { break }

                if let device = result {
                    found.append(device)
                    let snapshot = found.sorted { ($0.pingMs ?? 9999) < ($1.pingMs ?? 9999) }
                    await MainActor.run { [weak self] in
                        self?.discoveredDevices = snapshot
                    }
                }

                // Launch next IP if available
                if index < addresses.count {
                    let ip = addresses[index]
                    index += 1
                    group.addTask {
                        return await Self.probeDevice(ip: ip, port: 5555)
                    }
                }
            }
        }

        await MainActor.run { [weak self] in
            self?.isScanning = false
            self?.lastScanDate = Date()
            let sorted = found.sorted { ($0.pingMs ?? 9999) < ($1.pingMs ?? 9999) }
            self?.discoveredDevices = sorted
        }
    }

    // MARK: - TCP Port Probe

    /// Attempts a TCP connect to ip:port with a 700ms timeout.
    /// Returns a DiscoveredDevice if the port is open (ADB listener found), nil otherwise.
    private static func probeDevice(ip: String, port: Int) async -> DiscoveredDevice? {
        let start = Date()
        let open = await tcpPortOpen(host: ip, port: UInt16(port), timeoutSeconds: 0.7)
        guard open else { return nil }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return DiscoveredDevice(
            ipAddress: ip,
            port: port,
            pingMs: ms,
            isReachable: true
        )
    }

    /// Non-blocking TCP connect check using NWConnection.
    private static func tcpPortOpen(host: String, port: UInt16, timeoutSeconds: Double) async -> Bool {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port),
                using: .tcp
            )

            // Use a class-based flag so it can be safely mutated from concurrent closures
            // without triggering Swift 6 "mutation of captured var in concurrently-executing code".
            final class ResumeFlag: @unchecked Sendable {
                private let lock = NSLock()
                private var _didResume = false
                var didResume: Bool {
                    lock.withLock { _didResume }
                }
                /// Atomically sets the flag and returns whether this call was the first to do so.
                func tryResume() -> Bool {
                    lock.withLock {
                        guard !_didResume else { return false }
                        _didResume = true
                        return true
                    }
                }
            }
            let flag = ResumeFlag()

            let timeoutWork = DispatchWorkItem {
                if flag.tryResume() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutWork.cancel()
                    if flag.tryResume() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    timeoutWork.cancel()
                    if flag.tryResume() {
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }

    // MARK: - Local Subnet Detection

    /// Returns the first 3 octets of the Mac's primary non-loopback IPv4 address.
    /// e.g. "192.168.1" for 192.168.1.5
    static func localSubnetPrefix() async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var ifaddr: UnsafeMutablePointer<ifaddrs>?
                guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeifaddrs(ifaddr) }

                var result: String? = nil
                var ptr = firstAddr
                while true {
                    let flags = Int32(ptr.pointee.ifa_flags)
                    let family = ptr.pointee.ifa_addr.pointee.sa_family

                    // IPv4 only, skip loopback
                    if family == UInt8(AF_INET),
                       (flags & IFF_LOOPBACK) == 0,
                       (flags & IFF_UP) != 0 {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                      &hostname, socklen_t(hostname.count),
                                      nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            // Skip 169.254.x.x (link-local)
                            if !ip.hasPrefix("169.254") {
                                let parts = ip.components(separatedBy: ".")
                                if parts.count == 4 {
                                    result = parts.prefix(3).joined(separator: ".")
                                    break
                                }
                            }
                        }
                    }

                    if let next = ptr.pointee.ifa_next {
                        ptr = next
                    } else {
                        break
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Update Connected State

    /// Marks discovered devices as connected/disconnected based on current connectedDevices serials.
    func syncConnectedState(connectedSerials: Set<String>) {
        for i in discoveredDevices.indices {
            discoveredDevices[i].isConnected = connectedSerials.contains(discoveredDevices[i].serial)
        }
    }

    func markConnecting(ip: String, port: Int, isConnecting: Bool) {
        let serial = "\(ip):\(port)"
        if let i = discoveredDevices.firstIndex(where: { $0.id == serial }) {
            discoveredDevices[i].isConnecting = isConnecting
            if !isConnecting {
                // Re-sync connected state will be done by caller
            }
        }
    }
}
