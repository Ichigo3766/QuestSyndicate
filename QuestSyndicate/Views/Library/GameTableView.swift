//
//  GameTableView.swift
//  QuestSyndicate
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LibraryViewMode

enum LibraryViewMode: String {
    case grid = "grid"
    case list = "list"
}

// MARK: - GameTableView

struct GameTableView: View {

    @Environment(AppState.self) private var appState

    @State private var listVM = GameListViewModel()
    @State private var selectedGame: GameInfo? = nil
    @State private var isRefreshing = false
    @State private var showScrollToTop = false
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var pressedGameID: String? = nil
    @State private var uninstallTarget: GameInfo? = nil
    @State private var showUninstallConfirm = false
    @State private var isUninstalling = false
    @State private var showRemoteSourceBar = true

    @AppStorage("libraryViewMode") private var viewModeRaw: String = LibraryViewMode.grid.rawValue

    private var viewMode: LibraryViewMode {
        LibraryViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private let topAnchorID = "gameListTop"

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Page header with title + action buttons
            pageHeader
            Divider().opacity(0.4)

            // Remote source info bar
            if showRemoteSourceBar {
                remoteSourceBar
                Divider().opacity(0.3)
            }

            // Search + controls toolbar
            toolbarArea
            Divider().opacity(0.4)

            // Filter bar
            filterBar
            Divider().opacity(0.25)

            // Main content
            mainContent
        }
        .sheet(item: $selectedGame) { game in
            GameDetailSheet(game: game)
                .environment(appState)
        }
        .confirmationDialog(
            "Uninstall \"\(uninstallTarget?.name ?? "this app")\"?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let game = uninstallTarget { performUninstall(game) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the app, OBB data, and save data from \(appState.selectedDevice?.displayName ?? "the device").")
        }
        .overlay {
            if let prog = appState.exportProgress {
                ExportProgressOverlay(progress: prog) {
                    appState.exportProgress = nil
                }
            }
        }
        .onChange(of: appState.gameLibrary.games)    { _, _ in syncVM() }
        .onChange(of: appState.deviceOnlyGames)      { _, _ in syncVM() }
        .onAppear { syncVM() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .showOnDeviceOnly)) { _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                listVM.installFilter = .onDeviceOnly
            }
        }
    }

    // MARK: - Sync VM

    private func syncVM() {
        let downloadPath = UserDefaults.standard.string(forKey: "downloadPath") ?? ""
        listVM.update(
            games: appState.gameLibrary.games,
            deviceOnlyGames: appState.deviceOnlyGames,
            downloadPath: downloadPath
        )
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            // Title block
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Apps & Games")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                }
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                headerActionButton(
                    title: "Install APK",
                    icon: "plus.app",
                    color: .accentColor
                ) {
                    // handled via drag-and-drop; open file picker
                    openAPKFilePicker()
                }

                headerActionButton(
                    title: "Re-Scan",
                    icon: "arrow.clockwise",
                    color: .secondary
                ) {
                    Task { await forceSync() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        let total = appState.gameLibrary.games.count
        // P0-2: Read pre-computed counts — no per-render array scan
        let installed = listVM.installedCount
        let updates   = listVM.updatesCount
        if total == 0 { return "No games loaded — sync your library" }
        var parts = ["\(total) titles"]
        if installed > 0 { parts.append("\(installed) installed") }
        if updates > 0   { parts.append("\(updates) updates") }
        return parts.joined(separator: " · ")
    }

    private func headerActionButton(
        title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(color == .secondary ? Color.primary.opacity(0.8) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .if(color != .secondary) { $0.glassCapsuleTinted(color) }
            .if(color == .secondary) { $0.glassCapsule() }
        }
        .buttonStyle(.plain)
    }

    private func openAPKFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "apk")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select APK files or a game folder to install"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            // Notify ContentView to handle install via drop pipeline
            NotificationCenter.default.post(
                name: .installManualFiles,
                object: panel.urls
            )
        }
    }

    // MARK: - Remote Source Bar

    private var remoteSourceBar: some View {
        HStack(spacing: 0) {
            // Source label
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.gameLibrary.games.isEmpty ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: (appState.gameLibrary.games.isEmpty ? Color.orange : Color.green).opacity(0.6), radius: 3)
                Text("REMOTE SOURCE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                if appState.gameLibrary.vrpConfig != nil {
                    Text("VrSrc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14)

            Divider().frame(height: 20).opacity(0.4)

            remoteStatPill("STATUS", appState.gameLibrary.games.isEmpty ? "Syncing" : "Ready",
                           color: appState.gameLibrary.games.isEmpty ? .orange : .green)
            remoteStatPill("CATALOG", "\(appState.gameLibrary.games.count)", color: .accentColor)
            // P0-2: Use pre-computed counts from listVM — no per-render array scan
            remoteStatPill("UPDATES", "\(listVM.updatesCount)", color: .orange)
            remoteStatPill("ON DEVICE", "\(listVM.installedCount)", color: .green)

            Spacer()
        }
        .frame(height: 36)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }

    private func remoteStatPill(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.5)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Toolbar Area

    private var toolbarArea: some View {
        HStack(spacing: 8) {
            searchBar
            Spacer(minLength: 4)
            sortMenu
            viewToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            TextField("Search games, packages, release names…", text: $listVM.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Search game library")
            if !listVM.searchText.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { listVM.searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassClear(cornerRadius: 10)
        .frame(maxWidth: 440)
        .animation(.easeInOut(duration: 0.15), value: listVM.searchText.isEmpty)
    }

    // MARK: Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(GameSortOption.allCases) { option in
                Button {
                    listVM.sortOption = option
                } label: {
                    // Show a direction arrow next to the active option
                    if listVM.sortOption == option {
                        let dirIcon: String = {
                            guard option != .recentlyAdded else { return "checkmark" }
                            return listVM.sortAscending ? "arrow.up" : "arrow.down"
                        }()
                        Label(option.rawValue, systemImage: option.systemImage)
                        Image(systemName: dirIcon)
                    } else {
                        Label(option.rawValue, systemImage: option.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: listVM.sortOption.systemImage)
                    .font(.system(size: 13))
                if listVM.sortOption != .recentlyAdded {
                    Image(systemName: listVM.sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 32)
            .padding(.horizontal, 6)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .glassClear(cornerRadius: 10)
        .fixedSize()
        .help("Sort — tap again to reverse")
    }

    // MARK: View Toggle (Grid / List)

    private var viewToggle: some View {
        HStack(spacing: 0) {
            ForEach([
                (LibraryViewMode.grid, "square.grid.2x2"),
                (LibraryViewMode.list, "list.bullet")
            ], id: \.0.rawValue) { mode, icon in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        viewModeRaw = mode.rawValue
                    }
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(viewMode == mode ? .white : .secondary)
                        .frame(width: 34, height: 28)
                        .background(
                            viewMode == mode ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(mode == .grid ? "Grid view" : "List view")
            }
        }
        .padding(3)
        .glassClear(cornerRadius: 10)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(GameInstallFilter.allCases) { filter in
                    FilterChipView(
                        title: filter.rawValue,
                        icon: filter.systemImage,
                        accentColor: filter.accentColor,
                        isSelected: listVM.installFilter == filter,
                        count: filterCount(for: filter)
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            listVM.installFilter = filter
                        }
                    }
                }
                Divider().frame(height: 20).padding(.horizontal, 2)
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: listVM.displayedGames.count)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
    }

    private func filterCount(for filter: GameInstallFilter) -> Int? {
        switch filter {
        case .all:          return nil
        // Use pre-computed counts from the view model — avoids re-scanning the full
        // game array (potentially thousands of items) on every filter-bar render.
        case .installed:    return listVM.installedCount > 0 ? listVM.installedCount : nil
        case .updates:      return listVM.updatesCount > 0   ? listVM.updatesCount   : nil
        case .notInstalled: return nil
        case .onDeviceOnly: return appState.deviceOnlyGames.count > 0 ? appState.deviceOnlyGames.count : nil
        }
    }

    private var countLabel: String {
        let n = listVM.displayedGames.count
        return "\(n) game\(n == 1 ? "" : "s")"
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if appState.gameLibrary.isLoading {
            skeletonView
        } else if appState.gameLibrary.games.isEmpty {
            emptyLibraryView
        } else if listVM.displayedGames.isEmpty && !listVM.isRecomputing {
            noResultsView
        } else if viewMode == .grid {
            gridContent
        } else {
            listContent
        }
    }

    // MARK: - Grid

    private var gridContent: some View {
        // Pre-compute the queue set once for the whole grid, rather than
        // letting every GameGridCard scan the queue array independently.
        let queuedReleaseNames = Set(
            appState.pipeline.queue
                .filter { $0.status == .queued || $0.status.isActive }
                .map { $0.releaseName }
        )

        return ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Color.clear.frame(height: 1).id(topAnchorID)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 185, maximum: 230), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(listVM.displayedGames) { game in
                            GameGridCard(
                                game: game,
                                isPressed: pressedGameID == game.id,
                                inQueue: queuedReleaseNames.contains(game.releaseName)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onTapGesture { openDetail(game) }
                            .simultaneousGesture(pressGesture(for: game.id))
                            .contextMenu { contextMenu(for: game) }
                            .accessibilityLabel(a11yLabel(game))
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16).padding(.bottom, 60)
                    // Rasterise the entire grid onto a single Metal layer during scrolling,
                    // which eliminates per-card compositing overhead dramatically.
                    .drawingGroup()
                }
                .onAppear { scrollProxy = proxy }
                .background(scrollOffsetReader)
                .coordinateSpace(name: "libraryScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { handleScrollOffset($0) }
            }
            scrollToTopFAB
        }
    }

    // MARK: - List

    private var listContent: some View {
        // Pre-compute the queue set once for the whole list — same pattern as gridContent.
        // Without this, every GameListRow computes `inQueue` by scanning the queue array,
        // giving O(rows × queue) work on each render pass.
        let queuedReleaseNames = Set(
            appState.pipeline.queue
                .filter { $0.status == .queued || $0.status.isActive }
                .map { $0.releaseName }
        )

        return ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Color.clear.frame(height: 1).id(topAnchorID)
                    LazyVStack(spacing: 0) {
                        ForEach(listVM.displayedGames) { game in
                            GameListRow(
                                game: game,
                                searchQuery: listVM.searchText.trimmingCharacters(in: .whitespaces),
                                isPressed: pressedGameID == game.id,
                                inQueue: queuedReleaseNames.contains(game.releaseName)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { openDetail(game) }
                            .simultaneousGesture(pressGesture(for: game.id))
                            .contextMenu { contextMenu(for: game) }
                            .accessibilityLabel(a11yLabel(game))
                            .accessibilityAddTraits(.isButton)
                            if game.id != listVM.displayedGames.last?.id {
                                Divider().padding(.leading, 88)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }
                .onAppear { scrollProxy = proxy }
                .background(scrollOffsetReader)
                .coordinateSpace(name: "libraryScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { handleScrollOffset($0) }
            }
            scrollToTopFAB
        }
    }

    // MARK: - Scroll helpers

    private var scrollOffsetReader: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetPreferenceKey.self,
                value: geo.frame(in: .named("libraryScroll")).minY
            )
        }
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        // Hysteresis — only toggle the FAB when we cross a meaningful threshold.
        // This means the preference change only triggers a SwiftUI state update
        // (and a re-render) twice per scroll session (once to show, once to hide),
        // instead of on every single 120 Hz frame.
        let should: Bool
        if showScrollToTop {
            should = offset < -100   // visible → keep showing until nearly back at top
        } else {
            should = offset < -200   // hidden  → only appear after scrolling well past top
        }
        guard should != showScrollToTop else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showScrollToTop = should }
    }

    @ViewBuilder
    private var scrollToTopFAB: some View {
        if showScrollToTop {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    scrollProxy?.scrollTo(topAnchorID, anchor: .top)
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 22).padding(.bottom, 22)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.7).combined(with: .opacity),
                removal:   .scale(scale: 0.7).combined(with: .opacity)
            ))
            .accessibilityLabel("Scroll to top")
        }
    }

    // MARK: - Skeleton

    @ViewBuilder
    private var skeletonView: some View {
        if viewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 230), spacing: 14)], spacing: 14) {
                    ForEach(0..<12, id: \.self) { _ in SkeletonGridCard() }
                }
                .padding(18)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonGameRow()
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }

    // MARK: - Empty / No Results

    private var emptyLibraryView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 44)).foregroundStyle(Color.accentColor.opacity(0.5))
            }
            VStack(spacing: 8) {
                Text("No Games Found")
                    .font(.title2).fontWeight(.bold)
                Text("Sync the library or add your VRP configuration in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            Button("Sync Now") { Task { await forceSync() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 90, height: 90)
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 44)).foregroundStyle(Color.secondary.opacity(0.4))
            }
            VStack(spacing: 8) {
                Text("No Results").font(.title2).fontWeight(.bold)
                if !listVM.searchText.isEmpty {
                    Text("No games matched \"\(listVM.searchText)\"")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Try a different filter or search.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Button("Clear Search & Filters") {
                withAnimation { listVM.searchText = ""; listVM.installFilter = .all }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for game: GameInfo) -> some View {
        Button("View Details") { openDetail(game) }
        Divider()
        if !game.isDeviceOnly {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(appState.pipeline.queue.contains { $0.releaseName == game.releaseName })
        }
        if game.isInstalled && !game.isDeviceOnly {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                Label("Re-install", systemImage: "arrow.clockwise.circle")
            }
            .disabled(appState.pipeline.queue.contains {
                $0.releaseName == game.releaseName && $0.status != .completed && $0.status != .installError
            })
        }
        if (game.isInstalled || game.isDeviceOnly) && appState.selectedDevice != nil {
            Button {
                appState.exportGame(game)
            } label: {
                Label("Export APK to Computer…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                uninstallTarget = game
                showUninstallConfirm = true
            } label: {
                Label("Uninstall from \(appState.selectedDevice?.displayName ?? "Device")", systemImage: "trash")
            }
        }
        Divider()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(game.packageName, forType: .string)
        } label: {
            Label("Copy Package Name", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Helpers

    private func pressGesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.07)) { pressedGameID = id } }
            .onEnded   { _ in withAnimation(.spring(response: 0.3))  { pressedGameID = nil } }
    }

    private func openDetail(_ game: GameInfo) { selectedGame = game }

    private func performUninstall(_ game: GameInfo) {
        isUninstalling = true
        Task {
            do {
                try await appState.uninstallGame(game)
            } catch {
                appState.showError("Failed to uninstall \(game.name): \(error.localizedDescription)")
            }
            isUninstalling = false
        }
    }

    private func forceSync() async {
        isRefreshing = true
        let mirrorPath   = appState.mirrors.getActiveMirrorConfigPath()
        let mirrorRemote = appState.mirrors.getActiveMirrorRemoteName()
        do {
            try await appState.gameLibrary.forceSync(
                mirrorConfigPath: mirrorPath,
                activeMirrorRemote: mirrorRemote
            )
            appState.configurePipeline()
            appState.refreshInstalledStatus()
        } catch {
            appState.showError("Library sync failed: \(error.localizedDescription)")
        }
        isRefreshing = false
    }

    private func a11yLabel(_ game: GameInfo) -> String {
        var parts = [game.name.isEmpty ? game.packageName : game.name]
        parts.append(game.isDeviceOnly ? "Device Only" : game.installStatus.label)
        if game.isRecentlyUpdated && !game.isDeviceOnly { parts.append("New") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - FilterChipView

private struct FilterChipView: View {
    let title: String
    let icon: String
    let accentColor: Color
    let isSelected: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            isSelected ? Color.white.opacity(0.20) : Color(NSColor.controlBackgroundColor),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : Color.primary.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .if(isSelected) { $0.glassCapsuleTinted(accentColor) }
            .if(!isSelected) { $0.glassCapsule() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) filter\(isSelected ? ", selected" : "")")
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - GameGridCard

struct GameGridCard: View, Equatable {
    let game: GameInfo
    var isPressed: Bool = false
    /// Pre-computed by the parent grid so every card doesn't scan the queue array itself.
    var inQueue: Bool = false

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    // Equatable — only redraw when the data driving the card actually changes.
    static func == (lhs: GameGridCard, rhs: GameGridCard) -> Bool {
        lhs.game        == rhs.game   &&
        lhs.isPressed   == rhs.isPressed &&
        lhs.inQueue     == rhs.inQueue
    }

    // Accent color driven by install status
    private var statusColor: Color {
        if game.isDeviceOnly { return .purple }
        switch game.installStatus {
        case .installed:       return .green
        case .updateAvailable: return .orange
        case .notInstalled:    return Color.accentColor
        }
    }

    private var serverThumbnailURL: URL? {
        guard let base = appState.gameLibrary.vrpConfig?.baseUri,
              !base.isEmpty else { return nil }
        let clean = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(clean)/.meta/thumbnails/\(game.packageName).jpg")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── App-icon style thumbnail ──────────────────────────────
            iconArea

            // ── Info area ────────────────────────────────────────────
            infoArea
        }
        // Single material + single border: eliminates the duplicate compositing pass.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isHovering
                        ? statusColor.opacity(0.45)
                        : Color(NSColor.separatorColor).opacity(0.28),
                    lineWidth: 1
                )
        )
        // compositingGroup() flattens material + content into one layer before the shadow
        // pass — prevents each card from triggering separate compositing.
        .compositingGroup()
        // Static shadow: avoids re-compositing every card on every mouse-move event.
        // Hover effect is communicated through border color + scale only.
        .shadow(color: .black.opacity(0.09), radius: 7, x: 0, y: 3)
        .scaleEffect(isPressed ? 0.97 : (isHovering ? 1.02 : 1.0))
        .opacity(isPressed ? 0.88 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.72), value: isPressed)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isHovering)
    }

    // MARK: Icon Area

    private var iconArea: some View {
        ZStack {
            // Plain solid background — avoids an extra Gaussian-blur material pass
            // on top of the card's own .regularMaterial background.
            Rectangle()
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    LinearGradient(
                        colors: [statusColor.opacity(0.07), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // The actual icon — fills and clips perfectly like an app icon.
            // 200 pt target (400 px @ 2×) is sufficient for a 185-230 pt card.
            AsyncThumbnailView(
                thumbnailPath: game.thumbnailPath,
                cornerRadius: 18,
                targetSize: CGSize(width: 200, height: 200),
                fallbackURL: serverThumbnailURL,
                fillFrame: true
            )
            .frame(width: 140, height: 140)
            // Subtle inner border on the icon itself
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )

            // "NEW" badge — top-right of icon area
            if game.isRecentlyUpdated && !game.isDeviceOnly {
                VStack {
                    HStack {
                        Spacer()
                        Text("NEW")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .padding(.top, 10).padding(.trailing, 10)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipped()
    }

    // MARK: Info Area

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Divider line
            Divider().opacity(0.3)

            VStack(alignment: .leading, spacing: 6) {
                // Game title
                Text(game.name.isEmpty ? game.packageName : game.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Metadata row + action button
                HStack(alignment: .center, spacing: 6) {
                    // Size / status metadata
                    metaLine
                    Spacer(minLength: 4)
                    // Action button
                    actionButton
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        if game.isDeviceOnly {
            HStack(spacing: 4) {
                Circle().fill(Color.purple).frame(width: 5, height: 5)
                Text("On Device")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.purple)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if !game.formattedSize.isEmpty {
                        Text(game.formattedSize)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if game.isInstalled || game.installStatus == .updateAvailable {
                        HStack(spacing: 3) {
                            Circle().fill(statusColor).frame(width: 5, height: 5)
                            Text(game.installStatus == .updateAvailable ? "Update" : "Installed")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                }
                if !game.formattedLastUpdated.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(game.formattedLastUpdated)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if game.isDeviceOnly {
            EmptyView()
        } else if inQueue {
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 8))
                Text("Queued")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
        } else if game.installStatus == .updateAvailable {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                    Text("Update")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {})
        } else if game.isInstalled {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Installed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
        } else {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                    Text("Get")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {})
        }
    }
}

// MARK: - GameListRow

struct GameListRow: View {
    let game: GameInfo
    let searchQuery: String
    var isPressed: Bool = false
    /// Pre-computed by the parent list so each row doesn't scan the queue array itself.
    var inQueue: Bool = false

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private var serverThumbnailURL: URL? {
        guard let base = appState.gameLibrary.vrpConfig?.baseUri,
              !base.isEmpty else { return nil }
        let clean = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(clean)/.meta/thumbnails/\(game.packageName).jpg")
    }

    var body: some View {
        HStack(spacing: 14) {
            AsyncThumbnailView(
                thumbnailPath: game.thumbnailPath,
                cornerRadius: 10,
                targetSize: CGSize(width: 112, height: 112),
                fallbackURL: serverThumbnailURL
            )
            .frame(width: 58, height: 58)
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    HighlightedText(
                        text: game.name.isEmpty ? game.packageName : game.name,
                        query: searchQuery, baseFont: .headline
                    ).lineLimit(1)
                    if game.isRecentlyUpdated && !game.isDeviceOnly { NewBadge() }
                    if game.isDeviceOnly {
                        Text("DEVICE ONLY")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.purple, in: Capsule())
                    }
                }
                HighlightedText(text: game.packageName, query: searchQuery, baseFont: .caption2)
                    .foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    if !game.isDeviceOnly {
                        metaBadge(game.formattedSize, icon: "arrow.down.doc")
                        metaBadge(game.formattedLastUpdated, icon: "calendar")
                    }
                    InstallStatusBadge(status: game.installStatus, isDeviceOnly: game.isDeviceOnly)
                }
            }
            Spacer(minLength: 8)
            rowAction
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        .scaleEffect(isPressed ? 0.985 : 1.0)
        .opacity(isPressed ? 0.88 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private func metaBadge(_ text: String, icon: String?) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.tertiary) }
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    @ViewBuilder
    private var rowAction: some View {
        if game.isDeviceOnly {
            Image(systemName: "ellipsis.circle").font(.callout).foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
        } else if game.isInstalled {
            EmptyView()
        } else if inQueue {
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.caption)
                Text("Queued").font(.caption).fontWeight(.medium)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
        } else {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").font(.callout)
                    Text("Get").font(.callout).fontWeight(.semibold)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - NewBadge

struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel("New")
    }
}

// MARK: - InstallStatusBadge

struct InstallStatusBadge: View {
    let status: GameInfo.InstallStatus
    var isDeviceOnly: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(badgeColor).frame(width: 5, height: 5)
            Text(badgeLabel).font(.caption2).foregroundStyle(badgeColor)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(badgeColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(badgeColor.opacity(0.25), lineWidth: 0.5))
        .accessibilityLabel(isDeviceOnly ? "Device Only" : status.label)
    }

    private var badgeLabel: String {
        if isDeviceOnly { return "Device Only" }
        switch status {
        case .installed:       return "Installed"
        case .updateAvailable: return "Update"
        case .notInstalled:    return "Available"
        }
    }

    private var badgeColor: Color {
        if isDeviceOnly { return .purple }
        switch status {
        case .installed:       return .green
        case .updateAvailable: return .orange
        case .notInstalled:    return .secondary
        }
    }
}

// MARK: - SkeletonGridCard

private struct SkeletonGridCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon area background
            ZStack {
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .frame(height: 140)

                // Centered icon placeholder
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shimmer()
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)

            // Divider
            Divider().opacity(0.3)

            // Info area
            VStack(alignment: .leading, spacing: 8) {
                // Title line
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shimmer()
                    .frame(height: 13)
                    .padding(.trailing, 30)

                // Meta + action row
                HStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shimmer()
                        .frame(width: 52, height: 9)
                    Spacer()
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shimmer()
                        .frame(width: 48, height: 24)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.25), lineWidth: 1)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

