//
//  Theme.swift
//  MyInventory
//
//  Design tokens — single source of truth for all visual values.
//

import SwiftUI

enum Theme {

    // MARK: Brand
    static let accent     = Color(red: 0.16, green: 0.42, blue: 0.40)
    static let accentSoft = Color(red: 0.16, green: 0.42, blue: 0.40).opacity(0.12)

    // MARK: Status
    static let statusOverdue        = Color(red: 0.83, green: 0.24, blue: 0.22)
    static let statusNeedsAttention = Color(red: 0.86, green: 0.42, blue: 0.10)  // deep amber, distinct from due-soon
    static let statusDueSoon        = Color(red: 0.90, green: 0.55, blue: 0.13)
    static let statusOK             = Color(red: 0.20, green: 0.55, blue: 0.36)
    static let statusNeverChecked   = Color(red: 0.83, green: 0.24, blue: 0.22)
    static let statusNoExpiry       = Color.secondary

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
