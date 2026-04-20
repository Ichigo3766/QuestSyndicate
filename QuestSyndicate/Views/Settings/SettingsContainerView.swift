//
//  SettingsContainerView.swift
//  QuestSyndicate
//
//  Redesigned settings UI — clean, user-friendly, fully functional.
//

import SwiftUI
import AppKit

// MARK: - SettingsContainerView

struct SettingsContainerView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general      = "General"
        case server       = "Server"
        case blacklist    = "Blacklist"
        case tools        = "Tools"
        case about        = "About"

        var systemImage: String {
            switch self {
            case .general:   return "gear"
            case .server:    return "server.rack"
            case .blacklist: return "nosign"
            case .tools:     return "wrench.and.screwdriver"
            case .about:     return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Custom tab bar ────────────────────────────────────────────────
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 16, weight: .medium))
                            Text(tab.rawValue)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.12))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            // ── Tab content ───────────────────────────────────────────────────
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                        .environment(appState)
                case .server:
                    ServerSettingsView()
                        .environment(appState)
                case .blacklist:
                    BlacklistSettingsView()
                        .environment(appState)
                case .tools:
                    ToolsSettingsView()
                        .environment(appState)
                case .about:
                    AboutSettingsView()
                        .environment(appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 580)
    }
}

// MARK: - Shared Helpers

/// A styled row used inside Form sections.
private struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Content

    var body: some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, subtitle != nil ? 4 : 0)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("downloadPath")  private var downloadPath = Constants.vrpDataDirectory.path
    @AppStorage("colorScheme")   private var colorSchemeRaw = "system"
    @AppStorage("autoInstallAfterDownload") private var autoInstall = true
    @AppStorage("autoDeleteAfterInstall")   private var autoDelete  = true

    @State private var thumbnailCacheSize: String = "Calculating…"
    @State private var isClearingCache = false

    var body: some View {
        Form {
            // ── Download Location ─────────────────────────────────────────────
            Section {
                SettingsRow(
                    title: "Download Folder",
                    subtitle: "Game archives are stored here while downloading and extracting."
                ) {
                    HStack(spacing: 6) {
                        Text(condensedPath(downloadPath))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .trailing)
                        Button("Change…") { browseDownloadPath() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: downloadPath)]
                            )
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Show in Finder")
                    }
                }
            } header: {
                Label("Download Location", systemImage: "arrow.down.to.line")
                    .font(.headline)
            }

            // ── Appearance ────────────────────────────────────────────────────
            Section {
                SettingsRow(title: "Color Scheme") {
                    Picker("", selection: $colorSchemeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            } header: {
                Label("Appearance", systemImage: "paintbrush")
                    .font(.headline)
            }

            // ── Install Behavior ──────────────────────────────────────────────
            Section {
                Toggle(isOn: $autoInstall) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-install after download")
                        Text("Automatically installs a game to your Quest as soon as it finishes downloading.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $autoDelete) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete archive after installing")
                        Text("Removes the downloaded .7z file once the game is installed, freeing up disk space.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Install Behavior", systemImage: "arrow.down.circle")
                    .font(.headline)
            }

            // ── Storage ───────────────────────────────────────────────────────
            Section {
                SettingsRow(
                    title: "Thumbnail Cache",
                    subtitle: "Cached cover art for the game library."
                ) {
                    HStack(spacing: 8) {
                        Text(thumbnailCacheSize)
                            .font(.callout).foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button(isClearingCache ? "Clearing…" : "Clear") {
                            clearThumbnailCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isClearingCache)
                    }
                }

                SettingsRow(
                    title: "App Support Folder",
                    subtitle: "All app data — configs, downloads, binaries."
                ) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Constants.appSupportDirectory])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .onChange(of: downloadPath) { _, newPath in
            appState.pipeline.setDownloadPath(newPath)
        }
        .task { await computeCacheSize() }
    }

    // MARK: - Helpers

    private func browseDownloadPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: downloadPath)
        panel.prompt = "Select Folder"
        panel.message = "Choose where downloaded game archives are stored."
        if panel.runModal() == .OK, let url = panel.url {
            downloadPath = url.path
        }
    }

    private func condensedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func computeCacheSize() async {
        let result = await Task.detached(priority: .utility) {
            let cacheDir = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first?.appendingPathComponent("QuestSyndicate/thumbnails")

            guard let dir = cacheDir,
                  let enumerator = FileManager.default.enumerator(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return "0 MB"
            }

            var total: Int64 = 0
            while let obj = enumerator.nextObject(), let fileURL = obj as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }

            let mb = Double(total) / 1_000_000
            if mb < 0.1 {
                return "Empty"
            } else if mb < 1000 {
                return String(format: "%.1f MB", mb)
            } else {
                return String(format: "%.2f GB", mb / 1000)
            }
        }.value
        thumbnailCacheSize = result
    }

    private func clearThumbnailCache() {
        isClearingCache = true
        Task {
            await ThumbnailCacheService.shared.purgeMemoryCache()
            await computeCacheSize()
            isClearingCache = false
        }
    }
}

