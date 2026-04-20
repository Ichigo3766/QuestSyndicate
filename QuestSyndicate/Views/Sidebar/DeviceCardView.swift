import SwiftUI

// MARK: - DeviceCardView

struct DeviceCardView: View {
    let device: DeviceInfo
    let isSelected: Bool
    var connectionTypes: Set<SidebarDevice.ConnectionType>? = nil

    @Environment(AppState.self) private var appState

    @State private var isSwitchingToWifi = false
    @State private var wifiSwitchResult: WifiSwitchResult? = nil

    enum WifiSwitchResult {
        case success(ip: String)
        case failure(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header row: icon + name + connection badge ──
            deviceHeader

            if isSelected && device.type == .device {
                Divider()
                    .padding(.vertical, 10)

                deviceStats
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.10), radius: isSelected ? 8 : 5, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        HStack(spacing: 12) {
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: device.type == .emulator ? "iphone" : "visionpro")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Device name row
                HStack(spacing: 6) {
                    // Status indicator dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusColor.opacity(0.6), radius: 3)

                    Text(device.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if device.type == .emulator {
                        Text("EMU")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(.orange)
                            .glassTinted(.orange, cornerRadius: 4)
                    }
                }

                // Subtitle: battery or status
                if (device.type == .device || device.type == .emulator),
                   let battery = device.batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: device.batteryIcon)
                            .font(.system(size: 10))
                            .foregroundStyle(batteryColor(battery))
                        Text("\(battery)% battery")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if device.type != .device && device.type != .emulator {
                    Text(deviceStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            connectionBadge
        }
    }

    // MARK: - Device Stats (expanded when selected)

    @ViewBuilder
    private var deviceStats: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Installed apps count
            if appState.installedPackageCount > 0 {
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("INSTALLED")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .kerning(0.8)
                        Text("\(appState.installedPackageCount)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("apps & games")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor.opacity(0.25))
                }
            }

            // Storage bar
            storageSection

            // Action buttons
            VStack(spacing: 6) {
                // VIEW DEVICE APPS button
                Button {
                    appState.selectedTab = .library
                    NotificationCenter.default.post(name: .showOnDeviceOnly, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11, weight: .semibold))
                        Text("VIEW DEVICE APPS")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                // SWITCH TO WI-FI — only for USB devices without active WiFi
                if !device.isWireless && !resolvedConnectionTypes.contains(.wifi) {
                    wifiSwitchButton
                }
            }
        }
    }

    // MARK: - Storage Section

    @ViewBuilder
    private var storageSection: some View {
        if let freeGB = device.storageFreeGB, let totalGB = device.storageTotalGB, totalGB > 0 {
            let usedGB = totalGB - freeGB
            let usedFraction = min(max(usedGB / totalGB, 0), 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("STORAGE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .kerning(0.8)
                    Spacer()
                    Text(String(format: "%.1f GB free", freeGB))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Storage bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: storageBarGradient(fraction: usedFraction),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(geo.size.width * usedFraction, 6), height: 8)
                    }
                }
                .frame(height: 8)

                Text(String(format: "%.0f%% used · %.1f GB / %.0f GB", usedFraction * 100, usedGB, totalGB))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let free = device.storageFree, let total = device.storageTotal {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(free) free / \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Wi-Fi Switch Button

    @ViewBuilder
    private var wifiSwitchButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !isSwitchingToWifi else { return }
                isSwitchingToWifi = true
                wifiSwitchResult = nil
                Task {
                    do {
                        let ip = try await appState.enableWifiForSelectedDevice()
                        wifiSwitchResult = .success(ip: ip)
                    } catch {
                        wifiSwitchResult = .failure(message: error.localizedDescription)
                    }
                    isSwitchingToWifi = false
                    if case .success = wifiSwitchResult {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        wifiSwitchResult = nil
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isSwitchingToWifi {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        Text("Enabling wireless…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else if case .success(let ip) = wifiSwitchResult {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.green)
                        Text("Wireless · \(ip)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green).lineLimit(1)
                    } else if case .failure(let msg) = wifiSwitchResult {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Text(msg)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: "wifi")
                            .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        Text("ENABLE WIRELESS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .disabled(isSwitchingToWifi)

            if wifiSwitchResult == nil && !isSwitchingToWifi {
                Text("Enable to stay connected wirelessly after unplugging USB.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Connection Badge

    private var resolvedConnectionTypes: Set<SidebarDevice.ConnectionType> {
        if let types = connectionTypes { return types }
        return device.isWifi ? [.wifi] : [.usb]
    }

    @ViewBuilder
    private var connectionBadge: some View {
        let types = resolvedConnectionTypes
        let hasBoth = types.contains(.usb) && types.contains(.wifi)

        if hasBoth {
            HStack(spacing: 4) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor.opacity(0.85))
                Image(systemName: "wifi")
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75))
        } else if types.contains(.wifi) {
            HStack(spacing: 4) {
                Image(systemName: "wifi")
                    .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text("Wi-Fi")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("USB")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch device.statusColor {
        case .green:  return .green
        case .blue:   return .blue
        case .red:    return .red
        case .orange: return .orange
        case .gray:   return Color.secondary
        }
    }

    private var deviceStatusText: String {
        switch device.type {
        case .offline:      return "Offline"
        case .unauthorized: return "Tap to authorize in headset"
        case .unknown:      return "Unavailable"
        default:            return "Connected"
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .orange }
        return .red
    }

    private func storageBarGradient(fraction: Double) -> [Color] {
        if fraction < 0.7 { return [.green.opacity(0.8), .green] }
        if fraction < 0.9 { return [.orange.opacity(0.8), .orange] }
        return [.red.opacity(0.8), .red]
    }
}

