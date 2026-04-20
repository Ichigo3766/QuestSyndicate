import SwiftUI

struct WiFiConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var ipAddress = ""
    @State private var port = "5555"
    @State private var isConnecting = false
    @State private var connectingSerial: String? = nil
    @State private var errorMessage: String? = nil
    @State private var bookmarks: [WiFiBookmark] = []
    @State private var showManual = false

    // Serials of devices that are TRULY online (not just listed in ADB as offline/unauthorized)
    private var connectedSerials: Set<String> {
        Set(appState.connectedDevices
            .filter { $0.type == .device || $0.type == .emulator }
            .map { $0.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    savedDevicesSection
                    manualSection
                    hintBlock
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 560)
        .onAppear { loadBookmarks() }
        .onChange(of: appState.connectedDevices) { _, _ in
            // When a new device connects, try to enrich its bookmark
            for device in appState.connectedDevices where device.isWifi {
                enrichBookmarkIfNeeded(for: device)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .frame(width: 32, height: 32)
                    .glassTinted(.accentColor, cornerRadius: 16)
                Image(systemName: "wifi")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Connect via Wi-Fi")
                    .font(.headline)
                Text("Manage saved devices and connect wirelessly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Saved Devices Section

    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Devices")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                if !bookmarks.isEmpty {
                    Text("\(bookmarks.count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassCapsule()
                }

                Spacer()
            }

            if bookmarks.isEmpty {
                emptyBookmarksView
            } else {
                VStack(spacing: 8) {
                    ForEach(bookmarks) { bookmark in
                        SavedDeviceRow(
                            bookmark: bookmark,
                            isConnected: connectedSerials.contains(bookmark.serial),
                            isConnecting: connectingSerial == bookmark.serial
                        ) {
                            Task { await connectBookmark(bookmark) }
                        } onDisconnect: {
                            Task { await disconnectBookmark(bookmark) }
                        } onDelete: {
                            deleteBookmark(bookmark)
                        }
                    }
                }
            }
        }
    }

    private var emptyBookmarksView: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("No saved devices")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("Devices you connect to will appear here automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Manual Section

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showManual.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 26, height: 26)
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text("Add Device Manually")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: showManual ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if showManual {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.horizontal, -12)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IP Address")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g. 192.168.1.100", text: $ipAddress)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Port")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("5555", text: $port)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                    }
                    .padding(.top, 2)

                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await connectManual() }
                    } label: {
                        HStack(spacing: 6) {
                            if isConnecting {
                                ProgressView().scaleEffect(0.75)
                                Text("Connecting…")
                            } else {
                                Image(systemName: "wifi")
                                Text("Connect")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(ipAddress.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Hint Block

    private var hintBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Enable Wi-Fi debugging in Quest Developer Settings first", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Quest and Mac must be on the same Wi-Fi network", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("For new devices: connect via USB first, then use \"Switch to WiFi\" from the device card", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Connect / Disconnect Actions

    private func connectBookmark(_ bookmark: WiFiBookmark) async {
        connectingSerial = bookmark.serial
        errorMessage = nil
        do {
            try await appState.adb.connectTcpThrowing(ip: bookmark.ipAddress, port: bookmark.port)
            // Mark last connected time
            updateLastConnected(bookmark)
        } catch {
            errorMessage = "Could not connect to \(bookmark.ipAddress) — device unreachable"
        }
        connectingSerial = nil
    }

    private func disconnectBookmark(_ bookmark: WiFiBookmark) async {
        connectingSerial = bookmark.serial
        _ = try? await appState.adb.disconnectTcp(ip: bookmark.ipAddress, port: bookmark.port)
        connectingSerial = nil
    }

    private func connectManual() async {
        let trimmed = ipAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let portInt = Int(port) ?? 5555
        isConnecting = true
        errorMessage = nil
        do {
            try await appState.adb.connectTcpThrowing(ip: trimmed, port: portInt)
            saveOrUpdateBookmark(ip: trimmed, port: portInt, device: nil)
            ipAddress = ""
            port = "5555"
        } catch {
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }

    // MARK: - Bookmark Enrichment

    /// Called when a WiFi device connects — enriches its bookmark with device metadata
    private func enrichBookmarkIfNeeded(for device: DeviceInfo) {
        guard device.isWifi,
              let ip = device.ipAddress ?? extractIP(from: device.id) else { return }
        let portNum = extractPort(from: device.id) ?? 5555

        // Only enrich if we have useful metadata
        guard device.friendlyModelName != nil || device.batteryLevel != nil else { return }

        saveOrUpdateBookmark(ip: ip, port: portNum, device: device)
    }

    private func extractIP(from serial: String) -> String? {
        let parts = serial.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return String(parts[0])
    }

    private func extractPort(from serial: String) -> Int? {
        let parts = serial.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    // MARK: - Bookmark Persistence

    private func loadBookmarks() {
        guard let data = try? Data(contentsOf: Constants.wifiBookmarksPath),
              let loaded = try? JSONDecoder().decode([WiFiBookmark].self, from: data) else { return }
        bookmarks = loaded
    }

    private func saveOrUpdateBookmark(ip: String, port: Int, device: DeviceInfo?) {
        if let idx = bookmarks.firstIndex(where: { $0.ipAddress == ip && $0.port == port }) {
            // Update existing bookmark with enriched metadata
            var updated = bookmarks[idx]
            if let device = device {
                if let name = device.friendlyModelName { updated.deviceModelName = name }
                if let battery = device.batteryLevel { updated.lastBatteryLevel = battery }
                if let total = device.storageTotal { updated.lastStorageTotal = total }
                if let free = device.storageFree { updated.lastStorageFree = free }
                // Try to extract codename from model string
                if let model = device.model {
                    let lower = model.lowercased()
                    for questModel in QuestModel.allCases {
                        if lower.contains(questModel.rawValue) {
                            updated.modelCodename = questModel.rawValue
                            break
                        }
                    }
                }
            }
            updated.lastConnected = Date()
            bookmarks[idx] = updated
        } else {
            // Create new bookmark
            var bookmark = WiFiBookmark(name: ip, ipAddress: ip, port: port)
            if let device = device {
                bookmark.deviceModelName = device.friendlyModelName
                bookmark.lastBatteryLevel = device.batteryLevel
                bookmark.lastStorageTotal = device.storageTotal
                bookmark.lastStorageFree = device.storageFree
                if let model = device.model {
                    let lower = model.lowercased()
                    for questModel in QuestModel.allCases {
                        if lower.contains(questModel.rawValue) {
                            bookmark.modelCodename = questModel.rawValue
                            break
                        }
                    }
                }
            }
            bookmark.lastConnected = Date()
            bookmarks.insert(bookmark, at: 0)
        }
        persistBookmarks()
    }

    private func updateLastConnected(_ bookmark: WiFiBookmark) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].lastConnected = Date()
            persistBookmarks()
        }
    }

    private func deleteBookmark(_ bookmark: WiFiBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    private func persistBookmarks() {
        try? FileManager.default.createDirectory(
            at: Constants.appSupportDirectory,
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: Constants.wifiBookmarksPath)
        }
    }
}

// MARK: - Saved Device Row

struct SavedDeviceRow: View {
    let bookmark: WiFiBookmark
    let isConnected: Bool
    let isConnecting: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Device icon with status dot
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .frame(width: 44, height: 44)
                        .glassCard(cornerRadius: 10)
                    Image(systemName: bookmark.modelSystemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(.primary.opacity(0.8))
                }

                Circle()
                    .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }

            // Device info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(bookmark.displayLabel)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isConnected {
                        Text("Online")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassCapsuleTinted(.green)
                    }
                }

                HStack(spacing: 6) {
                    Text(bookmark.serial)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text("WiFi")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .glassCapsuleTinted(.accentColor)
                }

                // Battery and storage info if available
                HStack(spacing: 8) {
                    if let battery = bookmark.lastBatteryLevel {
                        HStack(spacing: 3) {
                            Image(systemName: batteryIcon(battery))
                                .font(.system(size: 9))
                                .foregroundStyle(batteryColor(battery))
                            Text("\(battery)%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let free = bookmark.lastStorageFree, bookmark.lastStorageTotal != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("\(free) free")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let lastSeen = bookmark.lastConnected {
                        Text("Last seen \(lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 70, height: 26)
                } else if isConnected {
                    Button(action: onDisconnect) {
                        Text("Disconnect")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                } else {
                    Button(action: onConnect) {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.system(size: 10))
                            Text("Connect")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                // Delete button (shown on hover)
                if isHovering && !isConnected {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove saved device")
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isConnected {
                RoundedRectangle(cornerRadius: 12)
                    .glassTinted(.green, cornerRadius: 12)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 12)
                    .glassInteractive(cornerRadius: 12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .glassCard(cornerRadius: 12)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isConnected)
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 0..<20:  return "battery.0percent"
        case 20..<40: return "battery.25percent"
        case 40..<60: return "battery.50percent"
        case 60..<80: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .orange }
        return .red
    }
}
