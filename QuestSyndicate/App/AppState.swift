import SwiftUI
import Observation

// MARK: - SidebarDevice

/// A merged device entry used exclusively for sidebar display.
/// Combines live ADB-connected devices with saved WiFi bookmarks.
struct SidebarDevice: Identifiable, Equatable {
    /// Primary identifier — USB serial when available, otherwise WiFi serial.
    let id: String
    /// Non-nil when the device is currently connected via ADB.
    let device: DeviceInfo?
    /// Non-nil when this device exists as a saved WiFi bookmark.
    let bookmark: WiFiBookmark?
    /// Which physical connection types are active (or were used historically).
    let connectionTypes: Set<ConnectionType>

    enum ConnectionType: Hashable { case usb, wifi }

    /// True when the device is fully connected and responsive (not just in ADB's device list as offline/unauthorized).
    var isOnline: Bool { device?.type == .device || device?.type == .emulator }

    /// Best display name available.
    var displayName: String {
        device?.displayName
            ?? bookmark?.displayLabel
            ?? id
    }

    static func == (lhs: SidebarDevice, rhs: SidebarDevice) -> Bool {
        lhs.id == rhs.id
            && lhs.device == rhs.device
            && lhs.bookmark == rhs.bookmark
            && lhs.connectionTypes == rhs.connectionTypes
    }
}

// MARK: - Export Progress

struct ExportProgress: Identifiable {
    var id = UUID()
    var packageName: String
    var gameName: String
    var isComplete: Bool = false
    var error: String? = nil
    var exportedFiles: [URL] = []
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    // MARK: - Core Services (actors)
    let adb: ADBService
    let rclone: RcloneService
    let extraction: ExtractionService
    let installation: InstallationService
    let dependencies: DependencyManager

    // MARK: - Observable Services
    let pipeline: DownloadPipeline
    let uploads: UploadService
    let mirrors: MirrorService
    let updater: UpdateService

    // MARK: - Game Library ViewModel (bridges actor → @Observable)
    let gameLibrary: GameLibraryViewModel

    // MARK: - Device State
    var connectedDevices: [DeviceInfo] = [] {
        didSet { rebuildSidebarDevices() }
    }
    var selectedDevice: DeviceInfo? = nil
    private var isTrackingDevices = false
    /// Maps USB serial → WiFi IP for devices where "Enable Wireless" has been activated.
    /// This lets sidebarDevices show dual USB+WiFi badges immediately, before the WiFi
    /// serial appears in connectedDevices, and drives the USB→WiFi transition on unplug.
    var wifiEnabledIPs: [String: String] = [:] {
        didSet { rebuildSidebarDevices() }
    }

    // MARK: - P0-1: Cached WiFi bookmarks (eliminates synchronous disk I/O per frame)
    /// In-memory cache of `wifi-bookmarks.json`. Loaded once at startup, kept in sync
    /// with every write. `sidebarDevices` reads from here — never from disk.
    private var cachedBookmarks: [WiFiBookmark] = [] {
        didSet { rebuildSidebarDevices() }
    }

    // MARK: - Cached Sidebar Devices
    /// Pre-computed sidebar device list. Rebuilt only when `connectedDevices`,
    /// `cachedBookmarks`, or `wifiEnabledIPs` change — not on every render tick.
    private(set) var sidebarDevices: [SidebarDevice] = []

    // MARK: - Installed App State
    /// Count of third-party packages on the selected device (used in DeviceCardView).
    var installedPackageCount: Int = 0
    /// Games that are installed on the device but NOT present in the VRP library.
    var deviceOnlyGames: [GameInfo] = []

    // MARK: - Export State
    /// Non-nil while an export is in progress or just completed (shown as overlay).
    var exportProgress: ExportProgress? = nil

    // MARK: - Navigation
    var selectedTab: AppTab = .library
    var showSettings = false

    // MARK: - Alerts
    var alertMessage: String? = nil
    var showAlert = false

    // MARK: - Init

