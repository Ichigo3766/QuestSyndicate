
//
//  Extensions.swift
//  QuestSyndicate
//

import Foundation
import SwiftUI

// MARK: - FileManager helpers

extension FileManager {
    nonisolated func createDirectoryIfNeeded(at url: URL) throws {
        if !fileExists(atPath: url.path) {
            try createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - String helpers

extension String {
    /// Trims whitespace and newlines
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Base64-decode and return as UTF-8 string
    nonisolated var base64Decoded: String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns true if string matches a Quest device codename
    nonisolated var isQuestCodename: Bool {
        Constants.questModels.contains(lowercased())
    }
}

// MARK: - Date helpers

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var mediumFormatted: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: self)
    }
}

// MARK: - Color helpers

extension Color {
    static var surfaceBackground: Color { Color(NSColor.controlBackgroundColor) }
    static var separatorColor: Color { Color(NSColor.separatorColor) }
    static var tertiaryLabel: Color { Color(NSColor.tertiaryLabelColor) }
}

// MARK: - View helpers

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }

    /// Rounded-rect card — uses Liquid Glass on macOS 26+, falls back to premium material.
    func cardStyle(cornerRadius: CGFloat = 10) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
            }
        }
    }

    /// Section-level card — 12 pt corner radius.
    func sectionCard() -> some View {
        cardStyle(cornerRadius: 12)
    }

    // ── Liquid Glass helpers (macOS 26+ native, premium fallback on earlier) ──────

    /// Standard glass card with configurable corner radius.
    /// On macOS 26: native Liquid Glass. On earlier: thin material + border + subtle shadow.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
        }
    }

    /// Glass capsule.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }

    /// Glass circle.
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
        }
    }

    /// Tinted glass card — coloured tint on macOS 26+.
    /// On earlier macOS: solid color background for good contrast.
    @ViewBuilder
    func glassTinted(_ color: Color, cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(color), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(color.opacity(0.50), lineWidth: 0.75)
                )
        }
    }

    /// Tinted glass capsule — coloured tint on macOS 26+.
    @ViewBuilder
    func glassCapsuleTinted(_ color: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(color), in: .capsule)
        } else {
            self
                .background(color, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(color.opacity(0.50), lineWidth: 0.75)
                )
        }
    }

    /// Subtle (clear) glass card — for search bars / secondary controls.
    @ViewBuilder
    func glassClear(cornerRadius: CGFloat = 9) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    /// Subtle tinted clear-glass capsule.
    @ViewBuilder
    func glassClearCapsuleTinted(_ color: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear.tint(color), in: .capsule)
        } else {
            self
                .background(color.opacity(0.12), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

    /// Interactive glass card — adds `.interactive()` on macOS 26+ for clickable cards.
    @ViewBuilder
    func glassInteractive(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
        }
    }
}

// MARK: - Double helpers

extension Double {
    var progressClamped: Double { max(0, min(100, self)) }

    var asPercentFraction: Double { self / 100.0 }
}

// MARK: - Process helpers

extension Process {
    static func which(_ name: String) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmed
        return result?.isEmpty == false ? result : nil
    }
}
