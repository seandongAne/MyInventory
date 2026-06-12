//
//  Card.swift
//  MyInventory
//
//  The floating-surface primitive. Wrap any content with .cardStyle().
//

import SwiftUI

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardSurface,
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .elevation(.card)
    }
}

extension View {
    func cardStyle() -> some View { modifier(Card()) }

    /// Soft, single-direction elevation from the Theme shadow tiers
    /// (color-scheme aware — see `Theme.Shadow`).
    func elevation(_ shadow: Theme.Shadow = .card) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}
