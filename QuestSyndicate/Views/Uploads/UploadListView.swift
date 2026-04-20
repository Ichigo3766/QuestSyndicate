import SwiftUI

struct UploadListView: View {
    @Environment(AppState.self) private var appState
    @State private var showCandidates = false

    private var activeItems: [UploadItem] { appState.uploads.queue.filter { $0.status.isActive } }
    private var queuedItems: [UploadItem] { appState.uploads.queue.filter { $0.status == .queued } }
    private var errorItems: [UploadItem] { appState.uploads.queue.filter { $0.status == .error || $0.status == .cancelled } }
    private var completedItems: [UploadItem] { appState.uploads.queue.filter { $0.status == .completed } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.uploads.queue.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if !activeItems.isEmpty   { uploadSection("Active (\(activeItems.count))", items: activeItems) }
                        if !queuedItems.isEmpty   { uploadSection("Queued (\(queuedItems.count))", items: queuedItems) }
                        if !errorItems.isEmpty    { uploadSection("Failed / Cancelled (\(errorItems.count))", items: errorItems) }
                        if !completedItems.isEmpty { uploadSection("Completed (\(completedItems.count))", items: completedItems) }
                    }
                }
            }
        }
        .navigationTitle("Uploads")
        .sheet(isPresented: $showCandidates) {
            UploadCandidateSheet().environment(appState)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let name = appState.mirrors.activeMirror?.name {
                HStack(spacing: 6) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text("Mirror: \(name)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.surfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("No mirror selected").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.surfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            Button { showCandidates = true } label: {
                Label("Upload from Device", systemImage: "arrow.up.circle").font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.selectedDevice == nil)
            .help(appState.selectedDevice == nil ? "Connect a device first" : "Upload game from device")

            if !completedItems.isEmpty || !errorItems.isEmpty {
                Button(role: .destructive) { clearFinished() } label: {
                    Label("Clear Finished", systemImage: "trash").font(.callout)
                }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func uploadSection(_ title: String, items: [UploadItem]) -> some View {
        Section {
            ForEach(items) { item in
                UploadItemRow(item: item).environment(appState)
                Divider().padding(.leading, 16)
            }
        } header: {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(.bar)
        }
    }

    private func clearFinished() {
        let toRemove = appState.uploads.queue.filter { $0.status == .completed || $0.status == .error || $0.status == .cancelled }
        for item in toRemove { appState.uploads.removeFromQueue(packageName: item.packageName) }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Uploads").font(.title2).fontWeight(.semibold)
            Text("Connect a device and tap \"Upload from Device\" to share a game.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Upload Item Row
struct UploadItemRow: View {
    @Environment(AppState.self) private var appState
    let item: UploadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status.color).font(.system(size: 18)).frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.gameName).font(.callout).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if item.status.isActive {
                        Text(item.statusDescription).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if item.status.isActive {
                    ProgressView(value: item.progress / 100.0).progressViewStyle(.linear).tint(item.status.color)
                    Text("\(Int(item.progress))%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(item.statusDescription).font(.caption)
                        .foregroundStyle(item.status == .error ? .red : .secondary).lineLimit(2)
                }
            }

            if item.status == .queued || item.status.isActive {
                Button { appState.uploads.cancelUpload(packageName: item.packageName) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Cancel")
            }
            if item.status == .completed || item.status == .error || item.status == .cancelled {
                Button(role: .destructive) { appState.uploads.removeFromQueue(packageName: item.packageName) } label: {
                    Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(.red)
                }.buttonStyle(.plain).help("Remove")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
    }
}

// MARK: - Upload Candidate Sheet
struct UploadCandidateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var packages: [PackageInfo] = []
    @State private var isLoading = true
    @State private var selectedIDs = Set<PackageInfo.ID>()
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload from Device").font(.headline)
                    if let device = appState.selectedDevice {
                        Text(device.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding()
            Divider()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning installed packages…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if packages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No third-party packages found.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(packages, selection: $selectedIDs) { pkg in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pkg.packageName).font(.callout).fontWeight(.medium)
                        }
                        Spacer()
                        Text("v\(pkg.versionCode)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Upload Selected") { enqueueSelected(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty || appState.mirrors.activeMirror == nil)
            }
            .padding()
        }
        .frame(width: 480, height: 480)
        .task { await loadPackages() }
    }

    private func loadPackages() async {
        guard let device = appState.selectedDevice else {
            error = "No device connected."
            isLoading = false
            return
        }
        let all = (try? await appState.adb.getInstalledPackages(serial: device.id)) ?? []
        packages = all.filter { $0.isThirdParty }
        isLoading = false
    }

    private func enqueueSelected() {
        guard let device = appState.selectedDevice,
              let mirror = appState.mirrors.activeMirror else { return }
        let selected = packages.filter { selectedIDs.contains($0.id) }
        for pkg in selected {
            appState.uploads.addToQueue(
                packageName: pkg.packageName,
                gameName: pkg.packageName,
                versionCode: pkg.versionCode,
                deviceId: device.id
            )
        }
        _ = mirror // mirrorId stored per-item not needed here; upload service uses configured remote
    }
}