    init() {
        let rclone = RcloneService()
        let extraction = ExtractionService()
        let adb = ADBService()

        self.rclone = rclone
        self.extraction = extraction
        self.adb = adb
        let installation = InstallationService(adb: adb)
        self.installation = installation
        self.dependencies = DependencyManager()

        self.pipeline = DownloadPipeline(
            rclone: rclone,
            extraction: extraction,
            installation: installation   // reuse the same instance — no duplicate state
        )
        self.uploads = UploadService(
            adb: adb,
            extraction: extraction,
            rclone: rclone
        )
        self.mirrors = MirrorService(rclone: rclone)

        let libraryService = GameLibraryService(rclone: rclone, extraction: extraction)
        self.gameLibrary = GameLibraryViewModel(service: libraryService)
        self.updater = UpdateService()
    }

    // MARK: - Startup

    @MainActor
    func start() async {
        // P0-1: Load bookmarks once at startup — all subsequent reads use cachedBookmarks
        loadBookmarksFromDisk()
        await dependencies.setup()
        mirrors.load()
        await gameLibrary.initialize()
        configurePipeline()
        startDeviceTracking()
        restoreLastDevice()

        // Background auto-sync — silently fetch the latest game list & thumbnails on every
        // launch so the library stays up-to-date without the user having to tap "Sync Now".
        // We log errors but don't block startup or show an alert — a sync failure on launch
        // is non-fatal (the user can trigger a manual resync from the toolbar).
        Task {
            let mirrorPath = mirrors.getActiveMirrorConfigPath()
            let mirrorRemote = mirrors.getActiveMirrorRemoteName()
            do {
                try await gameLibrary.forceSync(
                    mirrorConfigPath: mirrorPath,
                    activeMirrorRemote: mirrorRemote
                )
            } catch {
                // Non-fatal: log but don't alert — user can manually resync
                print("[AppState] Background auto-sync failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                configurePipeline()
                refreshInstalledStatus()
            }
        }
    }

    /// Loads wifi-bookmarks.json from disk into `cachedBookmarks`. Called once at startup.
    @MainActor
    private func loadBookmarksFromDisk() {
        let path = Constants.wifiBookmarksPath
        guard let data = try? Data(contentsOf: path) else {
            // File doesn't exist yet — first launch, nothing to load.
            cachedBookmarks = []
            return
        }
        do {
            cachedBookmarks = try JSONDecoder().decode([WiFiBookmark].self, from: data)
        } catch {
            // The file exists but can't be decoded — log a warning and start fresh rather
            // than silently losing the user's bookmarks without any diagnostic trace.
            print("[AppState] ⚠️ wifi-bookmarks.json is corrupt and could not be decoded: \(error). Starting with an empty bookmark list. The original file will be overwritten on the next save.")
            cachedBookmarks = []
        }
    }

    /// Writes `cachedBookmarks` to disk asynchronously (fire-and-forget).
    /// The in-memory cache is the source of truth; disk is just persistence.
    private func saveBookmarksToDisk() {
        let bookmarks = cachedBookmarks
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: Constants.appSupportDirectory,
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(bookmarks) {
                try? data.write(to: Constants.wifiBookmarksPath)
            }
        }
    }

    /// Forwards the VRP config (loaded by GameLibraryService) into the DownloadPipeline.
    /// Must be called whenever the config may have changed (startup, after sync).
    @MainActor
    func configurePipeline() {
        guard let config = gameLibrary.vrpConfig else { return }
        let downloadPath = UserDefaults.standard.string(forKey: "downloadPath")
            ?? AppSettings.default.downloadPath
        let speedLimit = UserDefaults.standard.integer(forKey: "downloadSpeedLimit")
        pipeline.configure(vrpConfig: config, downloadPath: downloadPath, speedLimit: speedLimit)
        // Refresh the library's installed status whenever an install succeeds so that
        // the "Installed" filter updates automatically after install completes.
        pipeline.onInstallComplete = { [weak self] in
            self?.refreshInstalledStatus()
        }
    }

    private func restoreLastDevice() {
        if let serial = UserDefaults.standard.string(forKey: "lastSelectedDeviceSerial") {
            selectedDevice = connectedDevices.first { $0.id == serial }
        }
    }

    // MARK: - Device Tracking

    func startDeviceTracking() {
        guard !isTrackingDevices else { return }
        isTrackingDevices = true
        Task {
            let stream = await adb.trackDevices()
            for await event in stream {
                await MainActor.run { handleDeviceEvent(event) }
            }
        }
    }

