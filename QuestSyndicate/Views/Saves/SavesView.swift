import SwiftUI

// MARK: - Save Entry Model

struct SaveEntry: Identifiable {
    let id: String          // packageName
    let packageName: String
    let displayName: String
    var backupExists: Bool
    var backupDate: Date?
    var backupSizeBytes: Int64?
    var isBackingUp: Bool = false
    var isRestoring: Bool = false
    var statusMessage: String? = nil
    var errorMessage: String? = nil

    var backupSizeFormatted: String? {
        guard let bytes = backupSizeBytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var backupDateFormatted: String? {
        guard let date = backupDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - SavesViewModel

@Observable
@MainActor
final class SavesViewModel {
    var entries: [SaveEntry] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil

    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Load

    func loadEntries() async {
        guard let appState, let device = appState.selectedDevice else {
            entries = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // List all packages under /sdcard/Android/data/
            let packageList = try await appState.adb.shell(device.id, "ls /sdcard/Android/data/ 2>/dev/null")
            let packages = packageList
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.contains(".") }

            // Match packages against known library games for display names
            let libraryGames = await MainActor.run { appState.gameLibrary.games }
            let nameMap = Dictionary(uniqueKeysWithValues: libraryGames.map { ($0.packageName, $0.name) })

            var newEntries: [SaveEntry] = packages.map { pkg in
                let displayName = nameMap[pkg] ?? AppState.prettifyPackageName(pkg)
                let backupURL = backupDirectory(for: pkg)
                let backupExists = FileManager.default.fileExists(atPath: backupURL.path)
                let backupDate = backupExists
                    ? (try? FileManager.default.attributesOfItem(atPath: backupURL.path))?[.modificationDate] as? Date
                    : nil
                let backupSize = backupExists ? directorySize(at: backupURL) : nil

                return SaveEntry(
                    id: pkg,
                    packageName: pkg,
                    displayName: displayName,
                    backupExists: backupExists,
                    backupDate: backupDate,
                    backupSizeBytes: backupSize
                )
            }
            // Sort: backed-up first, then alphabetical within each group
            newEntries.sort {
                if $0.backupExists != $1.backupExists { return $0.backupExists }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            entries = newEntries
        } catch {
            errorMessage = "Failed to load save data: \(error.localizedDescription)"
        }
    }

    // MARK: - Backup

    func backup(packageName: String) async {
        guard let appState, let device = appState.selectedDevice else { return }
        guard let idx = entries.firstIndex(where: { $0.id == packageName }) else { return }

        entries[idx].isBackingUp = true
        entries[idx].errorMessage = nil
        entries[idx].statusMessage = "Checking save data…"

        let dest = backupDirectory(for: packageName)

        do {
            // Probe readability
            let countStr = try await appState.adb.shell(
                device.id,
                "find \"/sdcard/Android/data/\(packageName)\" -type f -readable 2>/dev/null | wc -l"
            )
            let count = Int(countStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard count > 0 else {
                entries[idx].statusMessage = nil
                entries[idx].errorMessage = "No readable save files found."
                entries[idx].isBackingUp = false
                return
            }

            entries[idx].statusMessage = "Backing up \(count) file\(count == 1 ? "" : "s")…"

            // Remove old backup if present
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            // Pull saves
            _ = try await appState.adb.pull(
                serial: device.id,
                remotePath: "/sdcard/Android/data/\(packageName)",
                localPath: dest
            )

            // Refresh entry
            let backupDate = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date
            let backupSize = directorySize(at: dest)

            entries[idx].backupExists = true
            entries[idx].backupDate = backupDate ?? Date()
            entries[idx].backupSizeBytes = backupSize
            entries[idx].statusMessage = "Backed up successfully"
            entries[idx].isBackingUp = false

            // Clear status message after a moment
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let i = entries.firstIndex(where: { $0.id == packageName }) {
                entries[i].statusMessage = nil
            }
        } catch {
            if let i = entries.firstIndex(where: { $0.id == packageName }) {
                entries[i].isBackingUp = false
                entries[i].statusMessage = nil
                entries[i].errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Restore

    func restore(packageName: String) async {
        guard let appState, let device = appState.selectedDevice else { return }
        guard let idx = entries.firstIndex(where: { $0.id == packageName }) else { return }

        let src = backupDirectory(for: packageName)
        guard FileManager.default.fileExists(atPath: src.path) else {
            entries[idx].errorMessage = "No backup found to restore."
            return
        }

        entries[idx].isRestoring = true
        entries[idx].errorMessage = nil
        entries[idx].statusMessage = "Restoring save data…"

        do {
            _ = try await appState.adb.push(
                serial: device.id,
                localPath: src,
                remotePath: "/sdcard/Android/data/\(packageName)"
            )
            entries[idx].statusMessage = "Restored successfully"
            entries[idx].isRestoring = false

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let i = entries.firstIndex(where: { $0.id == packageName }) {
                entries[i].statusMessage = nil
            }
        } catch {
            if let i = entries.firstIndex(where: { $0.id == packageName }) {
                entries[i].isRestoring = false
                entries[i].statusMessage = nil
                entries[i].errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Delete Backup

    func deleteBackup(packageName: String) {
        guard let idx = entries.firstIndex(where: { $0.id == packageName }) else { return }
        let dest = backupDirectory(for: packageName)
        try? FileManager.default.removeItem(at: dest)
        entries[idx].backupExists = false
        entries[idx].backupDate = nil
        entries[idx].backupSizeBytes = nil
    }

    // MARK: - Helpers

    private func backupDirectory(for packageName: String) -> URL {
        Constants.appSupportDirectory
            .appendingPathComponent("SaveBackups", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
    }

    private func directorySize(at url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total > 0 ? total : nil
    }
}

// MARK: - SavesView

struct SavesView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SavesViewModel? = nil
    @State private var searchText: String = ""
    @State private var showBackedUpOnly: Bool = false
    @State private var deleteTarget: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header toolbar
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Game Saves")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()

                Toggle("Backed up only", isOn: $showBackedUpOnly)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Button {
                    Task { await viewModel?.loadEntries() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(appState.selectedDevice == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if appState.selectedDevice == nil {
                noDeviceView
            } else if let vm = viewModel {
                if vm.isLoading {
                    loadingView
                } else if let err = vm.errorMessage {
                    errorView(err)
                } else if filteredEntries(vm).isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEntries(vm)) { entry in
                                SaveEntryRow(
                                    entry: entry,
                                    onBackup: { Task { await vm.backup(packageName: entry.packageName) } },
                                    onRestore: { Task { await vm.restore(packageName: entry.packageName) } },
                                    onDeleteBackup: { deleteTarget = entry.packageName }
                                )
                                Divider().padding(.leading, 56)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .searchable(text: $searchText, prompt: "Search games…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Delete Backup?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let pkg = deleteTarget {
                    viewModel?.deleteBackup(packageName: pkg)
                }
                deleteTarget = nil
            }
        } message: {
            if let pkg = deleteTarget {
                Text("This will permanently delete the local backup for \"\(AppState.prettifyPackageName(pkg))\". This cannot be undone.")
            }
        }
        .task(id: appState.selectedDevice?.id) {
            if viewModel == nil {
                viewModel = SavesViewModel(appState: appState)
            }
            await viewModel?.loadEntries()
        }
    }

    // MARK: - Filtered entries

    private func filteredEntries(_ vm: SavesViewModel) -> [SaveEntry] {
        var list = vm.entries
        if showBackedUpOnly { list = list.filter { $0.backupExists } }
        if !searchText.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.packageName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    // MARK: - Empty States

    private var noDeviceView: some View {
        VStack(spacing: 16) {
            Image(systemName: "visionpro.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Device Connected")
                .font(.title3).fontWeight(.semibold)
            Text("Connect your Quest to manage game saves.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading save data…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Retry") {
                Task { await viewModel?.loadEntries() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Save Data Found")
                .font(.title3).fontWeight(.semibold)
            Text("No games with save data were found on this device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - SaveEntryRow

private struct SaveEntryRow: View {
    let entry: SaveEntry
    let onBackup: () -> Void
    let onRestore: () -> Void
    let onDeleteBackup: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                if entry.isBackingUp || entry.isRestoring {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 32, height: 32)
                } else if entry.backupExists {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, height: 32)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let msg = entry.statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let err = entry.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if entry.backupExists {
                    HStack(spacing: 6) {
                        if let date = entry.backupDateFormatted {
                            Text("Backed up \(date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let size = entry.backupSizeFormatted {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No backup")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                // Backup button
                Button(action: onBackup) {
                    Image(systemName: entry.backupExists ? "arrow.clockwise" : "arrow.down.to.line")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(entry.backupExists ? "Re-backup save data" : "Backup save data")
                .disabled(entry.isBackingUp || entry.isRestoring)

                // Restore button — only available if backup exists
                if entry.backupExists {
                    Button(action: onRestore) {
                        Image(systemName: "arrow.up.to.line")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Restore save data to device")
                    .disabled(entry.isBackingUp || entry.isRestoring)

                    Button(action: onDeleteBackup) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete local backup")
                    .disabled(entry.isBackingUp || entry.isRestoring)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
