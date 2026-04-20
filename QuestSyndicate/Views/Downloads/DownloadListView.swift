import SwiftUI
import UniformTypeIdentifiers

struct DownloadListView: View {
    @Environment(AppState.self) private var appState
    @State private var showManualInstall = false

    private var activeItems: [DownloadItem] { appState.pipeline.queue.filter { $0.status.isActive } }
    private var queuedItems: [DownloadItem] { appState.pipeline.queue.filter { $0.status == .queued } }
    private var errorItems: [DownloadItem] { appState.pipeline.queue.filter { $0.status == .error || $0.status == .installError || $0.status == .cancelled } }
    private var completedItems: [DownloadItem] { appState.pipeline.queue.filter { $0.status == .completed } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.pipeline.queue.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if !activeItems.isEmpty {
                            Section {
                                ForEach(activeItems) { item in
                                    DownloadItemRow(item: item)
                                        .id("\(item.id)-\(item.status.rawValue)")
                                        .environment(appState)
                                    Divider().padding(.leading, 16)
                                }
                            } header: { sectionHeader("Active (\(activeItems.count))") }
                        }
                        if !queuedItems.isEmpty {
                            Section {
                                ForEach(queuedItems) { item in
                                    DownloadItemRow(item: item)
                                        .id("\(item.id)-\(item.status.rawValue)")
                                        .environment(appState)
                                    Divider().padding(.leading, 16)
                                }
                            } header: { sectionHeader("Queued (\(queuedItems.count))") }
                        }
                        if !errorItems.isEmpty {
                            Section {
                                ForEach(errorItems) { item in
                                    DownloadItemRow(item: item)
                                        .id("\(item.id)-\(item.status.rawValue)")
                                        .environment(appState)
                                    Divider().padding(.leading, 16)
                                }
                            } header: { sectionHeader("Failed / Cancelled (\(errorItems.count))") }
                        }
                        if !completedItems.isEmpty {
                            Section {
                                ForEach(completedItems) { item in
                                    DownloadItemRow(item: item)
                                        .id("\(item.id)-\(item.status.rawValue)")
                                        .environment(appState)
                                    Divider().padding(.leading, 16)
                                }
                            } header: { sectionHeader("Completed (\(completedItems.count))") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .sheet(isPresented: $showManualInstall) {
            ManualInstallSheet().environment(appState)
        }
    }

    // MARK: - Toolbar
    private var toolbar: some View {
        HStack(spacing: 12) {
            SpeedLimitControl().environment(appState)
            Spacer()

            // Device indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.selectedDevice != nil ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(appState.selectedDevice?.displayName ?? "No device")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassClear(cornerRadius: 6)

            Button {
                showManualInstall = true
            } label: {
                Label("Manual Install", systemImage: "folder.badge.plus").font(.callout)
            }
            .buttonStyle(.bordered)

            if !completedItems.isEmpty || !errorItems.isEmpty {
                Button(role: .destructive) { clearFinished() } label: {
                    Label("Clear Finished", systemImage: "trash").font(.callout)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.bar)
    }

    private func clearFinished() {
        let toRemove = appState.pipeline.queue.filter {
            $0.status == .completed || $0.status == .error ||
            $0.status == .cancelled || $0.status == .installError
        }
        for item in toRemove { appState.pipeline.removeFromQueue(releaseName: item.releaseName) }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Downloads").font(.title2).fontWeight(.semibold)
            Text("Browse the library and tap Download to start.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Speed Limit Control
struct SpeedLimitControl: View {
    @Environment(AppState.self) private var appState
    @AppStorage("downloadSpeedLimit") private var storedLimit = 0
    @State private var speedText = ""
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer").foregroundStyle(.secondary).font(.system(size: 12))
            if isEditing {
                TextField("0 = unlimited", text: $speedText)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { applyLimit() }
                Button("Set") { applyLimit() }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button {
                    speedText = storedLimit > 0 ? String(storedLimit) : ""
                    isEditing = true
                } label: {
                    Text(storedLimit > 0 ? "\(storedLimit) MB/s" : "Unlimited")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
    }

    private func applyLimit() {
        let val = Int(speedText.trimmingCharacters(in: .whitespaces)) ?? 0
        storedLimit = val
        appState.pipeline.setSpeedLimit(val)
        isEditing = false
    }
}

// MARK: - Manual Install Sheet
struct ManualInstallSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var apkPath = ""
    @State private var obbPath = ""
    @State private var isInstalling = false
    @State private var installProgress: Double? = nil
    @State private var installStatus = ""
    @State private var error: String? = nil
    @State private var success = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manual APK Install").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("APK File").font(.subheadline).fontWeight(.semibold)
                    HStack {
                        TextField("Path to .apk file…", text: $apkPath).textFieldStyle(.roundedBorder)
                        Button("Browse") { browseAPK() }.buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("OBB Folder (optional)").font(.subheadline).fontWeight(.semibold)
                    HStack {
                        TextField("Path to OBB folder…", text: $obbPath).textFieldStyle(.roundedBorder)
                        Button("Browse") { browseOBB() }.buttonStyle(.bordered)
                    }
                    Text("The folder should be named after the package (e.g. com.example.game)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // Progress feedback while installing
                if isInstalling {
                    VStack(alignment: .leading, spacing: 4) {
                        if let pct = installProgress {
                            ProgressView(value: pct / 100.0)
                                .progressViewStyle(.linear)
                                .animation(.easeInOut(duration: 0.15), value: pct)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        if !installStatus.isEmpty {
                            Text(installStatus)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if let err = error { Text(err).font(.caption).foregroundStyle(.red) }
                if success { Label("Installed successfully!", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }

                HStack {
                    Spacer()
                    Button("Install") { Task { await doInstall() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(apkPath.isEmpty || isInstalling || appState.selectedDevice == nil)
                }
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func browseAPK() {
        let panel = NSOpenPanel()
        // `.apk` is not a registered UTType on macOS, so allowedContentTypes
        // would produce an empty filter and show nothing selectable.
        // Allow all files instead and validate the extension after selection.
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = []
        panel.title = "Select APK File"
        panel.message = "Choose an .apk file to install"
        if panel.runModal() == .OK, let url = panel.url {
            apkPath = url.path
        }
    }

    private func browseOBB() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { obbPath = url.path }
    }

    private func doInstall() async {
        guard let device = appState.selectedDevice else { return }
        isInstalling = true; error = nil; success = false
        installProgress = nil; installStatus = ""
        do {
            let apkURL = URL(fileURLWithPath: apkPath)

            // Install the APK (progress 0–100% if no OBB, 0–50% if OBB follows)
            let hasOBB = !obbPath.isEmpty
            let apkPhaseEnd: Double = hasOBB ? 50.0 : 100.0

            installStatus = "Installing \(apkURL.lastPathComponent)…"
            _ = try await appState.installation.installManualAPK(
                apkPath: apkURL,
                deviceSerial: device.id
            )
            installProgress = apkPhaseEnd

            // Push OBB folder if provided (progress 50–100%)
            if hasOBB {
                let obbURL = URL(fileURLWithPath: obbPath)
                // Use the OBB folder's own name as the package name — Android requires this.
                // Fall back to APK stem only if the folder name looks wrong.
                let folderName = obbURL.lastPathComponent
                let packageName = folderName.filter({ $0 == "." }).count >= 1
                    ? folderName
                    : apkURL.deletingPathExtension().lastPathComponent

                installStatus = "Pushing OBB data…"
                _ = try await appState.installation.copyOBBFolder(
                    folderPath: obbURL,
                    packageName: packageName,
                    deviceSerial: device.id
                )
                installProgress = 100
            }

            success = true
            appState.refreshInstalledStatus()
        } catch { self.error = error.localizedDescription }
        isInstalling = false
        installProgress = nil
        installStatus = ""
    }
}
