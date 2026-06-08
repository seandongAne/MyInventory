//
//  ScreenBackground.swift
//  MyInventory
//
//  Subtle vertical gradient so cards have a surface to float on.
//  Place in a ZStack behind content and set .scrollContentBackground(.hidden).
//

import SwiftUI

struct ScreenBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Theme.screenBackground,
                Theme.screenBackground.opacity(0.6)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
