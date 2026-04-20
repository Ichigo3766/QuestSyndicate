
//
//  GameLibraryService.swift
//  QuestSyndicate
//
//  Manages VRP game library: syncing, parsing, blacklists, trailers
//

import Foundation

// MARK: - VRPConfig

struct VRPConfig: Sendable {
    var baseUri: String
    var password: String
    var lastSync: Date?
}

extension VRPConfig: Codable {
    // Explicit nonisolated Codable conformance to avoid @MainActor inference
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseUri  = try container.decode(String.self, forKey: .baseUri)
        password = try container.decode(String.self, forKey: .password)
        lastSync = try container.decodeIfPresent(Date.self, forKey: .lastSync)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseUri,  forKey: .baseUri)
        try container.encode(password, forKey: .password)
        try container.encodeIfPresent(lastSync, forKey: .lastSync)
    }

    private enum CodingKeys: String, CodingKey {
        case baseUri, password, lastSync
    }
}

// MARK: - GameLibraryService

actor GameLibraryService {

    private let rclone: RcloneService
    private let extraction: ExtractionService

    private var vrpConfig: VRPConfig?
    private var games: [GameInfo] = []
    private var serverBlacklist: Set<String> = []
    private var customBlacklist: [BlacklistEntry] = []
    private var videoIdCache: [String: String?] = [:]

    private let dataPath: URL = Constants.vrpDataDirectory
    private let configPath: URL = Constants.vrpConfigPath
    private let serverInfoPath: URL = Constants.serverInfoPath
    private let customBlacklistPath: URL = Constants.customBlacklistPath

    // Internal blacklist (hardcoded packages that should never show)
    private let internalBlacklist: Set<String> = ["com.oculus.MiramarSetupRetail"]

    init(rclone: RcloneService, extraction: ExtractionService) {
        self.rclone = rclone
        self.extraction = extraction
    }

    // MARK: - Initialize

    func initialize() async {
        try? FileManager.default.createDirectoryIfNeeded(at: dataPath)
        await loadConfig()
        await loadGameList()
        await loadServerBlacklist()
        await loadCustomBlacklist()
    }

    // MARK: - Games Access

    func getGames() -> [GameInfo] { games }

    func getLastSyncTime() -> Date? { vrpConfig?.lastSync }

    func getConfig() -> VRPConfig? { vrpConfig }

    func serverBlacklistCount() -> Int { serverBlacklist.count }

    // MARK: - Force Sync

    func forceSync(mirrorConfigPath: String? = nil, activeMirrorRemote: String? = nil) async throws -> [GameInfo] {
        guard let config = vrpConfig, !config.baseUri.isEmpty else {
            throw NSError(domain: "QS", code: 10, userInfo: [NSLocalizedDescriptionKey: "Server configuration not set"])
        }

        let metaArchive = dataPath.appendingPathComponent("meta.7z")
        // Remove any stale file or directory so rclone copyto always gets a clean file destination.
        // A leftover directory named "meta.7z" (from a prior failed extraction) causes rclone to
        // fail with "Failed to copyto: is a directory not a file".
        try? FileManager.default.removeItem(at: metaArchive)
        try await downloadMetaArchive(to: metaArchive, config: config,
                                      mirrorConfigPath: mirrorConfigPath,
                                      mirrorRemote: activeMirrorRemote)
        try await extractMetaArchive(at: metaArchive, password: config.password)

        await loadGameList()
        await loadServerBlacklist()

        // Update last sync time
        vrpConfig?.lastSync = Date()
        await saveConfig()

        return games
    }

    // MARK: - Game Notes

    func getNote(releaseName: String) async -> String {
        let notesDir = dataPath.appendingPathComponent(".meta/notes")
        let noteFile = notesDir.appendingPathComponent("\(releaseName).txt")
        return (try? String(contentsOf: noteFile, encoding: .utf8)) ?? ""
    }

    // MARK: - YouTube Trailer

    func getTrailerVideoId(gameName: String) async -> String? {
        if let cached = videoIdCache[gameName] { return cached }

        // Strip anything in parentheses/brackets from the end of the name
        // e.g. "Mr. Fix – Repair Game (Mr-Fix)" → "Mr. Fix – Repair Game"
        //      "Alien: Isolation [VR Mod]"       → "Alien: Isolation"
        let cleanName = gameName
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let searchName = cleanName.isEmpty ? gameName : cleanName

        // "game name + Quest" reliably surfaces the official Meta Quest trailer as the top result.
        let query = "\(searchName) Quest official trailer"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://www.youtube.com/results?search_query=\(encoded)")!

        var request = URLRequest(url: searchURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            videoIdCache[gameName] = nil
            return nil
        }

        // YouTube embeds video IDs inside JSON blobs in the search page.
        // We look for IDs that appear inside a "videoRenderer" context (real search results)
        // so we skip ads ("adSlotRenderer") and Shorts ("reelShelfRenderer") which appear first.
        let videoId = firstVideoRendererID(in: html)
        videoIdCache[gameName] = videoId
        return videoId
    }

    /// Extracts the first video ID that belongs to a real `videoRenderer` block,
    /// skipping ads, Shorts shelves, and promoted content.
    private func firstVideoRendererID(in html: String) -> String? {
        // Split on "videoRenderer" so each chunk starts with a real result block.
        let chunks = html.components(separatedBy: "\"videoRenderer\"")
        // Index 0 is everything before the first videoRenderer — skip it.
        for chunk in chunks.dropFirst() {
            // The videoId key always appears within the first ~200 chars of the renderer object.
            let head = String(chunk.prefix(300))
            guard let idRange = head.range(of: #""videoId":"([a-zA-Z0-9_-]{11})""#, options: .regularExpression) else {
                continue
            }
            let raw = String(head[idRange])
                .replacingOccurrences(of: "\"videoId\":\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmed
            if raw.count == 11 { return raw }
        }
        return nil
    }

    // MARK: - Blacklist

    func getBlacklist() -> [BlacklistEntry] { customBlacklist }

    func isGameBlacklisted(packageName: String, versionCode: Int? = nil) -> Bool {
        if internalBlacklist.contains(packageName) { return true }
        if serverBlacklist.contains(packageName) { return true }
        return customBlacklist.contains { entry in
            guard entry.packageName == packageName else { return false }
            switch entry.version {
            case .any: return true
            case .specific(let v):
                if let vc = versionCode { return v == vc }
                return false
            }
        }
    }

    func addToBlacklist(packageName: String, version: BlacklistEntry.BlacklistVersion = .any) async {
        let entry = BlacklistEntry(packageName: packageName, version: version)
        if !customBlacklist.contains(where: { $0.packageName == packageName }) {
            customBlacklist.append(entry)
            await saveCustomBlacklist()
        }
    }

    func removeFromBlacklist(packageName: String) async {
        customBlacklist.removeAll { $0.packageName == packageName }
        await saveCustomBlacklist()
    }

    // MARK: - Update installed status

    func updateInstalledStatus(installedPackages: [PackageInfo]) {
        // P2-14: Mutate in-place — avoids allocating a full copy of ~2700 GameInfo structs
        let installedMap = Dictionary(uniqueKeysWithValues: installedPackages.map { ($0.packageName, $0.versionCode) })
        for i in games.indices {
            if let installedVersion = installedMap[games[i].packageName] {
                games[i].isInstalled = true
                games[i].deviceVersionCode = installedVersion
                if let gameVersion = Int(games[i].version) {
                    games[i].hasUpdate = installedVersion < gameVersion
                } else {
                    games[i].hasUpdate = false
                }
            } else {
                games[i].isInstalled = false
                games[i].deviceVersionCode = nil
                games[i].hasUpdate = nil
            }
        }
    }

    // MARK: - Private: Config Loading

    private func loadConfig() async {
        // Read cached lastSync from vrp-config.json so we can preserve it
        let cachedLastSync: Date? = {
            guard let data = try? Data(contentsOf: configPath),
                  let cached = try? JSONDecoder().decode(VRPConfig.self, from: data)
            else { return nil }
            return cached.lastSync
        }()

        // Try user ServerInfo.json first, then bundled
        let paths = [serverInfoPath, Bundle.main.url(forResource: "ServerInfo", withExtension: "json")].compactMap { $0 }
        for path in paths {
            if let data = try? Data(contentsOf: path),
               var config = try? JSONDecoder().decode(VRPConfig.self, from: data),
               !config.baseUri.isEmpty {
                // Preserve the lastSync from vrp-config.json — ServerInfo.json never contains it
                if config.lastSync == nil {
                    config.lastSync = cachedLastSync
                }
                vrpConfig = config
                await saveConfig()
                return
            }
        }

        // Also try cached vrp-config.json
        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(VRPConfig.self, from: data) {
            vrpConfig = config
            return
        }

        // No config found — write and use the built-in default
        let defaultConfig = VRPConfig(
            baseUri: "https://go.srcdl1.xyz/",
            password: "Z0w1OVZmZ1B4b0hS"
        )
        vrpConfig = defaultConfig
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(defaultConfig) {
            try? data.write(to: serverInfoPath)
        }
        await saveConfig()
    }

    private func saveConfig() async {
        guard let config = vrpConfig else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            try? data.write(to: configPath)
        }
    }

    // MARK: - Private: Download meta.7z

    private func downloadMetaArchive(
        to destination: URL,
        config: VRPConfig,
        mirrorConfigPath: String?,
        mirrorRemote: String?
    ) async throws {
        if let mirrorPath = mirrorConfigPath, let remote = mirrorRemote {
            // Use active mirror
            let source = "\(remote):/Quest Games/meta.7z"
            let handle = await rclone.download(
                source: source,
                destination: destination.path,
                configPath: mirrorPath,
                onProgress: { _ in }
            )
            _ = try await handle.waitForCompletion()
        } else {
            // Public endpoint via rclone :http:
            // copyto needs a source without a leading slash and destination as full file path
            let source = ":http:meta.7z"
            let handle = await rclone.download(
                source: source,
                destination: destination.path,
                httpUrl: config.baseUri,
                onProgress: { _ in }
            )
            _ = try await handle.waitForCompletion()
        }
    }

    // MARK: - Private: Extract meta.7z

    private func extractMetaArchive(at archive: URL, password: String) async throws {
        try await extraction.extract(
            archive: archive,
            destination: dataPath,
            password: password,
            key: "meta-sync",
            onProgress: { _ in }
        )
    }

    // MARK: - Private: Parse Game List

    private func loadGameList() async {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dataPath.path)) ?? []
        // Match: VRP-GameList.txt, GameList.txt, etc.
        guard let fileName = entries.first(where: {
            $0.hasSuffix("amelist.txt") || $0.hasSuffix("ameList.txt") || $0 == "GameList.txt"
        }) else { return }
        let gameListURL = dataPath.appendingPathComponent(fileName)
        guard let content = try? String(contentsOf: gameListURL, encoding: .utf8) else { return }
        games = parseGameList(content)
    }

    private func parseGameList(_ content: String) -> [GameInfo] {
        // Format (current VRP GameList.txt):
        // Game Name;Release Name;Package Name;Version Code;Last Updated;Size (MB);Downloads;Rating;Rating Count
        var result: [GameInfo] = []
        // Use a seen-set to deduplicate by packageName (take first/latest entry)
        var seen = Set<String>()
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: ";")
            guard parts.count >= 7 else { continue }

            let name        = parts[0].trimmed
            let releaseName = parts[1].trimmed
            let packageName = parts[2].trimmed
            let version     = parts[3].trimmed
            let lastUpdated = parts[4].trimmed
            let sizeMB      = parts[5].trimmed   // size in MB as a decimal string
            let downloads   = Int(parts[6].trimmed.components(separatedBy: ".").first ?? parts[6].trimmed) ?? 0

            // Skip the header row and blank/incomplete entries
            if name == "Game Name" || name.isEmpty || packageName.isEmpty { continue }
            // Skip duplicates — keep the first (which is the latest in VRP's list)
            guard !seen.contains(packageName) else { continue }
            seen.insert(packageName)

            // Convert raw MB value to a human-readable size string
            let size: String
            if let mb = Double(sizeMB) {
                if mb >= 1024 {
                    size = String(format: "%.1f GB", mb / 1024.0)
                } else {
                    size = String(format: "%.0f MB", mb)
                }
            } else {
                size = sizeMB.isEmpty ? "Unknown" : sizeMB
            }

            // P0-4: Parse "YYYY.MM.DD" → Date once at load time so isRecentlyUpdated,
            // sort comparisons, and formattedLastUpdated never need to re-parse.
            let parsedDate: Date? = {
                let p = lastUpdated.split(separator: ".")
                guard p.count == 3,
                      let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
                var comps = DateComponents()
                comps.year = y; comps.month = m; comps.day = d
                return Calendar.current.date(from: comps)
            }()

            // Thumbnails on disk are named by packageName (e.g. com.Sanzaru.Wrath2.jpg)
            let thumbnailPath = dataPath.appendingPathComponent(".meta/thumbnails/\(packageName).jpg").path
            let notePath      = dataPath.appendingPathComponent(".meta/notes/\(releaseName).txt").path

            result.append(GameInfo(
                name: name,
                packageName: packageName,
                version: version,
                size: size,
                lastUpdated: lastUpdated,
                releaseName: releaseName,
                downloads: downloads,
                thumbnailPath: thumbnailPath,
                notePath: notePath,
                isInstalled: false,
                deviceVersionCode: nil,
                hasUpdate: nil,
                parsedDate: parsedDate
            ))
        }
        return result
    }

    // MARK: - Private: Server Blacklist

    private func loadServerBlacklist() async {
        let blacklistPath = dataPath.appendingPathComponent(".meta/nouns/blacklist.txt")
        guard let content = try? String(contentsOf: blacklistPath, encoding: .utf8) else { return }
        serverBlacklist = Set(content.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty })
    }

    // MARK: - Private: Custom Blacklist

    private func loadCustomBlacklist() async {
        guard let data = try? Data(contentsOf: customBlacklistPath) else { return }
        customBlacklist = (try? JSONDecoder().decode([BlacklistEntry].self, from: data)) ?? []
    }

    private func saveCustomBlacklist() async {
        if let data = try? JSONEncoder().encode(customBlacklist) {
            try? data.write(to: customBlacklistPath)
        }
    }
}
