//
//  Haptics.swift
//  MyInventory
//
//  Tiny wrapper so actions that complete without visible UI change (quick
//  check, bulk check, template apply) still give tactile confirmation.
//

import UIKit

@MainActor
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
