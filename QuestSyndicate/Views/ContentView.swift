import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    // Drag-and-drop install state
    @State private var isDropTargeted = false
    @State private var dropInstallProgress: DropInstallProgress? = nil

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.prominentDetail)
        .alert("Error", isPresented: $appState.showAlert, presenting: appState.alertMessage) { _ in
            Button("OK") {}
        } message: { msg in
            Text(msg)
        }
        .task {
            await appState.start()
        }
        // ── Manual file install from page header "Install APK" button ────────
        .onReceive(NotificationCenter.default.publisher(for: .installManualFiles)) { note in
            guard let urls = note.object as? [URL], !urls.isEmpty else { return }
            Task { @MainActor in
                await installDroppedURLs(urls)
            }
        }
        // ── Global drag-and-drop target ──────────────────────────────────────
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        // Drop highlight ring
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            }
        }
        // Drop install progress toast
        .overlay(alignment: .bottom) {
            if let progress = dropInstallProgress {
                DropInstallToast(progress: progress) {
                    dropInstallProgress = nil
                }
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: dropInstallProgress != nil)
            }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedTab {
        case .library:
            GameTableView()
        case .downloads:
            DownloadListView()
        case .terminal:
            ADBTerminalView()
                .environment(appState)
        }
    }

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        // Require a connected device
        guard appState.selectedDevice != nil else {
            appState.showError("No device connected. Connect your Quest before dropping files to install.")
            return false
        }

        // P1-8: Use structured concurrency instead of DispatchGroup
        Task { @MainActor in
            var urls: [URL] = []
            await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                    continuation.resume(returning: url)
                                } else if let url = item as? URL {
                                    continuation.resume(returning: url)
                                } else {
                                    continuation.resume(returning: nil)
                                }
                            }
                        }
                    }
                }
                for await url in group {
                    if let url { urls.append(url) }
                }
            }
            guard !urls.isEmpty else { return }
            await installDroppedURLs(urls)
        }
        return true
    }

    // MARK: - Install Dropped Files

    @MainActor
    private func installDroppedURLs(_ urls: [URL]) async {
        guard let device = appState.selectedDevice else { return }

        var progress = DropInstallProgress(
            files: urls.map { $0.lastPathComponent },
            status: "Installing…",
            percent: nil,
            isComplete: false
        )
        dropInstallProgress = progress

        var succeeded = 0
        var lastError: String? = nil

        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            do {
                if isDir.boolValue {
                    // Directory dropped — treat as an extracted game folder (APK + OBB inside)
                    let folderName = url.deletingPathExtension().lastPathComponent
                    progress.status = "Installing \(folderName)…"
                    progress.percent = nil
                    dropInstallProgress = progress

                    // Detect packageName from directory contents (recursive search)
                    let packageName = detectPackageName(in: url) ?? folderName
                    _ = try await appState.installation.install(
                        extractedDirectory: url,
                        packageName: packageName,
                        deviceSerial: device.id,
                        onStatus: { msg in
                            Task { @MainActor in
                                progress.status = msg
                                dropInstallProgress = progress
                            }
                        },
                        onProgress: { pct in
                            Task { @MainActor in
                                progress.percent = pct
                                dropInstallProgress = progress
                            }
                        }
                    )
                    succeeded += 1
                } else if url.pathExtension.lowercased() == "apk" {
                    // Single APK file — install directly
                    progress.status = "Installing \(url.lastPathComponent)…"
                    progress.percent = nil
                    dropInstallProgress = progress
                    _ = try await appState.installation.installManualAPK(apkPath: url, deviceSerial: device.id)
                    succeeded += 1
                } else {
                    lastError = "Unsupported file type: \(url.pathExtension). Drop an .apk or a game folder."
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        // Refresh library installed state
        appState.refreshInstalledStatus()

        // Update toast to final state
        progress.percent = nil
        if let err = lastError, succeeded == 0 {
            progress.status = "Failed: \(err)"
            progress.isError = true
        } else if let err = lastError {
            progress.status = "\(succeeded) installed, some errors: \(err)"
            progress.isComplete = true
        } else {
            progress.status = succeeded == 1
                ? "\(urls.first?.deletingPathExtension().lastPathComponent ?? "App") installed!"
                : "\(succeeded) apps installed!"
            progress.isComplete = true
        }
        dropInstallProgress = progress

        // Auto-dismiss after 4 seconds
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        dropInstallProgress = nil
    }

    /// Detects an Android package name by inspecting the directory structure.
    /// P1-9: `nonisolated` — pure file-path inspection, no UI access required.
    ///
    /// Search order (most reliable first):
    ///  1. An APK file whose name looks like a reverse-domain package (e.g. `io.xrworkout.vrworkout.apk`)
    ///     — searched recursively so nested extraction layouts are handled.
    ///  2. A subdirectory whose name contains two or more dots (e.g. `io.xrworkout.vrworkout/`)
    ///  3. A subdirectory under `Android/obb/<packageName>/` at any depth
    private nonisolated func detectPackageName(in directory: URL) -> String? {
        let fm = FileManager.default

        // 1. APK filename — VRP archives name the APK after the package (search recursively)
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "apk" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    // A valid package name has at least 2 dots (e.g. io.xrworkout.vrworkout)
                    if stem.filter({ $0 == "." }).count >= 2 {
                        return stem
                    }
                }
            }
        }

        // 2. Any subdirectory whose name looks like a package name
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    let name = url.lastPathComponent
                    if name.filter({ $0 == "." }).count >= 2 {
                        return name
                    }
                }
            }
        }

        // 3. Android/obb/<packageName> subfolder at any depth
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let comps = url.pathComponents
                if comps.count >= 3,
                   comps[comps.count - 2].lowercased() == "obb",
                   comps[comps.count - 3].lowercased() == "android" {
                    return url.lastPathComponent
                }
            }
        }

        return nil
    }
}

// MARK: - Drop Install Progress Model

struct DropInstallProgress: Identifiable, Equatable {
    let id = UUID()
    var files: [String]
    var status: String
    var percent: Double?
    var isComplete: Bool = false
    var isError: Bool = false

    static func == (lhs: DropInstallProgress, rhs: DropInstallProgress) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.percent == rhs.percent
    }
}

// MARK: - Drop Install Toast

struct DropInstallToast: View {
    let progress: DropInstallProgress
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if progress.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else if progress.isError {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            } else {
                ProgressView().scaleEffect(0.85)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Manual Install")
                    .font(.callout).fontWeight(.semibold)
                Text(progress.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                // Show determinate progress bar when we have a percentage
                if let pct = progress.percent, !progress.isComplete, !progress.isError {
                    ProgressView(value: pct / 100.0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .animation(.easeInOut(duration: 0.15), value: pct)
                }
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 400)
        .glassCard(cornerRadius: 12)
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
