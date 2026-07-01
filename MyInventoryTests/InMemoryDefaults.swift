//
//  InMemoryDefaults.swift
//  MyInventoryTests
//
//  A dictionary-backed `SettingsDefaults` for tests.
//
//  Why this exists — and why it is NOT a `UserDefaults` subclass:
//  the settings tests need an isolated, per-test key/value store. Two earlier
//  approaches both intermittently crashed the CI test host with a `malloc`
//  double-free ("pointer being freed was not allocated"):
//    1. a real transient suite (`UserDefaults(suiteName:)!` + `removePersistentDomain`)
//       raced the simulator's `cfprefsd`;
//    2. subclassing `UserDefaults` and calling `super.init(suiteName: nil)!` — a class
//       cluster whose initializer returns the SHARED standard-domain object, so several
//       `InMemoryDefaults` instances all wrapped the same singleton and their deinits
//       over-released it (the constant crash address across process launches was that
//       shared object, living in the dyld shared-cache region).
//  `SettingsStore` now depends on the narrow `SettingsDefaults` protocol, so this can be
//  a plain Swift class over a `[String: Any]` dictionary — no class cluster, no
//  `cfprefsd`, no shared singleton. Deterministic, isolated, and can't corrupt the heap.
//

import Foundation
@testable import MyInventory

final class InMemoryDefaults: SettingsDefaults {
    private var storage: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { storage[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value { storage[defaultName] = value } else { storage.removeValue(forKey: defaultName) }
    }

    func removeObject(forKey defaultName: String) { storage.removeValue(forKey: defaultName) }

    func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { storage[defaultName] as? Bool ?? false }
}
