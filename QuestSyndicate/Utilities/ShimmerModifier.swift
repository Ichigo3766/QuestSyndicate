//
//  ShimmerModifier.swift
//  QuestSyndicate
//
//  Reusable shimmer / skeleton-loading animation for macOS SwiftUI.
//

import SwiftUI

// MARK: - ShimmerModifier

// P2-12: Lazy shimmer — animation only runs while the view is on screen.
struct ShimmerModifier: ViewModifier {

    @State private var phase: CGFloat = -1.0

    var duration: Double
    var bounce: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    shimmerGradient(width: width)
                        .offset(x: phase * width * 2)
                        .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .clipped()
            )
            .onAppear {
                // P2-12: Start animation only when visible
                withAnimation(
                    .linear(duration: duration)
                    .repeatForever(autoreverses: bounce)
                ) {
                    phase = 1.0
                }
            }
            .onDisappear {
                // P2-12: Reset phase so the animation timer is released when off-screen
                phase = -1.0
            }
    }

    private func shimmerGradient(width: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear,                               location: 0.0),
                .init(color: .white.opacity(0.08),                 location: 0.4),
                .init(color: .white.opacity(0.18),                 location: 0.5),
                .init(color: .white.opacity(0.08),                 location: 0.6),
                .init(color: .clear,                               location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width * 3)
        .offset(x: -width)
    }
}

// MARK: - View Extension

extension View {
    /// Applies a continuous shimmer overlay — perfect for skeleton / placeholder states.
    /// - Parameters:
    ///   - active: Only applies the shimmer when `true`. Defaults to `true`.
    ///   - duration: Sweep duration in seconds. Defaults to `1.4`.
    ///   - bounce: Whether the animation reverses. Defaults to `false` for a one-directional sweep.
    @ViewBuilder
    func shimmer(active: Bool = true, duration: Double = 1.4, bounce: Bool = false) -> some View {
        if active {
            self.modifier(ShimmerModifier(duration: duration, bounce: bounce))
        } else {
            self
        }
    }
}

// MARK: - SkeletonBox

/// A simple rounded rectangle placeholder that shimmers — drop-in for any loading state.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = 8
    var color: Color = Color(NSColor.controlBackgroundColor)

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .shimmer()
    }
}

// MARK: - SkeletonGameRow

/// A full-width skeleton row that mimics the real game card layout during initial load.
struct SkeletonGameRow: View {

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail placeholder
            SkeletonBox(cornerRadius: 10)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                // Title line
                SkeletonBox(cornerRadius: 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 13)
                    .padding(.trailing, 80)

                // Subtitle line
                SkeletonBox(cornerRadius: 5)
                    .frame(height: 10)
                    .frame(maxWidth: 180)

                // Badge row
                HStack(spacing: 6) {
                    SkeletonBox(cornerRadius: 5).frame(width: 60, height: 18)
                    SkeletonBox(cornerRadius: 5).frame(width: 50, height: 18)
                }
            }

            Spacer()

            // Action button placeholder
            SkeletonBox(cornerRadius: 8).frame(width: 80, height: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
