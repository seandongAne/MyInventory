//
//  ThemeContrastTests.swift
//  MyInventoryTests
//
//  Executable contract for the Theme palette: every adaptive tint must clear
//  ≥4:1 WCAG contrast against the card surface in BOTH light and dark mode.
//  (4:1 is this project's bar — stricter than the 3:1 WCAG minimum for
//  graphical objects, looser than the 4.5:1 text requirement.)
//

import XCTest
import SwiftUI
@testable import MyInventory

final class ThemeContrastTests: XCTestCase {

    private static let target: CGFloat = 4.0

    private let tints: [(name: String, color: Color)] = [
        ("accent", Theme.accent),
        ("statusOverdue", Theme.statusOverdue),
        ("statusNeedsAttention", Theme.statusNeedsAttention),
        ("statusDueSoon", Theme.statusDueSoon),
        ("statusOK", Theme.statusOK),
        ("statusNeverChecked", Theme.statusNeverChecked),
    ]

    func testTintsClearTargetContrastOnCardSurfaceInLightMode() {
        assertAll(in: UITraitCollection(userInterfaceStyle: .light), label: "light")
    }

    func testTintsClearTargetContrastOnCardSurfaceInDarkMode() {
        assertAll(in: UITraitCollection(userInterfaceStyle: .dark), label: "dark")
    }

    /// High-contrast (filled) badges AND solid-fill buttons: `badgeInkOnFill`
    /// on a solid status OR accent fill must clear the same 4:1 bar in both
    /// modes. Covers the overdue count badges + the accent CTAs / PressableButton
    /// (a hardcoded white only reached ~2.4:1 on the bright dark accent/overdue).
    /// `.neverExpires` is excluded — it stays tinted even in filled mode
    /// (see StatusBadge.filled).
    func testBadgeInkOnSolidStatusFillsInBothModes() {
        let filledTints = tints.filter { $0.name.hasPrefix("status") || $0.name == "accent" }
        let traits: [(String, UITraitCollection)] = [
            ("light", UITraitCollection(userInterfaceStyle: .light)),
            ("dark", UITraitCollection(userInterfaceStyle: .dark)),
        ]
        for (label, trait) in traits {
            for tint in filledTints {
                let ratio = contrast(fg: UIColor(Theme.badgeInkOnFill),
                                     bg: UIColor(tint.color),
                                     in: trait)
                XCTAssertGreaterThanOrEqual(ratio, Self.target,
                    "badge ink on \(tint.name) fill (\(label)) is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// The dark accentSoft tile is opaque by design; the accent icon sitting
    /// on it must stay readable (this is the case a translucent wash broke).
    func testAccentOnItsSoftTileStaysReadableInDarkMode() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let ratio = contrast(fg: UIColor(Theme.accent),
                             bg: UIColor(Theme.accentSoft),
                             in: dark)
        XCTAssertGreaterThanOrEqual(ratio, Self.target,
            "accent on accentSoft tile (dark) is \(String(format: "%.2f", ratio)):1")
    }

    // MARK: - Helpers

    private func assertAll(in trait: UITraitCollection, label: String) {
        let card = UIColor.secondarySystemGroupedBackground
        for tint in tints {
            let ratio = contrast(fg: UIColor(tint.color), bg: card, in: trait)
            XCTAssertGreaterThanOrEqual(ratio, Self.target,
                "\(tint.name) vs card surface (\(label)) is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// WCAG 2.x contrast ratio between two colors resolved for a trait.
    private func contrast(fg: UIColor, bg: UIColor, in trait: UITraitCollection) -> CGFloat {
        let lf = luminance(fg, in: trait)
        let lb = luminance(bg, in: trait)
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    /// WCAG relative luminance. Alpha is composited over the resolved card
    /// surface first so translucent tokens (light accentSoft) measure honestly.
    private func luminance(_ color: UIColor, in trait: UITraitCollection) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: trait).getRed(&r, green: &g, blue: &b, alpha: &a)
        if a < 1 {
            var ur: CGFloat = 0, ug: CGFloat = 0, ub: CGFloat = 0, ua: CGFloat = 0
            UIColor.secondarySystemGroupedBackground.resolvedColor(with: trait)
                .getRed(&ur, green: &ug, blue: &ub, alpha: &ua)
            r = a * r + (1 - a) * ur
            g = a * g + (1 - a) * ug
            b = a * b + (1 - a) * ub
        }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}
