import SwiftUI

struct MirrorsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddMirror = false
    @State private var testingID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.mirrors.mirrors.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.mirrors.mirrors) { mirror in
                            MirrorCard(mirror: mirror, testingID: $testingID)
                                .environment(appState)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Mirrors")
        .sheet(isPresented: $showAddMirror) {
            AddMirrorSheet().environment(appState)
        }
    }

    private var toolbar: some View {
        HStack {
            if let active = appState.mirrors.activeMirror {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Active: \(active.name)").font(.caption).foregroundStyle(.secondary)
                }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassClear(cornerRadius: 6)
            }
            Spacer()

            Button {
                Task { await appState.mirrors.testAllMirrors() }
            } label: {
                Label("Test All", systemImage: "antenna.radiowaves.left.and.right").font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(appState.mirrors.mirrors.isEmpty || testingID != nil)

            Button { showAddMirror = true } label: {
                Label("Add Mirror", systemImage: "plus").font(.callout)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Mirrors").font(.title2).fontWeight(.semibold)
            Text("Add an rclone mirror configuration to enable uploads.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button("Add Mirror") { showAddMirror = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Mirror Card
struct MirrorCard: View {
    @Environment(AppState.self) private var appState
    let mirror: Mirror
    @Binding var testingID: String?

    private var isActive: Bool { appState.mirrors.activeMirror?.id == mirror.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mirror.name).font(.callout).fontWeight(.semibold)
                    Text(mirror.config.type).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                // Test status badge
                testStatusBadge

                HStack(spacing: 8) {
                    Button {
                        Task { await doTest() }
                    } label: {
                        if testingID == mirror.id {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(testingID != nil).help("Test connection")

                    if isActive {
                        Button("Deactivate") { appState.mirrors.clearActiveMirror() }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button("Set Active") { appState.mirrors.setActiveMirror(id: mirror.id) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    Button(role: .destructive) {
                        appState.mirrors.removeMirror(id: mirror.id)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain).help("Remove mirror")
                }
            }

            if !mirror.config.host.isEmpty {
                Text(mirror.config.host).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.separatorColor.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var testStatusBadge: some View {
        switch mirror.testStatus {
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                Text("OK").font(.caption).foregroundStyle(.green)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .glassTinted(.green, cornerRadius: 5)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 12))
                Text("Failed").font(.caption).foregroundStyle(.red)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .glassTinted(.red, cornerRadius: 5)
        case .testing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .untested:
            EmptyView()
        }
    }

    private func doTest() async {
        testingID = mirror.id
        _ = await appState.mirrors.testMirror(id: mirror.id)
        testingID = nil
    }
}

// MARK: - Add Mirror Sheet
struct AddMirrorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var configText = ""
    @State private var error: String? = nil
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add rclone Mirror").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your rclone config section below:").font(.subheadline).foregroundStyle(.secondary)

                TextEditor(text: $configText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separatorColor, lineWidth: 1))
                    .cornerRadius(6)

                Text("Example:").font(.caption).foregroundStyle(.secondary)
                Text("[mymirror]\ntype = ftp\nhost = 192.168.1.50\nuser = vrp\npass = xxxx")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(8).background(Color.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if let err = error { Text(err).font(.caption).foregroundStyle(.red) }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                    Button("Add Mirror") {
                        Task { await addMirror() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 420)
    }

    private func addMirror() async {
        isAdding = true
        error = nil
        let success = await appState.mirrors.addMirror(configContent: configText)
        if success { dismiss() } else { error = "Invalid rclone config format." }
        isAdding = false
    }
}
