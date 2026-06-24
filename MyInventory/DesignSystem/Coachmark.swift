//
//  Coachmark.swift
//  MyInventory
//
//  A small, robust coach-mark overlay for the first-run guide: a dimmed scrim
//  with a spotlight cut-out + ring around a target, and an instruction card with
//  a "Next" button. Targets are located with SwiftUI anchor preferences, so a
//  view marks itself a target with `.coachmarkAnchor(.someID)` and the overlay
//  (installed once at the root via `.coachmarks(...)`) resolves the frame.
//
//  Deliberately anchored only to CONTENT elements (sidebar rows, in-list buttons)
//  — toolbar items can't be reliably anchored via preferences. Runs on iPad
//  (regular width); the welcome cards carry the load on compact iPhone.
//

import SwiftUI

enum CoachmarkID: Hashable {
    case addFirst
}

struct CoachmarkStep: Identifiable {
    let id = UUID()
    let target: CoachmarkID
    let title: String
    let message: String
}

// MARK: - Anchor plumbing

struct CoachmarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachmarkID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [CoachmarkID: Anchor<CGRect>],
                       nextValue: () -> [CoachmarkID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a coach-mark target so the overlay can spotlight it.
    func coachmarkAnchor(_ id: CoachmarkID) -> some View {
        anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// Installs the coach-mark overlay. Place once, high in the hierarchy.
    func coachmarks(_ steps: [CoachmarkStep],
                    isActive: Binding<Bool>,
                    onFinish: @escaping () -> Void) -> some View {
        modifier(CoachmarkModifier(steps: steps, isActive: isActive, onFinish: onFinish))
    }
}

// MARK: - Overlay

private struct CoachmarkModifier: ViewModifier {
    let steps: [CoachmarkStep]
    @Binding var isActive: Bool
    var onFinish: () -> Void
    @State private var index = 0

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(CoachmarkAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if isActive {
                    // Only spotlight steps whose target is actually on screen — on
                    // iPad the sidebar collapses in portrait, so a step pointing at
                    // it would otherwise show a target-less (confusing) card.
                    let visible = steps.filter { anchors[$0.target] != nil }
                    Group {
                        if visible.isEmpty {
                            Color.clear.onAppear(perform: finish)
                        } else {
                            let i = min(index, visible.count - 1)
                            overlay(step: visible[i],
                                    rect: proxy[anchors[visible[i].target]!],
                                    position: i + 1, total: visible.count)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
    }

    private func advance(isLast: Bool) {
        if isLast { finish() } else { withAnimation { index += 1 } }
    }

    private func finish() {
        index = 0
        isActive = false
        onFinish()
    }

    private func overlay(step: CoachmarkStep, rect: CGRect,
                         position: Int, total: Int) -> some View {
        ZStack {
            // Dimmed scrim with a spotlight hole over the target.
            ZStack {
                Color.black.opacity(0.6)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .frame(width: rect.width + 18, height: rect.height + 18)
                    .position(x: rect.midX, y: rect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()

            // Highlight ring around the spotlight.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .frame(width: rect.width + 18, height: rect.height + 18)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Instruction card pinned to the screen edge away from the target.
            GeometryReader { proxy in
                VStack {
                    if rect.midY < proxy.size.height * 0.5 {
                        Spacer(minLength: 0); card(step, position: position, total: total)
                    } else {
                        card(step, position: position, total: total); Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.spacing8)
            }
        }
        .ignoresSafeArea()
    }

    private func card(_ step: CoachmarkStep, position: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing6) {
            Text(step.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(step.message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if total > 1 {
                    Text("\(position) of \(total)")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Skip") { finish() }
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                Button(position < total ? "Next" : "Got it") { advance(isLast: position >= total) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.badgeInkOnFill)
            }
        }
        .padding(Theme.spacing8)
        .frame(maxWidth: 460)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .elevation(.card)
        .frame(maxWidth: .infinity)
    }
}
