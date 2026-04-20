//
//  AsyncThumbnailView.swift
//  QuestSyndicate
//
//  High-performance async thumbnail loader for game cards.
//  Uses ThumbnailCacheService for two-level caching.
//  Shows shimmer skeleton while loading and a styled fallback on failure.
//

import SwiftUI
import AppKit

// MARK: - LoadState

private enum LoadState: Equatable {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

// MARK: - AsyncThumbnailView

struct AsyncThumbnailView: View {

    let thumbnailPath: String
    var cornerRadius: CGFloat = 10
    var targetSize: CGSize = CGSize(width: 128, height: 128)
    /// If the local disk file is missing/empty, this URL will be fetched instead.
    var fallbackURL: URL? = nil
    /// When true the image fills the frame (cover mode). When false it fits inside (letterbox mode).
    var fillFrame: Bool = false

    @State private var loadState: LoadState = .idle

    var body: some View {
        ZStack {
            switch loadState {

            case .idle, .loading:
                skeletonView

            case .loaded(let image):
                if fillFrame {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .transition(.opacity.animation(.easeIn(duration: 0.2)))
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.animation(.easeIn(duration: 0.2)))
                }

            case .failed:
                fallbackView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Kick off (or restart) load whenever thumbnailPath or fallbackURL changes.
        .task(id: thumbnailPath) {
            await load()
        }
    }

    // MARK: - Sub-views

    private var skeletonView: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
            .shimmer()
    }

    private var fallbackView: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            }
        }
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        // --- 1. Try local disk path ---
        if !thumbnailPath.isEmpty {
            if let cached = await ThumbnailCacheService.shared.cachedImage(for: thumbnailPath, targetSize: targetSize) {
                loadState = .loaded(cached)
                return
            }

            loadState = .loading

            if let image = await ThumbnailCacheService.shared.loadImage(for: thumbnailPath, targetSize: targetSize) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.18)) {
                    loadState = .loaded(image)
                }
                return
            }
            guard !Task.isCancelled else { return }
        } else {
            loadState = .loading
        }

        // --- 2. Disk miss — try server fallback URL ---
        if let url = fallbackURL {
            let cacheKey = url.absoluteString
            if let cached = await ThumbnailCacheService.shared.cachedImage(for: cacheKey, targetSize: targetSize) {
                withAnimation(.easeIn(duration: 0.18)) { loadState = .loaded(cached) }
                return
            }
            if let image = await ThumbnailCacheService.shared.loadImageFromURL(url, targetSize: targetSize) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.18)) { loadState = .loaded(image) }
                return
            }
        }

        guard !Task.isCancelled else { return }
        loadState = .failed
    }
}

// MARK: - Preview support

#if DEBUG
#Preview("Loaded") {
    AsyncThumbnailView(thumbnailPath: "")
        .frame(width: 64, height: 64)
        .padding()
}

#Preview("Skeleton") {
    AsyncThumbnailView(thumbnailPath: "/nonexistent/path.jpg")
        .frame(width: 64, height: 64)
        .padding()
}
#endif
