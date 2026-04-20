
//
//  MirrorService.swift
//  QuestSyndicate
//
//  Manages rclone mirror configurations
//

import Foundation

@Observable
final class MirrorService {

    var mirrors: [Mirror] = []
    var activeMirror: Mirror?

    private let rclone: RcloneService
    private let mirrorsPath = Constants.mirrorsConfigPath

    init(rclone: RcloneService) {
        self.rclone = rclone
    }

    func load() {
        guard let data = try? Data(contentsOf: mirrorsPath),
              let saved = try? JSONDecoder().decode([Mirror].self, from: data) else { return }
        mirrors = saved
        activeMirror = mirrors.first(where: { $0.isActive })
    }

    // MARK: - Add Mirror

    func addMirror(configContent: String) async -> Bool {
        guard let (remoteName, options) = INIParser.parseRcloneConfig(configContent) else {
            return false
        }
        let config = MirrorConfig(id: UUID().uuidString, name: remoteName, type: options["type"] ?? "unknown", host: options["host"] ?? "")
        let newMirror = Mirror(name: remoteName, config: config)

        // Write the config file
        let configURL = Constants.mirrorsDirectory.appendingPathComponent("\(newMirror.id).conf")
        do {
            try configContent.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        mirrors.append(newMirror)
        save()
        return true
    }

    func removeMirror(id: String) {
        if activeMirror?.id == id { activeMirror = nil }
        mirrors.removeAll { $0.id == id }
        let configURL = Constants.mirrorsDirectory.appendingPathComponent("\(id).conf")
        try? FileManager.default.removeItem(at: configURL)
        save()
    }

    func setActiveMirror(id: String) {
        for i in mirrors.indices { mirrors[i].isActive = mirrors[i].id == id }
        activeMirror = mirrors.first(where: { $0.id == id })
        save()
    }

    func clearActiveMirror() {
        for i in mirrors.indices { mirrors[i].isActive = false }
        activeMirror = nil
        save()
    }

    // MARK: - Test

    func testMirror(id: String) async -> MirrorTestResult {
        guard let idx = mirrors.firstIndex(where: { $0.id == id }) else {
            return MirrorTestResult(id: id, success: false, error: "Not found", timestamp: Date())
        }
        mirrors[idx].testStatus = .testing

        let configURL = Constants.mirrorsDirectory.appendingPathComponent("\(id).conf")
        let remoteName = mirrors[idx].name

        do {
            let elapsed = try await rclone.testMirror(
                remoteName: remoteName,
                configPath: configURL.path
            )
            mirrors[idx].testStatus = .success
            mirrors[idx].lastTested = Date()
            save()
            return MirrorTestResult(id: id, success: true, responseTime: elapsed, timestamp: Date())
        } catch {
            mirrors[idx].testStatus = .failed
            mirrors[idx].testError = error.localizedDescription
            save()
            return MirrorTestResult(id: id, success: false, error: error.localizedDescription, timestamp: Date())
        }
    }

    func testAllMirrors() async -> [MirrorTestResult] {
        await withTaskGroup(of: MirrorTestResult.self) { group in
            for mirror in mirrors {
                group.addTask { await self.testMirror(id: mirror.id) }
            }
            var results: [MirrorTestResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: - Active Mirror Config Path

    func getActiveMirrorConfigPath() -> String? {
        guard let active = activeMirror else { return nil }
        return Constants.mirrorsDirectory.appendingPathComponent("\(active.id).conf").path
    }

    func getActiveMirrorRemoteName() -> String? {
        activeMirror?.name
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(mirrors) {
            try? data.write(to: mirrorsPath)
        }
    }
}
