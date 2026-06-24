//
//  WelcomeView.swift
//  MyInventory
//
//  First-run welcome guide — a few plain-language cards that explain the core
//  idea before the user lands in the app. Tuned for a non-technical user: large
//  text, generous spacing, an explicit "Continue" button on every page (never
//  rely on the swipe being discovered), and a checklist framing. Re-openable
//  from Settings; gated by `SettingsStore.hasCompletedOnboarding`.
//

import SwiftUI

struct WelcomeView: View {
    /// Called when the guide closes. `completed` is true for "Get Started"
    /// (continue into the coach-marks) and false for "Skip".
    var onFinish: (_ completed: Bool) -> Void

    @State private var page = 0

    private struct Card: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let cards: [Card] = [
        Card(icon: "shippingbox.fill", tint: Theme.accent,
             title: "Welcome to MyInventory",
             body: "Keep track of the supplies you store in your vehicle, bags, and home — and never lose track of when it's time to check each one again."),
        Card(icon: "checklist", tint: Theme.statusOverdue,
             title: "Needs Attention is your checklist",
             body: "Anything overdue, flagged, or never checked gathers there. Work down it like a pre-flight check — when it's empty, you're all set."),
        Card(icon: "plus.circle.fill", tint: Theme.accent,
             title: "Add what you keep",
             body: "Tap the + button to add a supply — or start from a ready-made checklist like Car Kit, Home Emergency, or a 72-Hour Go-Bag."),
        Card(icon: "checkmark.circle.fill", tint: Theme.statusOK,
             title: "Check it off in one tap",
             body: "When you've looked an item over, tap its green ✓. That records the check and resets its timer, so you'll be reminded again at the right time.")
    ]

    private var isLastPage: Bool { page >= cards.count - 1 }

    var body: some View {
        ZStack {
            ScreenBackground()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish(false) }
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(Theme.spacing8)
                        .accessibilityHint("Closes the guide")
                }

                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        cardPage(card).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(action: advance) {
                    Text(isLastPage ? "Get Started" : "Continue")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .foregroundStyle(Theme.badgeInkOnFill)
                .padding(.horizontal, Theme.spacing12)
                .padding(.bottom, Theme.spacing12)
                .padding(.top, Theme.spacing8)
            }
            .frame(maxWidth: 520)
        }
        .interactiveDismissDisabled()
    }

    private func advance() {
        if isLastPage {
            onFinish(true)
        } else {
            withAnimation { page += 1 }
        }
    }

    @ViewBuilder
    private func cardPage(_ card: Card) -> some View {
        VStack(spacing: Theme.spacing12) {
            Spacer(minLength: 0)

            Image(systemName: card.icon)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(card.tint)
                .frame(width: 128, height: 128)
                .background(card.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text(card.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)

            Text(card.body)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacing16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title). \(card.body)")
    }
}

#Preview {
    WelcomeView(onFinish: { _ in })
}