// MARK: - Server Settings

struct ServerSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var baseUri    = ""
    @State private var password   = ""
    @State private var showPass   = false
    @State private var isSaving   = false
    @State private var saveResult: SaveResult? = nil
    @State private var showAdvanced = false
    @State private var rawJson    = ""
    @State private var isSyncing  = false

    enum SaveResult {
        case success, failure(String)
    }

    var body: some View {
        Form {
            // ── Connection ────────────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    TextField("https://go.srcdl1.xyz/", text: $baseUri)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("The VRP server address. Leave as default unless you're using a custom mirror.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    HStack {
                        if showPass {
                            TextField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        Button {
                            showPass.toggle()
                        } label: {
                            Image(systemName: showPass ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showPass ? "Hide password" : "Show password")
                    }
                    Text("Used to decrypt downloaded game archives. Required for installation.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // Feedback
                if let result = saveResult {
                    switch result {
                    case .success:
                        Label("Saved successfully!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    case .failure(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                }

                HStack {
                    Spacer()
                    Button(isSaving ? "Saving…" : "Save Configuration") {
                        saveSimple()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || baseUri.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
                }
            } header: {
                HStack {
                    Label("VRP Server Connection", systemImage: "server.rack")
                        .font(.headline)
                    Spacer()
                    configStatusBadge
                }
            }

            // ── Sync ──────────────────────────────────────────────────────────
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Library")
                            .font(.callout)
                        if let lastSync = appState.gameLibrary.vrpConfig?.lastSync {
                            Text("Last synced \(lastSync, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Never synced — tap Sync Now to download the game list.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text("\(appState.gameLibrary.games.count) games")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                    if isSyncing {
                        ProgressView().scaleEffect(0.7).padding(.leading, 4)
                    }
                    Button(isSyncing ? "Syncing…" : "Sync Now") {
                        syncNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSyncing || appState.gameLibrary.isLoading)
                }
            } header: {
                Label("Game Library", systemImage: "square.grid.2x2")
                    .font(.headline)
            } footer: {
                Text("Sync downloads the latest game list from the VRP server. This uses your internet connection and may take a moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Advanced ─────────────────────────────────────────────────────
            Section {
                DisclosureGroup("Advanced — Raw JSON Editor", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You can paste a full vrp-public.json file here. This overwrites the fields above.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $rawJson)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 100)
                            .scrollContentBackground(.hidden)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                        HStack {
                            Button("Paste from Clipboard") {
                                if let s = NSPasteboard.general.string(forType: .string) { rawJson = s }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            Button("Apply JSON") { saveFromJson() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(rawJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadCurrentConfig() }
    }

    // MARK: - Status badge

    @ViewBuilder
    private var configStatusBadge: some View {
        if appState.gameLibrary.vrpConfig != nil {
            Label("Configured", systemImage: "checkmark.circle.fill")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassCapsuleTinted(.green)
        } else {
            Label("Not Set", systemImage: "exclamationmark.circle")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassCapsuleTinted(.orange)
        }
    }

    // MARK: - Actions

    private func loadCurrentConfig() {
        if let data = try? Data(contentsOf: Constants.serverInfoPath),
           let config = try? JSONDecoder().decode(VRPConfig.self, from: data) {
            baseUri  = config.baseUri
            password = config.password
            if let str = String(data: data, encoding: .utf8) { rawJson = str }
        } else if let config = appState.gameLibrary.vrpConfig {
            baseUri  = config.baseUri
            password = config.password
        }
    }

    private func saveSimple() {
        let cleanBase = baseUri.trimmingCharacters(in: .whitespaces)
        guard !cleanBase.isEmpty else { return }

        isSaving = true
        saveResult = nil

        let config = VRPConfig(baseUri: cleanBase, password: password.trimmingCharacters(in: .whitespaces))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: Constants.serverInfoPath)
            saveResult = .success
            syncNow()
        } catch {
            saveResult = .failure(error.localizedDescription)
        }
        isSaving = false

        // Auto-dismiss success after 3s
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .success = saveResult { saveResult = nil }
        }
    }

    private func saveFromJson() {
        let trimmed = rawJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return }

        do {
            let config = try JSONDecoder().decode(VRPConfig.self, from: data)
            baseUri  = config.baseUri
            password = config.password
            saveSimple()
        } catch {
            saveResult = .failure("Invalid JSON: \(error.localizedDescription)")
        }
    }

    private func syncNow() {
        isSyncing = true
        Task {
            let mirrorPath   = appState.mirrors.getActiveMirrorConfigPath()
            let mirrorRemote = appState.mirrors.getActiveMirrorRemoteName()
            do {
                try await appState.gameLibrary.forceSync(
                    mirrorConfigPath: mirrorPath,
                    activeMirrorRemote: mirrorRemote
                )
                appState.configurePipeline()
                appState.refreshInstalledStatus()
            } catch {
                saveResult = .failure("Sync failed: \(error.localizedDescription)")
                // Auto-dismiss error after 8s
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if case .failure = saveResult { saveResult = nil }
                }
            }
            isSyncing = false
        }
    }
}

// MARK: - Blacklist Settings

struct BlacklistSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var customEntries: [BlacklistEntry] = []
    @State private var newPackageName = ""
    @State private var newVersionCode = ""
    @State private var showAddRow     = false

    var body: some View {
        Form {
            // ── Custom entries ────────────────────────────────────────────────
            Section {
                if customEntries.isEmpty && !showAddRow {
                    VStack(spacing: 10) {
                        Image(systemName: "nosign")
                            .font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text("No hidden games")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Games you add here will be hidden from the library.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(customEntries, id: \.packageName) { entry in
                        HStack {
                            Image(systemName: "nosign")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.packageName)
                                    .font(.callout.monospaced())
                                Text(entry.version == .any ? "All versions" : "Specific version only")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                withAnimation { removeEntry(entry) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from blacklist")
                        }
                    }
                }

                if showAddRow {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        TextField("com.example.game", text: $newPackageName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        TextField("Version (optional)", text: $newVersionCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Button("Add") { addEntry() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newPackageName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            withAnimation { showAddRow = false; newPackageName = ""; newVersionCode = "" }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Label("Hidden Games", systemImage: "eye.slash")
                        .font(.headline)
                    Spacer()
                    Button {
                        withAnimation { showAddRow = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(showAddRow)
                }
            } footer: {
                Text("Enter the package name (e.g. com.developer.gamename). You can find this in the game details sheet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Server Blacklist ──────────────────────────────────────────────
            Section {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VRP Server Blacklist")
                            .font(.callout)
                        Text("Maintained by VRP — contains games that should not be distributed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(appState.gameLibrary.serverBlacklistCount) entries")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassCapsule()
                }
            } header: {
                Label("Server Blacklist", systemImage: "shield")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadEntries() }
    }

    // MARK: - Helpers

    private func loadEntries() {
        guard let data = try? Data(contentsOf: Constants.customBlacklistPath),
              let loaded = try? JSONDecoder().decode([BlacklistEntry].self, from: data)
        else { return }
        customEntries = loaded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customEntries) {
            try? data.write(to: Constants.customBlacklistPath)
        }
        Task { await appState.gameLibrary.reloadBlacklist() }
    }

    private func addEntry() {
        let pkg = newPackageName.trimmingCharacters(in: .whitespaces)
        guard !pkg.isEmpty else { return }
        let version: BlacklistEntry.BlacklistVersion
        if let v = Int(newVersionCode.trimmingCharacters(in: .whitespaces)), !newVersionCode.isEmpty {
            version = .specific(v)
        } else {
            version = .any
        }
        customEntries.append(BlacklistEntry(packageName: pkg, version: version))
        newPackageName = ""
        newVersionCode = ""
        showAddRow = false
        save()
    }

    private func removeEntry(_ entry: BlacklistEntry) {
        customEntries.removeAll { $0.packageName == entry.packageName }
        save()
    }
}

// MARK: - Tools Settings

struct ToolsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                toolCard(
                    name: "ADB",
                    subtitle: "Android Debug Bridge — communicates with your Quest over USB or Wi-Fi",
                    icon: "cable.connector",
                    path: Constants.adbPath,
                    status: appState.dependencies.adbStatus
                )
                Divider().padding(.leading, 44)
                toolCard(
                    name: "rclone",
                    subtitle: "Handles downloading game archives from the VRP server",
                    icon: "arrow.down.circle",
                    path: Constants.rclonePath,
                    status: appState.dependencies.rcloneStatus
                )
                Divider().padding(.leading, 44)
                toolCard(
                    name: "7-Zip (7zz)",
                    subtitle: "Extracts downloaded archives — required for installation",
                    icon: "archivebox",
                    path: Constants.sevenZipPath,
                    status: appState.dependencies.sevenZipStatus
                )
            } header: {
                Label("Required Tools", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
            } footer: {
                Text("These tools are downloaded automatically on first launch. They are stored in the app support folder and are not system-wide installs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        Task { await appState.dependencies.setup() }
                    } label: {
                        Label("Re-download All Tools", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.dependencies.isSettingUp)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Constants.binDirectory])
                    } label: {
                        Label("Reveal Tools Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                if let err = appState.dependencies.setupError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Label("Actions", systemImage: "gearshape.2")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func toolCard(
        name: String,
        subtitle: String,
        icon: String,
        path: URL,
        status: DependencyReadiness
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .glassCard(cornerRadius: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Text(condensedPath(path.path))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }

            Spacer()

            statusBadge(status)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: DependencyReadiness) -> some View {
        switch status {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassCapsuleTinted(.green)

        case .checking:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65)
                Text("Checking").font(.caption)
            }
            .foregroundStyle(.secondary)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 72)
                    .tint(Color.accentColor)
                Text("\(Int(progress))%")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .glassCapsuleTinted(.red)
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }

        case .unknown:
            Label("Not checked", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func condensedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    @State private var showUpdateSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // ── App icon + name ───────────────────────────────────────────────
            VStack(spacing: 14) {
                Group {
                    if let icon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 88, height: 88)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

                VStack(spacing: 4) {
                    Text("QuestSyndicate")
                        .font(.title2).fontWeight(.bold)
                    Text("Version \(version) (\(build))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32)

            Divider().padding(.vertical, 20).padding(.horizontal, 40)

            // ── Description ───────────────────────────────────────────────────
            Text("A native macOS app for managing Meta Quest VR devices. Download, sideload, and manage your game library all in one place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            // ── Update status ─────────────────────────────────────────────────
            updateStatusView
                .padding(.top, 16)

            // ── Links ─────────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Link(destination: Constants.githubRepoPageURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.bordered)

                Link(destination: URL(string: "https://developer.android.com/studio/command-line/adb")!) {
                    Label("ADB Docs", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)

                Link(destination: URL(string: "https://sidequestvr.com")!) {
                    Label("SideQuest", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 14)

            Spacer()

            // ── Footer ────────────────────────────────────────────────────────
            Text("Made with ♥ for the Quest community")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showUpdateSheet) {
            UpdatePromptView(updateService: appState.updater)
        }
    }

    // MARK: - Update status row

    @ViewBuilder
    private var updateStatusView: some View {
        switch appState.updater.state {
        case .idle, .upToDate:
            Button {
                Task { await appState.updater.checkForUpdate() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

        case .checking:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Checking for updates…")
                    .font(.callout).foregroundStyle(.secondary)
            }

        case .available(let info):
            Button {
                showUpdateSheet = true
            } label: {
                Label("Update to v\(info.version)", systemImage: "arrow.down.circle.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)

        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(Color.accentColor)
                Text("\(Int(p * 100))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Installing…")
                    .font(.callout).foregroundStyle(.secondary)
            }

        case .failed(let msg):
            VStack(spacing: 6) {
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(msg)
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Retry") {
                    Task { await appState.updater.checkForUpdate() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