    @MainActor
    private func handleDeviceEvent(_ event: DeviceEvent) {
        switch event {
        case .added(let device):
            if !connectedDevices.contains(where: { $0.id == device.id }) {
                connectedDevices.append(device)
                // Enrich with details asynchronously
                Task {
                    let detailed = await adb.getDeviceDetails(serial: device.id)
                    await MainActor.run {
                        if let idx = connectedDevices.firstIndex(where: { $0.id == device.id }) {
                            connectedDevices[idx] = detailed
                        }
                        // Also update selectedDevice if it's this device — WiFi connect case
                        if selectedDevice?.id == device.id {
                            selectedDevice = detailed
                            // Refresh installed packages now that we have a confirmed connection
                            refreshInstalledStatus()
                        }
                        // Persist enriched metadata back to wifi bookmarks file
                        if detailed.isWifi {
                            persistBookmarkMetadata(for: detailed)
                        }
                    }
                }
            }
            if selectedDevice == nil {
                selectDevice(device)
            }

        case .removed(let serial):
            connectedDevices.removeAll { $0.id == serial }
            if selectedDevice?.id == serial {
                // Check if wireless was enabled for this USB device — if so, try to
                // seamlessly transition to the WiFi connection instead of going blank.
                if let wifiIP = wifiEnabledIPs[serial] {
                    let wifiSerial = "\(wifiIP):5555"
                    if let wifiDevice = connectedDevices.first(where: { $0.id == wifiSerial }) {
                        // WiFi device is already live — select it directly.
                        selectDevice(wifiDevice)
                        wifiEnabledIPs.removeValue(forKey: serial)
                        return
                    }
                    // WiFi device not yet in connectedDevices — the poller will add it
                    // shortly (it was recently connected so the grace period protects it).
                    // Fall through to normal handling; the poller's .added event will
                    // auto-select the WiFi device via the selectedDevice == nil check.
                    wifiEnabledIPs.removeValue(forKey: serial)
                }
                // Clear all device-specific state before selecting the next device
                clearDeviceState()
                selectDevice(connectedDevices.first(where: { $0.type == .device || $0.type == .emulator }))
            }

        case .changed(let device):
            if let idx = connectedDevices.firstIndex(where: { $0.id == device.id }) {
                connectedDevices[idx] = device
            }
            if selectedDevice?.id == device.id {
                selectedDevice = device
                if device.type == .device || device.type == .emulator {
                    // Device recovered to fully connected — re-enrich and refresh installed status
                    Task {
                        let detailed = await adb.getDeviceDetails(serial: device.id)
                        await MainActor.run {
                            if let idx = connectedDevices.firstIndex(where: { $0.id == device.id }) {
                                connectedDevices[idx] = detailed
                            }
                            selectedDevice = detailed
                            refreshInstalledStatus()
                        }
                    }
                } else {
                    // Device went offline/unauthorized — clear all stale device-specific UI state
                    // immediately so the card and library reflect the actual disconnected status.
                    clearDeviceState()
                }
            }

        case .error:
            break
        }
    }

    /// Clears all device-specific UI state. Called whenever the selected device goes offline
    /// or is removed, so the library and device card don't show stale data.
    @MainActor
    private func clearDeviceState() {
        installedPackageCount = 0
        deviceOnlyGames = []
        Task { await gameLibrary.updateInstalledStatus(installedPackages: []) }
    }

    // MARK: - Sidebar Device List

