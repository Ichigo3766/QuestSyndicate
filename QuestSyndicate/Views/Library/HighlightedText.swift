//
//  HighlightedText.swift
//  QuestSyndicate
//
//  Renders text with highlighted ranges matching a search query.
//  Falls back to plain Text when no query is present.
//

import SwiftUI

// MARK: - HighlightedText

struct HighlightedText: View {

    let text: String
    let query: String
    var baseFont: Font = .body
    var highlightColor: Color = .accentColor
    var highlightBackground: Color = .accentColor.opacity(0.18)

    // P1-5: Cache the AttributedString so it is only recomputed when text or query changes,
    // not on every body evaluation during scrolling.
    @State private var cachedAttributed: AttributedString? = nil
    @State private var cachedKey: String = ""

    var body: some View {
        if query.isEmpty {
            Text(text)
                .font(baseFont)
        } else {
            let key = "\(text)||||\(query)"
            Text(resolvedAttributed(key: key))
                .font(baseFont)
                .onChange(of: key) { _, newKey in
                    // Invalidate cache when text or query changes
                    cachedKey = newKey
                    cachedAttributed = buildAttributedString()
                }
                .onAppear {
                    if cachedKey != key {
                        cachedKey = key
                        cachedAttributed = buildAttributedString()
                    }
                }
        }
    }

    private func resolvedAttributed(key: String) -> AttributedString {
        if cachedKey == key, let cached = cachedAttributed { return cached }
        return buildAttributedString()
    }

    // MARK: - Attributed String

    private func buildAttributedString() -> AttributedString {
        var attributed = AttributedString(text)

        let queryLower = query.lowercased()
        let textLower  = text.lowercased()

        // Walk through all occurrences of the query in the text.
        var searchRange = textLower.startIndex..<textLower.endIndex
        while let range = textLower.range(of: queryLower, range: searchRange) {
            // Map String.Index range → AttributedString range
            if let attrRange = AttributedString.Index(range.lowerBound, within: attributed)
                .flatMap({ lower in
                    AttributedString.Index(range.upperBound, within: attributed)
                        .map { upper in lower..<upper }
                }) {
                attributed[attrRange].foregroundColor = NSColor(highlightColor)
                attributed[attrRange].backgroundColor = NSColor(highlightBackground)
                // Bold the matched text using SwiftUI font attribute (Sendable-safe)
                var container = AttributeContainer()
                container.inlinePresentationIntent = .stronglyEmphasized
                attributed[attrRange].mergeAttributes(container)
            }

            // Advance past this match.
            searchRange = range.upperBound..<textLower.endIndex
        }

        return attributed
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        HighlightedText(text: "Asgard's Wrath 2", query: "wrath")
        HighlightedText(text: "com.meta.asgardswrath2", query: "asgards", baseFont: .caption)
        HighlightedText(text: "No match here", query: "xyz")
        HighlightedText(text: "Plain text, no query", query: "")
    }
    .padding()
}
#endif
