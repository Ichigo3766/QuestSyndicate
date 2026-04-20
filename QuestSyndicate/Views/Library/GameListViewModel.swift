//
//  GameListViewModel.swift
//  QuestSyndicate
//
//  Dedicated view-model for the game list screen.
//  All heavy filtering/sorting runs off the main thread; results are
//  published back on @MainActor so the UI never freezes.
//

import SwiftUI
import Observation

// MARK: - SortOption

enum GameSortOption: String, CaseIterable, Identifiable {
    case title         = "Title"
    case date          = "Date"
    case downloads     = "Popularity"
    case size          = "Size"
    case recentlyAdded = "Recently Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .title:         return "textformat.abc"
        case .date:          return "calendar.badge.clock"
        case .downloads:     return "chart.bar.fill"
        case .size:          return "arrow.up.left.and.arrow.down.right"
        case .recentlyAdded: return "sparkles"
        }
    }
}

// MARK: - InstallFilter

enum GameInstallFilter: String, CaseIterable, Identifiable {
    case all            = "All"
    case installed      = "Installed"
    case updates        = "Updates"
    case notInstalled   = "Not Installed"
    case onDeviceOnly   = "On Device"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all:            return "square.grid.2x2"
        case .installed:      return "checkmark.circle.fill"
        case .updates:        return "arrow.down.circle.fill"
        case .notInstalled:   return "circle"
        case .onDeviceOnly:   return "iphone.circle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .all:            return .accentColor
        case .installed:      return .green
        case .updates:        return .orange
        case .notInstalled:   return .secondary
        case .onDeviceOnly:   return .purple
        }
    }
}

// MARK: - GameListViewModel

@MainActor
@Observable
final class GameListViewModel {

    // MARK: - Published state

    /// Raw search text — set directly by the search field.
    var searchText: String = "" {
        didSet { scheduleDebounce() }
    }

    /// Install filter — immediate re-filter on change.
    var installFilter: GameInstallFilter = .all {
        didSet { triggerRecompute(source: "filter") }
    }

    /// Currently displayed (sorted + filtered) games.
    var displayedGames: [GameInfo] = []

    /// Whether a background recompute is in progress.
    var isRecomputing: Bool = false

    // MARK: - P0-2: Pre-computed filter counts
    private(set) var installedCount: Int = 0
    private(set) var updatesCount: Int = 0

    // MARK: - Sort (persisted via UserDefaults)

    /// The active sort category.
    var sortOption: GameSortOption {
        get { _sortOption }
        set {
            if _sortOption == newValue {
                // Tapping the same option flips the direction (except recentlyAdded)
                if newValue != .recentlyAdded {
                    _sortAscending.toggle()
                    UserDefaults.standard.set(_sortAscending, forKey: "gameListSortAscending")
                }
            } else {
                _sortOption = newValue
                // Reset to sensible defaults for each category
                switch newValue {
                case .title:         _sortAscending = true
                case .date:          _sortAscending = false   // newest first
                case .downloads:     _sortAscending = false   // most first
                case .size:          _sortAscending = false   // largest first
                case .recentlyAdded: _sortAscending = false
                }
                UserDefaults.standard.set(newValue.rawValue, forKey: "gameListSortOption")
                UserDefaults.standard.set(_sortAscending, forKey: "gameListSortAscending")
            }
            triggerRecompute(source: "sort")
        }
    }

    /// The current sort direction (ascending = true).
    var sortAscending: Bool { _sortAscending }

    // MARK: - Private

    private var sourceGames: [GameInfo] = []

    private var _sortOption: GameSortOption = {
        let raw = UserDefaults.standard.string(forKey: "gameListSortOption") ?? ""
        return GameSortOption(rawValue: raw) ?? .date
    }()

    private var _sortAscending: Bool = {
        // If the key was never written it returns false — sensible "newest first" default.
        if UserDefaults.standard.object(forKey: "gameListSortAscending") == nil { return false }
        return UserDefaults.standard.bool(forKey: "gameListSortAscending")
    }()

    private var downloadPath: String = ""
    private var debounceTask: Task<Void, Never>?

    private var lastSourceID: Int = 0
    private var lastSortOption: GameSortOption? = nil
    private var lastSortAscending: Bool? = nil
    private var lastFilter: GameInstallFilter? = nil
    private var lastQuery: String = ""

    // MARK: - Public API