// MARK: - ExportProgressOverlay

struct ExportProgressOverlay: View {
    let progress: ExportProgress
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { if progress.isComplete { onDismiss() } }

            VStack(spacing: 18) {
                if progress.isComplete {
                    if let err = progress.error {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 44)).foregroundStyle(.red)
                        Text("Export Failed").font(.title2).fontWeight(.bold)
                        Text(err).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 300)
                    } else {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                        Text("Export Complete").font(.title2).fontWeight(.bold)
                        Text("\(progress.gameName) saved to Finder").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Done", action: onDismiss).buttonStyle(.borderedProminent)
                } else {
                    ProgressView().scaleEffect(1.4).padding(.bottom, 4)
                    Text("Exporting \(progress.gameName)…").font(.title3).fontWeight(.semibold)
                    Text("Pulling APK and OBB data from device").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .glassCard(cornerRadius: 22)
            .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 8)
        }
    }
}

// MARK: - GameActionButton (compat shim)

struct GameActionButton: View {
    @Environment(AppState.self) private var appState
    let game: GameInfo

    var body: some View {
        if appState.pipeline.queue.contains(where: { $0.releaseName == game.releaseName }) {
            Label("Queued", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else {
            Button {
                appState.pipeline.addToQueue(game)
            } label: {
                Label("Download", systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - ScrollOffsetPreferenceKey

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - GameInfo.Comparable

extension GameInfo: Comparable {
    public static func < (lhs: GameInfo, rhs: GameInfo) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

