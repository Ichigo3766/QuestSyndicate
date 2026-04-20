//
//  ThumbnailCacheService.swift
//  QuestSyndicate
//
//  Actor-based async thumbnail loader with two-level cache:
//  1. In-memory NSCache  (fast, auto-evictable under memory pressure)
//  2. Disk files already exist at thumbnailPath — no extra disk write needed
//

import AppKit
import Foundation

// MARK: - ThumbnailCacheService

actor ThumbnailCacheService {

    // MARK: Shared singleton
    static let shared = ThumbnailCacheService()

    // MARK: - Private state

    /// Memory cache of fully-decoded NSImages, keyed by absolute path.
    private let memoryCache = NSCache<NSString, NSImage>()

    /// In-flight task handles — so we can cancel when a cell scrolls off.
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    // MARK: - Init

    private init() {
        memoryCache.countLimit = 400          // max 400 images
        memoryCache.totalCostLimit = 150 * 1_024 * 1_024  // ~150 MB
    }

    // MARK: - Public API

    /// Returns the cached image synchronously if available (size-aware); otherwise nil.
    func cachedImage(for path: String, targetSize: CGSize = CGSize(width: 128, height: 128)) -> NSImage? {
        let key = cacheKeyFor(path: path, size: targetSize)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Loads an image for `path` at the given display `targetSize` (in points).
    /// Retina scale is applied automatically (2×) so images are never upscaled.
    /// Calling again for the same path+size while in-flight returns the same task.
    func loadImage(for path: String, targetSize: CGSize = CGSize(width: 128, height: 128)) async -> NSImage? {
        let cacheKey = cacheKeyFor(path: path, size: targetSize)

        // 1. Memory cache hit
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // 2. Return existing in-flight task if present
        if let existing = inflight[cacheKey] {
            return await existing.value
        }

        // 3. Kick off a new background decode task
        let screenScale: CGFloat = 2.0   // assume Retina; images are never upscaled beyond native res
        let pixelSize = CGSize(width: targetSize.width * screenScale,
                               height: targetSize.height * screenScale)

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let image = NSImage(data: data) else { return nil }

            // Only downsample if the source is larger than what we need —
            // never upscale (that would add blur without any quality benefit).
            let nativeW = image.size.width
            let nativeH = image.size.height
            let needsDownsample = nativeW > pixelSize.width || nativeH > pixelSize.height
            let thumbnail = needsDownsample
                ? Self.downsample(image: image, to: pixelSize)
                : image

            await self?.store(thumbnail, for: cacheKey)
            return thumbnail
        }

        inflight[cacheKey] = task
        let result = await task.value
        inflight.removeValue(forKey: cacheKey)
        return result
    }

    /// Downloads an image from a remote URL, downsamples it, and caches it.
    func loadImageFromURL(_ url: URL, targetSize: CGSize = CGSize(width: 128, height: 128)) async -> NSImage? {
        let cacheKey = "\(url.absoluteString)@\(Int(targetSize.width))x\(Int(targetSize.height))"

        // Memory cache hit
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // Return existing in-flight task
        if let existing = inflight[cacheKey] {
            return await existing.value
        }

        let screenScale: CGFloat = 2.0
        let pixelSize = CGSize(width: targetSize.width * screenScale,
                               height: targetSize.height * screenScale)

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return nil }

            let nativeW = image.size.width
            let nativeH = image.size.height
            let needsDownsample = nativeW > pixelSize.width || nativeH > pixelSize.height
            let thumbnail = needsDownsample
                ? Self.downsample(image: image, to: pixelSize)
                : image

            await self?.store(thumbnail, for: cacheKey)
            return thumbnail
        }

        inflight[cacheKey] = task
        let result = await task.value
        inflight.removeValue(forKey: cacheKey)
        return result
    }

    /// Cancels an in-flight load. Called when a cell leaves the visible area.
    func cancelLoad(for path: String) {
        inflight[path]?.cancel()
        inflight.removeValue(forKey: path)
    }

    /// Purges the in-memory cache (e.g. on memory pressure).
    func purgeMemoryCache() {
        memoryCache.removeAllObjects()
    }

    // MARK: - Private helpers

    /// Builds a stable, size-aware cache key so grid (178pt) and list (56pt) thumbnails
    /// are stored separately and never mixed up.
    private func cacheKeyFor(path: String, size: CGSize) -> String {
        "\(path)@\(Int(size.width))x\(Int(size.height))"
    }

    private func store(_ image: NSImage?, for key: String) {
        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Downsamples an NSImage to the target size while preserving aspect ratio.
    /// Uses CGContext — fully thread-safe, no NSGraphicsContext needed.
    private static func downsample(image: NSImage, to targetSize: CGSize) -> NSImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }

        // Preserve aspect ratio (fit within targetSize)
        let widthRatio  = targetSize.width  / originalSize.width
        let heightRatio = targetSize.height / originalSize.height
        let scale       = min(widthRatio, heightRatio)
        let drawSize    = CGSize(width:  floor(originalSize.width  * scale),
                                 height: floor(originalSize.height * scale))

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let width  = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: drawSize))

        guard let resultCG = ctx.makeImage() else { return image }
        return NSImage(cgImage: resultCG, size: drawSize)
    }
}
