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
            .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
    }
}

extension View {
    func cardStyle() -> some View { modifier(Card()) }
}
