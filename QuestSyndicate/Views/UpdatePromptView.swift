//
//  UpdatePromptView.swift
//  QuestSyndicate
//
//  Beautiful update prompt sheet with changelog, download progress, and
//  full install flow.
//

import SwiftUI

// MARK: - UpdatePromptView

struct UpdatePromptView: View {
    @Environment(\.dismiss) private var dismiss
    let updateService: UpdateService

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            headerSection

            Divider()

            // ── Body (changelog or progress) ─────────────────────────────────
            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ── Footer buttons ────────────────────────────────────────────────
            footerSection
        }
        .frame(width: 540, height: 480)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 16) {
            // App icon
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Update Available")
                    .font(.title2).fontWeight(.bold)

                if let info = updateService.availableUpdate {
                    HStack(spacing: 6) {
                        Text("Version \(info.version)")
                            .font(.callout).fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                        Text("You have \(local)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let dateStr = info.releaseDate {
                        Text(formattedDate(dateStr))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // "New" badge
            Text("NEW")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        switch updateService.state {
        case .available(let info):
            changelogView(info: info)

        case .downloading(let progress):
            downloadingView(progress: progress)

        case .installing:
            installingView

        case .failed(let msg):
            failedView(message: msg)

        default:
            changelogView(info: updateService.availableUpdate ?? UpdateInfo(version: ""))
        }
    }

    // MARK: - Changelog

    private func changelogView(info: UpdateInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notes = info.releaseNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("What's New", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No release notes provided.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    // MARK: - Downloading

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 6)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Downloading Update…")
                    .font(.title3).fontWeight(.semibold)
                Text("Please keep the app open until the update is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .frame(maxWidth: 320)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Installing

    private var installingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.4)
                .padding()

            VStack(spacing: 6) {
                Text("Installing…")
                    .font(.title3).fontWeight(.semibold)
                Text("The app will relaunch automatically when done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 6) {
                Text("Update Failed")
                    .font(.title3).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 10) {
                Button("Try Again") {
                    Task { await updateService.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)

                Button("View on GitHub") {
                    NSWorkspace.shared.open(Constants.githubReleasesPageURL)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        let isActive: Bool = {
            switch updateService.state {
            case .downloading, .installing: return true
            default: return false
            }
        }()

        let isFailed: Bool = {
            if case .failed = updateService.state { return true }
            return false
        }()

        HStack(spacing: 10) {
            // "Later" — only when not mid-install
            if !isActive {
                Button("Later") {
                    updateService.dismissUpdate()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
            }

            Spacer()

            // "View on GitHub"
            if !isActive && !isFailed {
                Button {
                    NSWorkspace.shared.open(Constants.githubReleasesPageURL)
                } label: {
                    Label("Release Notes", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }

            // "Update Now" — only shown when the update is available (not failed)
            if case .available = updateService.state {
                Button {
                    Task { await updateService.downloadAndInstall() }
                } label: {
                    Label(
                        updateService.availableUpdate?.downloadUrl == nil
                            ? "Open GitHub"
                            : "Update Now",
                        systemImage: updateService.availableUpdate?.downloadUrl == nil
                            ? "arrow.up.right.square"
                            : "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .onTapGesture {
                    // If no DMG asset, fall back to opening the GitHub releases page
                    if updateService.availableUpdate?.downloadUrl == nil {
                        NSWorkspace.shared.open(Constants.githubReleasesPageURL)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .none
            return "Released \(out.string(from: date))"
        }
        return iso
    }
}

// MARK: - Compact update banner (shown in toolbar / status bar area)

struct UpdateBannerView: View {
    let updateService: UpdateService
    @Binding var showSheet: Bool

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                if let v = updateService.availableUpdate?.version {
                    Text("v\(v) available")
                        .font(.caption).fontWeight(.medium)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassCapsuleTinted(.accentColor)
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Preview

#Preview("Update Prompt") {
    let svc = UpdateService()
    UpdatePromptView(updateService: svc)
}
