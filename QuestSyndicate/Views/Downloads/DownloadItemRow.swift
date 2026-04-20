import SwiftUI

struct DownloadItemRow: View {
    @Environment(AppState.self) private var appState
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status.color)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.gameName).font(.callout).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if item.status == .downloading, let speed = item.speed {
                        Text(speed).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let sz = item.size, !sz.isEmpty {
                        Text(sz).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                if item.status.isActive {
                    VStack(alignment: .leading, spacing: 2) {
                        if item.status == .installing {
                            if let ip = item.installProgress, ip > 0 {
                                // Determinate bar — adb streamed a percentage
                                ProgressView(value: ip / 100.0)
                                    .progressViewStyle(.linear)
                                    .tint(item.status.color)
                                    .animation(.easeInOut(duration: 0.15), value: ip)
                            } else {
                                // No progress yet — indeterminate spinner bar
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(item.status.color)
                            }
                        } else {
                            ProgressView(value: item.displayProgress / 100.0)
                                .progressViewStyle(.linear)
                                .tint(item.status.color)
                        }
                        HStack {
                            Text(item.statusDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.2), value: item.statusDescription)
                            Spacer()
                            if item.status == .installing, let ip = item.installProgress, ip > 0 {
                                Text("\(Int(ip))%")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.easeInOut(duration: 0.2), value: Int(ip))
                            } else if item.status != .installing {
                                Text("\(Int(item.displayProgress))%")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(item.statusDescription)
                        .font(.caption)
                        .foregroundStyle(item.status == .error || item.status == .installError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            actionButtons
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if item.status.canPause {
                Button { appState.pipeline.pauseDownload(releaseName: item.releaseName) } label: {
                    Image(systemName: "pause.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Pause")
            }

            if item.status.canResume {
                Button { appState.pipeline.resumeDownload(releaseName: item.releaseName) } label: {
                    Image(systemName: "play.circle").font(.system(size: 18)).foregroundStyle(.blue)
                }.buttonStyle(.plain).help("Resume")
            }

            if item.status.canRetry {
                Button { appState.pipeline.retryDownload(releaseName: item.releaseName) } label: {
                    Image(systemName: "arrow.clockwise.circle").font(.system(size: 18)).foregroundStyle(.orange)
                }.buttonStyle(.plain).help("Retry")
            }

            if item.status == .completed {
                if item.isInstalledToDevice {
                    // Already installed — show a static green checkmark (no action needed)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                        .help("Installed to device")
                } else {
                    // Downloaded but not yet installed — show install button
                    Button {
                        Task {
                            guard let device = appState.selectedDevice else { return }
                            await appState.pipeline.installFromCompleted(releaseName: item.releaseName,
                                                                         deviceSerial: device.id)
                        }
                    } label: {
                        Image(systemName: "iphone.and.arrow.forward.inward").font(.system(size: 16)).foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.selectedDevice == nil)
                    .help(appState.selectedDevice == nil ? "No device connected" : "Install to device")
                }
            }

            if item.status.canCancel {
                Button { appState.pipeline.cancelItem(releaseName: item.releaseName) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Cancel")
            }

            if item.status.canDelete {
                Button(role: .destructive) {
                    appState.pipeline.removeFromQueue(releaseName: item.releaseName)
                } label: {
                    Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(.red)
                }.buttonStyle(.plain).help("Remove")
            }
        }
    }
}
