//
//  Theme.swift
//  MyInventory
//
//  Design tokens — single source of truth for all visual values.
//

import SwiftUI
import UIKit

enum Theme {

    // MARK: Adaptive color support
    //
    // Every tint is a light/dark PAIR and must clear ≥4:1 contrast against the
    // card surface (secondarySystemGroupedBackground) in BOTH appearances —
    // enforced by ThemeContrastTests. Dark variants are brighter and slightly
    // desaturated (the same way system colors adapt); light ambers are kept
    // deep because yellow/orange is what fails on white, not on black.
    // Hue semantics are preserved: red=overdue, amber=warning, green=ok,
    // violet=never-checked, teal=brand.

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                            _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: Brand
    static let accent = adaptive(light: rgb(0.16, 0.42, 0.40),
                                 dark:  rgb(0.38, 0.71, 0.67))
    /// Soft fill behind accent-tinted icons (ItemCard thumbnail tile).
    /// Light = 12% accent wash; dark = an OPAQUE dim teal — a translucent wash
    /// of the bright dark accent would lift the tile's luminance and erode the
    /// icon's contrast sitting on it.
    static let accentSoft = adaptive(light: rgb(0.16, 0.42, 0.40, 0.12),
                                     dark:  rgb(0.13, 0.23, 0.22))

    // MARK: Status
    static let statusOverdue        = adaptive(light: rgb(0.83, 0.24, 0.22),
                                               dark:  rgb(0.95, 0.42, 0.38))
    static let statusNeedsAttention = adaptive(light: rgb(0.76, 0.35, 0.05),   // deep amber, distinct from due-soon
                                               dark:  rgb(0.93, 0.52, 0.20))
    static let statusDueSoon        = adaptive(light: rgb(0.67, 0.44, 0.02),
                                               dark:  rgb(0.92, 0.62, 0.20))
    static let statusOK             = adaptive(light: rgb(0.20, 0.55, 0.36),
                                               dark:  rgb(0.34, 0.72, 0.48))
    static let statusNeverChecked   = adaptive(light: rgb(0.48, 0.36, 0.79),   // violet — distinct from overdue red
                                               dark:  rgb(0.67, 0.58, 0.96))
    static let statusNoExpiry       = Color.secondary

    /// Ink (text/icon) on a SOLID status-color fill — used by StatusBadge in
    /// high-contrast (filled) mode. White on the deep light fills; near-black
    /// on the bright dark fills (white only reaches ~2.6:1 there).
    static let badgeInkOnFill = adaptive(light: rgb(1.00, 1.00, 1.00),
                                         dark:  rgb(0.063, 0.067, 0.075))

    // MARK: Surfaces
    static let screenBackground = Color(.systemGroupedBackground)
    static let cardSurface      = Color(.secondarySystemGroupedBackground)
    static let textPrimary      = Color.primary
    static let textSecondary    = Color.secondary

    // MARK: Geometry
    static let cardCornerRadius:    CGFloat = 16
    static let controlCornerRadius: CGFloat = 12
    static let badgeCornerRadius:   CGFloat = 8

    // MARK: Spacing (8-pt grid)
    static let spacing2:  CGFloat = 4
    static let spacing4:  CGFloat = 8
    static let spacing6:  CGFloat = 12
    static let spacing8:  CGFloat = 16
    static let spacing12: CGFloat = 24
    static let spacing16: CGFloat = 32

    // MARK: Shadow
    static let cardShadowColor:  Color   = Color.black.opacity(0.08)
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowY:      CGFloat = 4

    // MARK: Animation
    static let springQuick  = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let springGentle = Animation.spring(response: 0.45, dampingFraction: 0.85)
}
