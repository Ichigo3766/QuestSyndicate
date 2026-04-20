import SwiftUI
import UniformTypeIdentifiers

// MARK: - SetupWelcomeSheet
//
// Shown automatically on first launch (or whenever vrpConfig is nil).
// Guides the user through pasting their vrp-public.json to configure the app.

struct SetupWelcomeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var serverJson = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var isDraggingOver = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: "visionpro")
                    .font(.system(size: 52))
                    .foregroundStyle(.primary)
                    .padding(.top, 32)

                Text("Welcome to QuestSyndicate")
                    .font(.title2).fontWeight(.bold)

                Text("To get started, paste the contents of your **vrp-public.json** configuration file below.\nThis gives the app access to the VRP game library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.bottom, 24)

            Divider()

            // ── JSON Input ───────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("vrp-public.json", systemImage: "doc.text")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    if !serverJson.isEmpty {
                        Button {
                            serverJson = ""
                            saveError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ZStack {
                    // Editor
                    TextEditor(text: $serverJson)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 160)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isDraggingOver ? Color.accentColor : Color(NSColor.separatorColor),
                                    lineWidth: isDraggingOver ? 2 : 1
                                )
                        )
                        // Allow dropping a .json file directly
                        .onDrop(of: [.fileURL, .text, .plainText], isTargeted: $isDraggingOver) { providers in
                            loadDroppedJSON(providers: providers)
                        }

                    // Placeholder
                    if serverJson.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("Paste JSON here or drop the file")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        .allowsHitTesting(false)
                    }
                }

                if let err = saveError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 20)

            // ── Actions ──────────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button("Skip for Now") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .help("You can configure VRP later in Settings → VRP Config")

                Spacer()

                Button(action: pasteFromClipboard) {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                Button("Save & Continue") {
                    saveAndContinue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 28)
        }
        .frame(width: 540)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let str = NSPasteboard.general.string(forType: .string) {
            serverJson = str
            saveError = nil
        }
    }

    private func saveAndContinue() {
        isSaving = true
        saveError = nil

        let trimmed = serverJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            saveError = "Invalid text encoding."
            isSaving = false
            return
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["baseUri"] != nil else {
                throw NSError(domain: "QS", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "JSON must contain a 'baseUri' field."])
            }
            try data.write(to: Constants.serverInfoPath)
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            return
        }

        // Re-initialize library so config is picked up immediately
        Task {
            await appState.gameLibrary.initialize()
            appState.configurePipeline()
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }

    private func loadDroppedJSON(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Try loading as a file URL first
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    }
                    if let url, let str = try? String(contentsOf: url, encoding: .utf8) {
                        DispatchQueue.main.async {
                            serverJson = str
                            saveError = nil
                        }
                    }
                }
                return true
            }
            // Try loading as plain text
            if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
                    if let str = item as? String {
                        DispatchQueue.main.async {
                            serverJson = str
                            saveError = nil
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