    /// Rebuilds `sidebarDevices` from `connectedDevices`, `cachedBookmarks`, and
    /// `wifiEnabledIPs`. Called via `didSet` on each of those three properties so
    /// the stored result is always up-to-date and SwiftUI never pays the O(n²) cost
    /// inside a view body evaluation.
    ///
    /// Rules:
    ///  - USB device + matching WiFi device (same IP) → single entry, USB data, both icons
    ///  - USB only → single entry, .usb icon
    ///  - WiFi only → single entry, .wifi icon
    ///  - Saved bookmark with no live connection → offline entry with Connect button
    private func rebuildSidebarDevices() {
        let bookmarks = cachedBookmarks

        var result: [SidebarDevice] = []
        var consumedWifiSerials = Set<String>()

        // Step 1: Process USB-connected devices first (priority)
        let usbDevices = connectedDevices.filter { !$0.isWifi }
        for usbDevice in usbDevices {
            // Check if there's also a WiFi device for the same physical device.
            var matchingWifiSerial: String? = nil
            if let usbIP = usbDevice.ipAddress {
                matchingWifiSerial = connectedDevices.first(where: {
                    $0.isWifi && $0.id.hasPrefix(usbIP + ":")
                })?.id
            }
            // Fallback: check wifiEnabledIPs even if the WiFi serial isn't live yet
            if matchingWifiSerial == nil, let enabledIP = wifiEnabledIPs[usbDevice.id] {
                matchingWifiSerial = "\(enabledIP):5555"
            }

            // Find matching bookmark
            let bookmark = bookmarks.first(where: { bm in
                if let usbIP = usbDevice.ipAddress, usbIP == bm.ipAddress { return true }
                if let name = usbDevice.friendlyModelName, name == bm.deviceModelName { return false }
                return false
            })

            var types: Set<SidebarDevice.ConnectionType> = [.usb]
            if let wifiSerial = matchingWifiSerial {
                types.insert(.wifi)
                consumedWifiSerials.insert(wifiSerial)
            }

            result.append(SidebarDevice(
                id: usbDevice.id,
                device: usbDevice,
                bookmark: bookmark,
                connectionTypes: types
            ))
        }

        // Step 2: Process WiFi-connected devices not already consumed by a USB device.
        let wifiDevices = connectedDevices.filter { $0.isWifi && !consumedWifiSerials.contains($0.id) }
        for wifiDevice in wifiDevices {
            let ipFromSerial = wifiDevice.id.split(separator: ":").first.map(String.init)
            let bookmark = bookmarks.first(where: { bm in bm.ipAddress == ipFromSerial })
            if wifiDevice.type == .device || wifiDevice.type == .emulator {
                result.append(SidebarDevice(
                    id: wifiDevice.id,
                    device: wifiDevice,
                    bookmark: bookmark,
                    connectionTypes: [.wifi]
                ))
            } else if bookmark == nil {
                result.append(SidebarDevice(
                    id: wifiDevice.id,
                    device: wifiDevice,
                    bookmark: nil,
                    connectionTypes: []
                ))
            }
        }

        // Step 3: Add offline bookmarks (not currently online).
        let onlineIPs: Set<String> = Set(connectedDevices
            .filter { $0.type == .device || $0.type == .emulator }
            .compactMap { device -> String? in
                if device.isWifi {
                    return device.id.split(separator: ":").first.map(String.init)
                } else {
                    return device.ipAddress
                }
            })

        let offlineBookmarks = bookmarks.filter { !onlineIPs.contains($0.ipAddress) }
        for bookmark in offlineBookmarks {
            let offlineDevice = connectedDevices.first(where: { device in
                guard device.isWifi else { return false }
                let ip = device.id.split(separator: ":").first.map(String.init)
                return ip == bookmark.ipAddress
            })
            result.append(SidebarDevice(
                id: "bookmark-\(bookmark.id)",
                device: offlineDevice,
                bookmark: bookmark,
                connectionTypes: []
            ))
        }

        sidebarDevices = result
    }

    // MARK: - Connect to WiFi Bookmark

    /// Initiates an ADB WiFi connection to a saved bookmark.
    /// Returns `true` if the device is confirmed reachable, `false` on failure.
    @MainActor
    @discardableResult
    func connectToBookmark(_ bookmark: WiFiBookmark) async -> Bool {
        let serial = bookmark.serial
        let ip = bookmark.ipAddress
        let port = bookmark.port

        // connectTcp now verifies the device is responsive via echo-ok — returns false on failure.
        let connected = (try? await adb.connectTcp(ip: ip, port: port)) ?? false
        guard connected else { return false }

        // Give ADB tracker a moment to register the new device
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Force-add only if the tracker hasn't picked it up yet AND we know the connection succeeded
        let alreadyPresent = connectedDevices.contains(where: { $0.id == serial })
        if !alreadyPresent {
            let device = await adb.getDeviceDetails(serial: serial)
            // Only accept as online if the device type is actually reachable
            guard device.type == .device || device.type == .emulator else { return false }
            if !connectedDevices.contains(where: { $0.id == serial }) {
                connectedDevices.append(device)
            }
            selectDevice(device)
            persistBookmarkMetadata(for: device)
        } else {
            // Tracker found it — just select it
            if let device = connectedDevices.first(where: { $0.id == serial }) {
                selectDevice(device)
            }
        }
        return true
    }

