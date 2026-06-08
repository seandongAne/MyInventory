//
//  PressableButtonStyle.swift
//  MyInventory
//
//  Tactile scale + opacity feedback for primary action buttons.
//

import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, Theme.spacing6)
            .padding(.horizontal, Theme.spacing8)
            .background(tint,
                        in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.springQuick, value: configuration.isPressed)
    }
}
