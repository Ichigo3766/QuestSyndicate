
//
//  INIParser.swift
//  QuestSyndicate
//
//  Lightweight INI/rclone config parser

import Foundation

struct INIParser {
    typealias Section = [String: String]
    typealias Config  = [String: Section]

    // MARK: - Parse

    /// Parse an INI-format string and return a dictionary of section → key/value pairs.
    static func parse(_ content: String) -> Config {
        var result: Config = [:]
        var currentSection = ""

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }

            // Section header  [SectionName]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                if result[currentSection] == nil {
                    result[currentSection] = [:]
                }
                continue
            }

            // Key = Value
            if let equalsRange = line.range(of: "=") {
                let key   = line[line.startIndex..<equalsRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = line[equalsRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    result[currentSection, default: [:]][key] = value
                }
            }
        }
        return result
    }

    // MARK: - Serialize

    /// Serialize a Config dictionary back to INI format string.
    static func serialize(_ config: Config) -> String {
        var lines: [String] = []
        for (section, kvPairs) in config.sorted(by: { $0.key < $1.key }) {
            if !section.isEmpty {
                lines.append("[\(section)]")
            }
            for (key, value) in kvPairs.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key) = \(value)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - rclone-specific helpers

    /// Extract the first section from rclone config content and return remote name + options.
    static func parseRcloneConfig(_ content: String) -> (remoteName: String, options: [String: String])? {
        let config = parse(content)
        guard let first = config.first else { return nil }
        return (first.key, first.value)
    }

    /// Build a minimal rclone config file string for a given remote name and key/value options.
    nonisolated static func buildRcloneConfig(remoteName: String, options: [String: String]) -> String {
        var lines = ["[\(remoteName)]"]
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key) = \(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
