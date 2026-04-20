import SwiftUI
import WebKit

// MARK: - GameDetailSheet

struct GameDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let game: GameInfo

    @State private var notes: String? = nil
    @State private var trailerVideoId: String? = nil
    @State private var isLoadingMeta = true
    @State private var isInstalling = false
    @State private var installProgress: Double? = nil
    @State private var installStatusMsg = ""
    @State private var installError: String? = nil
    @State private var isUninstalling = false
    @State private var uninstallError: String? = nil
    @State private var showUninstallConfirm = false
    @State private var showReinstallConfirm = false

    private var downloadItem: DownloadItem? {
        appState.pipeline.queue.first { $0.releaseName == game.releaseName }
    }

    private var isInstalled: Bool {
        game.installStatus == .installed || game.installStatus == .updateAvailable || game.isDeviceOnly
    }

    // MARK: - Server thumbnail fallback
    private var serverThumbnailURL: URL? {
        guard let base = appState.gameLibrary.vrpConfig?.baseUri,
              !base.isEmpty else { return nil }
        let clean = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(clean)/.meta/thumbnails/\(game.packageName).jpg")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Hero banner
            heroBanner

            // Scrollable body
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {

                    // Main CTA + status
                    ctaSection

                    // Meta pills grid
                    if !game.isDeviceOnly {
                        metaGrid
                    }

                    // Device actions (when installed + device connected)
                    if isInstalled && appState.selectedDevice != nil {
                        deviceActionsSection
                    }

                    // Errors
                    if let err = installError   { errorBanner("Install failed: \(err)") }
                    if let err = uninstallError { errorBanner("Uninstall failed: \(err)") }

                    // Trailer
                    if let videoId = trailerVideoId {
                        trailerSection(videoId: videoId)
                    }

                    // Release notes
                    if let notes, !notes.isEmpty {
                        releaseNotesSection(notes: notes)
                    }

                    // Loading indicator
                    if isLoadingMeta {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading details…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 680, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .confirmationDialog(
            "Uninstall \(game.name)?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await performUninstall() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the app, OBB files, and data from \(appState.selectedDevice?.displayName ?? "your device").")
        }
        .confirmationDialog(
            "Re-install \(game.name)?",
            isPresented: $showReinstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-install") {
                appState.pipeline.addToQueue(game)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-download and re-install \(game.name). If files are already on disk, only the install step will run.")
        }
        .task { await loadMeta() }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            // Blurred background thumbnail
            AsyncThumbnailView(
                thumbnailPath: game.thumbnailPath,
                cornerRadius: 0,
                targetSize: CGSize(width: 680, height: 200),
                fallbackURL: serverThumbnailURL
            )
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .blur(radius: 18)
            .scaleEffect(1.12) // cover edges after blur
            .clipped()

            // Dark scrim so text is always readable
            LinearGradient(
                colors: [
                    .black.opacity(0.15),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content row
            HStack(alignment: .bottom, spacing: 16) {
                // Sharp thumbnail
                AsyncThumbnailView(
                    thumbnailPath: game.thumbnailPath,
                    cornerRadius: 16,
                    targetSize: CGSize(width: 320, height: 320),
                    fallbackURL: serverThumbnailURL
                )
                .frame(width: 110, height: 110)
                .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )

                // Name + package + status badge
                VStack(alignment: .leading, spacing: 6) {
                    statusPill
                    Text(game.name.isEmpty ? game.packageName : game.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                    Text(game.packageName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer()

                // Close button top-right
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.3), radius: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(height: 200)
        .clipped()
    }

    // MARK: - Status Pill

    @ViewBuilder
    private var statusPill: some View {
        if game.isDeviceOnly {
            pillBadge("Device Only", icon: "questionmark.circle.fill", color: .purple)
        } else {
            switch game.installStatus {
            case .installed:
                pillBadge("Installed", icon: "checkmark.circle.fill", color: .green)
            case .updateAvailable:
                pillBadge("Update Available", icon: "arrow.down.circle.fill", color: .orange)
            case .notInstalled:
                if downloadItem != nil {
                    pillBadge("In Queue", icon: "clock.fill", color: .white.opacity(0.8))
                } else {
                    pillBadge("Not Installed", icon: "circle", color: .white.opacity(0.5))
                }
            }
        }
    }

    private func pillBadge(_ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1))
    }

    // MARK: - CTA Section

    @ViewBuilder
    private var ctaSection: some View {
        if game.isDeviceOnly {
            // Device-only: no download available, just show info
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not in Library")
                        .font(.system(size: 15, weight: .semibold))
                    Text("This app is on your device but not in the VRP catalog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .glassCard(cornerRadius: 14)

        } else if let item = downloadItem {
            // In-queue / active download progress card
            downloadProgressCard(item: item)

        } else {
            // Default: Download / Re-download action card
            HStack(spacing: 14) {
                // Status icon
                ZStack {
                    Circle()
                        .fill(ctaIconColor.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: ctaIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ctaIconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(ctaTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(ctaSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appState.pipeline.addToQueue(game)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(game.installStatus == .updateAvailable ? "Update" : "Download")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassTinted(game.installStatus == .updateAvailable ? .orange : .accentColor, cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .glassCard(cornerRadius: 14)
        }
    }

    private var ctaIcon: String {
        switch game.installStatus {
        case .installed:       return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .notInstalled:    return "arrow.down.circle"
        }
    }

    private var ctaIconColor: Color {
        switch game.installStatus {
        case .installed:       return .green
        case .updateAvailable: return .orange
        case .notInstalled:    return .accentColor
        }
    }

    private var ctaTitle: String {
        switch game.installStatus {
        case .installed:       return "Installed"
        case .updateAvailable: return "Update Available"
        case .notInstalled:    return "Not Installed"
        }
    }

    private var ctaSubtitle: String {
        let size = game.formattedSize.isEmpty ? "" : " · \(game.formattedSize)"
        switch game.installStatus {
        case .installed:
            return "Version \(game.version)\(size)"
        case .updateAvailable:
            if let dvc = game.deviceVersionCode {
                return "Device: v\(dvc)  →  Latest: v\(game.version)\(size)"
            }
            return "Newer version available\(size)"
        case .notInstalled:
            return "Version \(game.version)\(size)"
        }
    }

    // MARK: - Download Progress Card

    @ViewBuilder
    private func downloadProgressCard(item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                // Animated progress ring
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 3)
                        .frame(width: 42, height: 42)
                    if item.status.isActive {
                        Circle()
                            .trim(from: 0, to: item.displayProgress / 100.0)
                            .stroke(item.status.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 42, height: 42)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: item.displayProgress)
                    }
                    Image(systemName: item.status.isActive ? "arrow.down" : statusIcon(item.status))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.status.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.statusDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if item.status.isActive {
                        Text("\(Int(item.displayProgress))% complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                // Install button when download is done
                if item.status == .completed {
                    if isInstalling {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let pct = installProgress {
                                ProgressView(value: pct / 100.0)
                                    .progressViewStyle(.linear)
                                    .frame(width: 100)
                                    .animation(.easeInOut(duration: 0.15), value: pct)
                                Text("\(Int(pct))%")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                ProgressView().scaleEffect(0.75)
                            }
                            if !installStatusMsg.isEmpty {
                                Text(installStatusMsg)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else {
                        Button {
                            Task { await installCompleted(item) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone.and.arrow.forward.inward")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Install to Device")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassTinted(.accentColor, cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.selectedDevice == nil)
                        .help(appState.selectedDevice == nil ? "No device connected" : "Install to device")
                    }
                }
            }

            if item.status.isActive {
                ProgressView(value: item.displayProgress / 100.0)
                    .progressViewStyle(.linear)
                    .tint(item.status.color)
                    .animation(.easeInOut(duration: 0.25), value: item.displayProgress)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
    }

    private func statusIcon(_ status: DownloadStatus) -> String {
        switch status {
        case .completed:    return "checkmark"
        case .error, .installError: return "xmark"
        default:            return "clock"
        }
    }

    // MARK: - Meta Grid

    private var metaGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            metaCard(
                icon: "tag.fill",
                iconColor: .accentColor,
                label: "Version",
                value: game.version.isEmpty ? "—" : game.version
            )
            metaCard(
                icon: "arrow.down.circle.fill",
                iconColor: .green,
                label: "Size",
                value: game.formattedSize.isEmpty ? "—" : game.formattedSize
            )
            metaCard(
                icon: "calendar",
                iconColor: .orange,
                label: "Updated",
                value: game.formattedLastUpdated.isEmpty ? "—" : game.formattedLastUpdated
            )
            metaCard(
                icon: "chart.bar.fill",
                iconColor: .purple,
                label: "Popularity",
                value: formatDownloads(game.downloads)
            )
        }
    }

    private func metaCard(icon: String, iconColor: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.3)
            }
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 12)
    }

    private func formatDownloads(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000     { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    // MARK: - Device Actions

    private var deviceActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "appletvremote.and.apple.tv.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Device Actions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                // Re-install
                if !game.isDeviceOnly {
                    deviceActionBtn(
                        title: "Re-install",
                        icon: "arrow.clockwise.circle",
                        color: .accentColor
                    ) {
                        showReinstallConfirm = true
                    }
                }

                // Export
                deviceActionBtn(
                    title: "Export APK",
                    icon: "square.and.arrow.up",
                    color: .primary
                ) {
                    appState.exportGame(game)
                    dismiss()
                }

                // Uninstall
                deviceActionBtn(
                    title: isUninstalling ? "Uninstalling…" : "Uninstall",
                    icon: isUninstalling ? "circle" : "trash",
                    color: .red,
                    isDestructive: true,
                    isDisabled: isUninstalling
                ) {
                    showUninstallConfirm = true
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
    }

    private func deviceActionBtn(
        title: String,
        icon: String,
        color: Color,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isDisabled ? Color.secondary : color)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDisabled ? Color.secondary : (isDestructive ? .red : .primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassClear(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    // MARK: - Trailer Section

    private func trailerSection(videoId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Trailer", icon: "play.rectangle.fill", color: .red)
            // P2-13: Lazy YouTube embed — WKWebView is only initialised when this
            // view first appears in the scroll viewport, not when the sheet opens.
            _LazyYouTubeEmbed(videoId: videoId)
            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 10))
                Text("Trailer from YouTube — may not always match this exact game.")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Release Notes Section

    private func releaseNotesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Release Notes", icon: "doc.text.fill", color: .accentColor)
            Text(notes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassCard(cornerRadius: 12)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassTinted(.red, cornerRadius: 10)
    }

    // MARK: - Actions

    private func installCompleted(_ item: DownloadItem) async {
        guard let device = appState.selectedDevice else { return }
        isInstalling = true
        installError = nil
        installProgress = nil
        installStatusMsg = ""
        do {
            let extractedDir = URL(fileURLWithPath: item.downloadPath)
                .appendingPathComponent(item.releaseName)
            _ = try await appState.installation.install(
                extractedDirectory: extractedDir,
                packageName: item.packageName,
                deviceSerial: device.id,
                onStatus: { msg in
                    Task { @MainActor in installStatusMsg = msg }
                },
                onProgress: { pct in
                    Task { @MainActor in installProgress = pct }
                }
            )
            appState.refreshInstalledStatus()
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
        installProgress = nil
        installStatusMsg = ""
    }

    private func performUninstall() async {
        isUninstalling = true
        uninstallError = nil
        do {
            try await appState.uninstallGame(game)
            dismiss()
        } catch {
            uninstallError = error.localizedDescription
        }
        isUninstalling = false
    }

    private func loadMeta() async {
        guard !game.isDeviceOnly else {
            isLoadingMeta = false
            return
        }
        async let notesTask = appState.gameLibrary.getNote(releaseName: game.releaseName)
        async let trailerTask = appState.gameLibrary.getTrailerVideoId(releaseName: game.releaseName)
        let (n, t) = await (notesTask, trailerTask)
        notes = n
        trailerVideoId = t
        isLoadingMeta = false
    }
}

// MARK: - Lazy YouTube Embed (P2-13)

/// Wraps `YouTubePlayerView` so the `WKWebView` is only initialised once this view
/// scrolls into the visible area — not when the `GameDetailSheet` first opens.
private struct _LazyYouTubeEmbed: View {
    let videoId: String
    @State private var hasAppeared = false

    var body: some View {
        Group {
            if hasAppeared {
                YouTubePlayerView(videoId: videoId)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                    )
            } else {
                // Placeholder until the view enters the viewport
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(height: 220)
                    .overlay(
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .onAppear { hasAppeared = true }
    }
}

// MARK: - YouTube WKWebView

struct YouTubePlayerView: NSViewRepresentable {
    let videoId: String

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let host = url.host ?? ""
            if url.scheme == "about" || url.scheme == "blob" || host.contains("youtube-nocookie.com") {
                decisionHandler(.allow)
            } else if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("google.com") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.setValue(true, forKey: "fullScreenEnabled")
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let embedURL = "https://www.youtube-nocookie.com/embed/\(videoId)"
        if let current = nsView.url?.absoluteString, current.contains(videoId) { return }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; background: #000; }
          html, body { width: 100%; height: 100%; overflow: hidden; }
          iframe {
            position: absolute; top: 0; left: 0;
            width: 100%; height: 100%;
            border: none;
          }
        </style>
        </head>
        <body>
        <iframe
          src="\(embedURL)?autoplay=0&rel=0&modestbranding=1&fs=1"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; fullscreen"
          allowfullscreen
          webkitallowfullscreen
          mozallowfullscreen>
        </iframe>
        </body>
        </html>
        """
        nsView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }
}
