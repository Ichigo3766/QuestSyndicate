import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            // App branding header
            appHeader
            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Navigation section
                    sidebarSectionHeader("NAVIGATION")
                        .padding(.top, 14)
                    navSection
                        .padding(.top, 6)

                    // Devices section
                    sidebarSectionHeader("DEVICES")
                        .padding(.top, 18)
                    devicesSection
                        .padding(.top, 6)

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 14, weight: .medium))
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: Bindable(appState).showSettings) {
            SettingsContainerView()
                .environment(appState)
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "visionpro")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("QuestSyndicate")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                Text("VR Game Manager")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Section Header

    private func sidebarSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(1.0)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Navigation Section

    private var navSection: some View {
        VStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                NavCard(tab: tab, isSelected: appState.selectedTab == tab) {
                    appState.selectedTab = tab
                }
                .environment(appState)
            }
        }
    }

    // MARK: - Devices Section

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wi-Fi connect button (inline, right-aligned)
            HStack {
                Spacer()
                WiFiConnectButton()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            let devices = appState.sidebarDevices
            if devices.isEmpty {
                noDevicesCard
            } else {
                VStack(spacing: 6) {
                    ForEach(devices) { sidebarDevice in
                        if sidebarDevice.isOnline, let device = sidebarDevice.device {
                            DeviceCardView(
                                device: device,
                                isSelected: appState.selectedDevice?.id == device.id,
                                connectionTypes: sidebarDevice.connectionTypes
                            )
                            .environment(appState)
                            .onTapGesture {
                                appState.selectDevice(device)
                            }
                        } else if let bookmark = sidebarDevice.bookmark {
                            OfflineDeviceCard(
                                bookmark: bookmark,
                                offlineReason: sidebarDevice.device.map { offlineReason(for: $0) }
                            )
                            .environment(appState)
                        } else if let device = sidebarDevice.device {
                            OfflineDeviceInfoCard(device: device)
                        }
                    }
                }
            }
        }
    }

    private func offlineReason(for device: DeviceInfo) -> String {
        switch device.type {
        case .offline:      return "Offline"
        case .unauthorized: return "Unauthorized"
        case .unknown:      return "Unavailable"
        default:            return "Offline"
        }
    }

    private var noDevicesCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .frame(width: 42, height: 42)
                    .glassCard(cornerRadius: 10)
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("No devices")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Connect via USB or Wi-Fi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: - Offline Device Card

struct OfflineDeviceCard: View {
    let bookmark: WiFiBookmark
    var offlineReason: String? = nil
    @Environment(AppState.self) private var appState
    @State private var isConnecting = false
    @State private var connectionFailed = false

    private var statusLabel: String {
        if connectionFailed { return "Failed" }
        return offlineReason ?? "Offline"
    }

    private var statusDotColor: Color {
        if connectionFailed { return .red }
        switch offlineReason {
        case "Unauthorized": return .orange
        case "Unavailable":  return Color.secondary
        default:             return Color.secondary.opacity(0.7)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .frame(width: 42, height: 42)
                    .glassCard(cornerRadius: 10)
                Image(systemName: bookmark.modelSystemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text("\(statusLabel) · \(bookmark.ipAddress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Connect button
            Button {
                guard !isConnecting else { return }
                isConnecting = true
                connectionFailed = false
                Task {
                    let success = await appState.connectToBookmark(bookmark)
                    isConnecting = false
                    if !success {
                        connectionFailed = true
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        connectionFailed = false
                    }
                }
            } label: {
                if isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 22, height: 22)
                } else {
                    Text(connectionFailed ? "Retry" : "Connect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(connectionFailed ? .red : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(connectionFailed ? Color.red.opacity(0.6) : Color.accentColor.opacity(0.6), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: - Offline Device Info Card

struct OfflineDeviceInfoCard: View {
    let device: DeviceInfo

    var statusLabel: String {
        switch device.type {
        case .offline:       return "Offline"
        case .unauthorized:  return "Unauthorized"
        default:             return "Unavailable"
        }
    }

    var statusDotColor: Color {
        switch device.type {
        case .offline:       return .red
        case .unauthorized:  return .orange
        default:             return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .frame(width: 42, height: 42)
                    .glassCard(cornerRadius: 10)
                Image(systemName: "visionpro")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor.opacity(0.85))
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }
}

// MARK: - Nav Card

struct NavCard: View {
    @Environment(AppState.self) private var appState
    let tab: AppTab
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var badge: Int {
        switch tab {
        case .downloads:
            return appState.pipeline.queue.filter { $0.status.isActive }.count
        default:
            return 0
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 13) {
                // Icon container
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.08 : 0.05))
                        .frame(width: 42, height: 42)

                    Image(systemName: tab.systemImage)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : Color.primary.opacity(0.6))
                }

                // Labels
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.9))

                    Text(tab.description)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.6) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Badge
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.08)
                        : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering && !isSelected ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Wi-Fi Connect Button

struct WiFiConnectButton: View {
    @Environment(AppState.self) private var appState
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wifi")
                    .font(.system(size: 11, weight: .semibold))
                Text("Wi-Fi")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help("Connect via Wi-Fi")
        .sheet(isPresented: $showSheet) {
            WiFiConnectSheet()
                .environment(appState)
        }
    }
}