    // MARK: - Device Selection

    @MainActor
    func selectDevice(_ device: DeviceInfo?) {
        selectedDevice = device
        pipeline.setConnectedDevice(device?.id)
        if let serial = device?.id {
            UserDefaults.standard.set(serial, forKey: "lastSelectedDeviceSerial")
            Task {
                let packages = (try? await adb.getInstalledPackages(serial: serial)) ?? []
                await updateInstalledStatusAndDeviceOnly(packages: packages, serial: serial)
            }
        } else {
            // No device — clear device-specific state
            installedPackageCount = 0
            deviceOnlyGames = []
            Task { await gameLibrary.updateInstalledStatus(installedPackages: []) }
        }
    }

    // MARK: - Installed Status Refresh

    /// Re-fetches installed packages for the selected device and updates all derived state.
    @MainActor
    func refreshInstalledStatus() {
        guard let serial = selectedDevice?.id else { return }
        Task {
            let packages = (try? await adb.getInstalledPackages(serial: serial)) ?? []
            await updateInstalledStatusAndDeviceOnly(packages: packages, serial: serial)
        }
    }

    /// Updates the library's installed flags AND computes `deviceOnlyGames` + `installedPackageCount`.
    /// Must be called from a Task context (not on MainActor directly) to avoid blocking UI.
    private func updateInstalledStatusAndDeviceOnly(packages: [PackageInfo], serial: String) async {
        // 1. Update the library's installed status
        await gameLibrary.updateInstalledStatus(installedPackages: packages)

        // 2. Compute installed count (use packages we already have — avoid a second adb call)
        let count = packages.count

        // 3. Compute device-only games: packages on device not in the VRP library
        //    We build a set of VRP package names for fast lookup.
        let libraryPackageNames = await MainActor.run {
            Set(gameLibrary.games.map { $0.packageName })
        }

        // 3b. Resolve human-readable names and cached icons for device-only packages
        //     concurrently, then build the GameInfo array.
        let deviceOnlyPackages = packages.filter { !libraryPackageNames.contains($0.packageName) }

        // Build GameInfo for each device-only package using the prettified name.
        let deviceOnly: [GameInfo] = deviceOnlyPackages.map { pkg in
            let displayName = Self.prettifyPackageName(pkg.packageName)
            return GameInfo(
                name:              displayName,
                packageName:       pkg.packageName,
                version:           String(pkg.versionCode),
                size:              "",
                lastUpdated:       "",
                releaseName:       "",
                downloads:         0,
                thumbnailPath:     "",
                notePath:          "",
                isInstalled:       true,
                deviceVersionCode: pkg.versionCode,
                hasUpdate:         false
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // 4. Push back to @MainActor
        await MainActor.run {
            self.installedPackageCount = count
            self.deviceOnlyGames = deviceOnly
        }
    }

    // MARK: - Enable WiFi ADB

    /// Switches the currently selected USB device to ADB-over-WiFi.
    /// Returns the connected IP on success, or throws with a user-visible message.
    ///
    /// Flow:
    ///  1. Run tcpip + connect via ADBService (includes 1.5s daemon-restart delay).
    ///  2. Record the USB serial → WiFi IP mapping in wifiEnabledIPs so that:
    ///     (a) sidebarDevices immediately shows dual USB+WiFi badges on the USB card,
    ///     (b) when the USB cable is removed the .removed handler can transition to WiFi.
    ///  3. Persist a WiFi bookmark for future reconnections.
    ///  The selected device is NOT changed here — the USB card stays selected, now
    ///  showing both connection-type badges. When the USB is physically unplugged the
    ///  .removed handler seamlessly transitions the selection to the WiFi device.
    @MainActor
    func enableWifiForSelectedDevice() async throws -> String {
        guard let device = selectedDevice, !device.isWireless else {
            throw NSError(domain: "ADB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No USB device selected."])
        }
        let ip = try await adb.enableWifiADB(serial: device.id)

        // Record the USB→WiFi IP mapping so the sidebar can show the dual badge.
        wifiEnabledIPs[device.id] = ip

        // Persist a WiFi bookmark so the device can be reconnected after USB unplug.
        persistBookmarkForIP(ip, device: device)

        return ip
    }

    /// Saves or updates a WiFi bookmark for the given IP / device combination.
    /// P0-1 / P1-10: Updates in-memory cache first, then persists async off-thread.
    @MainActor
    private func persistBookmarkForIP(_ ip: String, device: DeviceInfo) {
        guard !cachedBookmarks.contains(where: { $0.ipAddress == ip }) else { return }
        let bookmark = WiFiBookmark(
            name: device.friendlyModelName ?? device.id,
            ipAddress: ip,
            port: 5555
        )
        cachedBookmarks.append(bookmark)
        saveBookmarksToDisk()
    }

    // MARK: - Uninstall

    /// Uninstalls the given game from the selected device and refreshes installed state.
    @MainActor
    func uninstallGame(_ game: GameInfo) async throws {
        guard let serial = selectedDevice?.id else { return }
        _ = try await adb.uninstall(serial: serial, packageName: game.packageName)
        refreshInstalledStatus()
    }

    // MARK: - Export Game

    /// Presents an NSOpenPanel for the user to choose a destination folder, then
    /// exports the game's APK (+ OBB) from the selected device to that folder.
    @MainActor
    func exportGame(_ game: GameInfo) {
        guard let serial = selectedDevice?.id else {
            showError("No device connected. Please connect your Quest and try again.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Export \(game.name) — choose destination folder"
        panel.message = "Select a folder to save the exported APK and OBB files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // Show in-progress overlay
        exportProgress = ExportProgress(
            packageName: game.packageName,
            gameName: game.name,
            isComplete: false
        )

        Task {
            do {
                let exportedFiles = try await adb.exportGame(
                    serial: serial,
                    packageName: game.packageName,
                    destinationFolder: destination,
                    includeObb: true
                )
                await MainActor.run {
                    exportProgress?.isComplete = true
                    exportProgress?.exportedFiles = exportedFiles
                    // Reveal the destination folder in Finder
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                await MainActor.run {
                    exportProgress?.isComplete = true
                    exportProgress?.error = error.localizedDescription
                    showError("Export failed: \(error.localizedDescription)")
                }
            }

            // Auto-dismiss the progress overlay after 4 seconds.
            // Capture the current progress ID so a manual dismiss or a new export
            // started during the sleep won't be incorrectly cleared by this timer.
            let progressID = await MainActor.run { exportProgress?.id }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if exportProgress?.id == progressID {
                    exportProgress = nil
                }
            }
        }
    }

    // MARK: - Alert

    @MainActor
    func showError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - WiFi Bookmark Persistence

    /// Enriches the bookmark entry matching this device's IP/port with the latest
    /// model name, battery, and storage data, then persists asynchronously.
    /// P0-1 / P1-10: Mutates in-memory `cachedBookmarks`; disk write is async off-thread.
    @MainActor
    func persistBookmarkMetadata(for device: DeviceInfo) {
        guard device.isWifi else { return }

        // Parse IP and port from the serial (format: "ip:port")
        let parts = device.id.split(separator: ":")
        guard parts.count == 2,
              let port = Int(parts[1]) else { return }
        let ip = String(parts[0])

        if let idx = cachedBookmarks.firstIndex(where: { $0.ipAddress == ip && $0.port == port }) {
            // Update existing
            var bm = cachedBookmarks[idx]
            if let name = device.friendlyModelName { bm.deviceModelName = name }
            if let battery = device.batteryLevel    { bm.lastBatteryLevel = battery }
            if let total = device.storageTotal      { bm.lastStorageTotal = total }
            if let free = device.storageFree        { bm.lastStorageFree = free }
            if let model = device.model {
                let lower = model.lowercased()
                for questModel in QuestModel.allCases where lower.contains(questModel.rawValue) {
                    bm.modelCodename = questModel.rawValue
                    break
                }
            }
            bm.lastConnected = Date()
            cachedBookmarks[idx] = bm
        } else {
            // Create new bookmark entry
            var bm = WiFiBookmark(name: device.friendlyModelName ?? ip, ipAddress: ip, port: port)
            bm.deviceModelName = device.friendlyModelName
            bm.lastBatteryLevel = device.batteryLevel
            bm.lastStorageTotal = device.storageTotal
            bm.lastStorageFree  = device.storageFree
            if let model = device.model {
                let lower = model.lowercased()
                for questModel in QuestModel.allCases where lower.contains(questModel.rawValue) {
                    bm.modelCodename = questModel.rawValue
                    break
                }
            }
            bm.lastConnected = Date()
            cachedBookmarks.insert(bm, at: 0)
        }

        // Persist async — cache is already updated so UI reflects changes immediately
        saveBookmarksToDisk()
    }

    // MARK: - Package Name Prettifier

    /// Converts a reverse-DNS package name into a human-readable title.
    ///
    /// Strategy:
    ///  1. Strip well-known top-level prefixes (com, org, net, io, tv, co, app).
    ///  2. Strip the second-level domain segment if it's redundant with the app name
    ///     (e.g. "bigscreenvr" in "com.bigscreenvr.bigscreen" → just use "bigscreen").
    ///  3. Take the last meaningful path component.
    ///  4. Split on common word boundaries (camelCase, underscores, dots, hyphens).
    ///  5. Title-case each word and join with spaces.
    ///
    /// Examples:
    ///   com.bigscreenvr.bigscreen           → "Bigscreen"
    ///   com.facebook.arvr.quillplayer       → "Quill Player"
    ///   com.google.android.apps.youtube.vr.oculus → "Youtube VR Oculus"
    ///   com.meta.shell.env.footprint.haven2025 → "Haven 2025"
    ///   com.limelight.noir                  → "Noir"
    ///   com.meta.curio.ruler                → "Ruler"
    static func prettifyPackageName(_ packageName: String) -> String {
        // Known noise words to drop (TLDs and common vendor/platform segments)
        let noiseWords: Set<String> = [
            "com", "org", "net", "io", "tv", "co", "app",
            "android", "google", "meta", "oculus", "facebook",
            "shell", "env", "arvr", "vr", "apps"
        ]

        // Split the full package name by "."
        let parts = packageName.lowercased().components(separatedBy: ".")

        // Drop the leading TLD segment(s), then find the last non-noise, non-redundant component
        // as the primary display word.
        let meaningful = parts.filter { !noiseWords.contains($0) && !$0.isEmpty }
        let source = meaningful.last ?? parts.last ?? packageName

        // Split camelCase and handle underscores/hyphens
        let words = splitIntoWords(source)

        // Title-case and join
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return titled.joined(separator: " ")
    }

    /// Splits a string into words by camelCase transitions, underscores, hyphens, and digits/letters boundaries.
    private static func splitIntoWords(_ input: String) -> [String] {
        var result: [String] = []
        // First split on non-alphanumeric separators
        let roughWords = input.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for word in roughWords {
            // Split camelCase and letter-digit / digit-letter boundaries
            var current = ""
            var prevIsUpper = false
            var prevIsDigit = false
            for (i, ch) in word.enumerated() {
                let isUpper = ch.isUppercase
                let isDigit = ch.isNumber
                let isLower = ch.isLowercase

                if i > 0 {
                    let prevIsLower = !prevIsUpper && !prevIsDigit
                    // Start new word on: uppercase after lowercase (camelCase), digit↔letter boundary
                    let camelSplit = isUpper && prevIsLower
                    let digitToLetter = isLower && prevIsDigit
                    let letterToDigit = isDigit && !prevIsDigit

                    if camelSplit || digitToLetter || letterToDigit {
                        if !current.isEmpty { result.append(current.lowercased()) }
                        current = String(ch)
                        prevIsUpper = isUpper
                        prevIsDigit = isDigit
                        continue
                    }
                }
                current.append(ch)
                prevIsUpper = isUpper
                prevIsDigit = isDigit
            }
            if !current.isEmpty { result.append(current.lowercased()) }
        }

        return result.filter { !$0.isEmpty }
    }
}

// MARK: - Navigation Tab

enum AppTab: String, CaseIterable, Identifiable {
    case library   = "Library"
    case downloads = "Downloads"
    case saves     = "Saves"
    case terminal  = "Terminal"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .library:   return "square.grid.2x2"
        case .downloads: return "arrow.down.circle"
        case .saves:     return "externaldrive.badge.timemachine"
        case .terminal:  return "terminal"
        }
    }

    var description: String {
        switch self {
        case .library:   return "Browse & install games"
        case .downloads: return "Manage active downloads"
        case .saves:     return "Backup & restore game saves"
        case .terminal:  return "ADB shell & commands"
        }
    }
}