    func update(
        games: [GameInfo],
        deviceOnlyGames: [GameInfo] = [],
        downloadPath: String = ""
    ) {
        self.downloadPath = downloadPath
        let combined = games + deviceOnlyGames
        // Include game count, package names, versions, and install state so that:
        //   • newly added games (count changes) always trigger a refresh
        //   • version bumps / metadata changes after a resync are not silently skipped
        //   • install-status toggling (installed/update) still propagates correctly
        let newID = combined.reduce(combined.count &* 2_654_435_761) { acc, g in
            acc &+ (g.id.hashValue
                ^ g.version.hashValue
                ^ g.installStatus.hashValue
                ^ (g.isDeviceOnly ? 1 : 0)
                ^ (g.hasUpdate == true ? 2 : 0))
        }
        guard newID != lastSourceID else { return }
        lastSourceID = newID
        sourceGames = combined
        triggerRecompute(source: "data")
    }

    // MARK: - Debounce

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.triggerRecompute(source: "search")
        }
    }

    // MARK: - Recompute

    private func triggerRecompute(source: String) {
        let query     = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filter    = installFilter
        let sort      = _sortOption
        let ascending = _sortAscending
        let dp        = downloadPath

        if source != "data",
           sort      == lastSortOption,
           ascending == lastSortAscending,
           filter    == lastFilter,
           query     == lastQuery {
            return
        }

        lastSortOption    = sort
        lastSortAscending = ascending
        lastFilter        = filter
        lastQuery         = query

        isRecomputing = true

        if source == "data" {
            let libraryGames = sourceGames.filter { !$0.isDeviceOnly }
            installedCount = libraryGames.count(where: { $0.isInstalled })
            updatesCount   = libraryGames.count(where: { $0.hasUpdate == true })
        }

        let result = Self.computeDisplayList(
            games:        sourceGames,
            query:        query,
            filter:       filter,
            sort:         sort,
            ascending:    ascending,
            downloadPath: dp
        )
        displayedGames = result
        isRecomputing  = false
    }

    // MARK: - Pure computation

    private static func computeDisplayList(
        games:        [GameInfo],
        query:        String,
        filter:       GameInstallFilter,
        sort:         GameSortOption,
        ascending:    Bool,
        downloadPath: String
    ) -> [GameInfo] {

        var result = games

        // 1. Install filter
        switch filter {
        case .all:          break
        case .installed:    result = result.filter { !$0.isDeviceOnly && $0.isInstalled }
        case .updates:      result = result.filter { $0.installStatus == .updateAvailable }
        case .notInstalled: result = result.filter { !$0.isDeviceOnly && $0.installStatus == .notInstalled }
        case .onDeviceOnly: result = result.filter { $0.isDeviceOnly }
        }

        // 2. Search
        if !query.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(query)        ||
                $0.packageName.lowercased().contains(query) ||
                $0.releaseName.lowercased().contains(query)
            }
        }

        // 3. Sort
        result = applySortOption(sort, ascending: ascending, to: result)

        return result
    }

    private static func applySortOption(
        _ option: GameSortOption,
        ascending: Bool,
        to games: [GameInfo]
    ) -> [GameInfo] {
        switch option {
        case .title:
            return games.sorted {
                let cmp = $0.name.localizedStandardCompare($1.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .date:
            return games.sorted {
                ascending ? $0.lastUpdated < $1.lastUpdated : $0.lastUpdated > $1.lastUpdated
            }
        case .downloads:
            return games.sorted {
                ascending ? $0.downloads < $1.downloads : $0.downloads > $1.downloads
            }
        case .size:
            return games.sorted {
                ascending ? $0.sizeInMB < $1.sizeInMB : $0.sizeInMB > $1.sizeInMB
            }
        case .recentlyAdded:
            return games.sorted { $0.lastUpdated > $1.lastUpdated }
        }
    }
}

// MARK: - GameInfo helpers (filter logic)

extension GameInfo {
    /// Returns true if the game was updated in the last 14 days.
    var isRecentlyUpdated: Bool {
        guard let date = parsedDate else { return false }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day.map { $0 <= 14 } ?? false
    }

    /// True for packages on the device that are not in the VRP library.
    var isDeviceOnly: Bool {
        downloads == 0 && size.isEmpty && lastUpdated.isEmpty && releaseName.isEmpty
    }
}
