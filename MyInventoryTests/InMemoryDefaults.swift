//
//  InMemoryDefaults.swift
//  MyInventoryTests
//
//  A dictionary-backed `UserDefaults` for tests.
//
//  Why this exists: the settings tests used to create a real CFPreferences suite
//  per test (`UserDefaults(suiteName:)!` + `removePersistentDomain(forName:)`).
//  On the CI simulator that pattern intermittently crashed the whole test host
//  with a malloc double-free ("pointer being freed was not allocated") — the
//  transient suite create/remove races with the simulator's `cfprefsd`. It was
//  flaky (some runs green, some red) and turned the unit-test job red at random.
//
//  This subclass overrides every primitive `SettingsStore` touches with an
//  in-memory store, so no suite is ever created and `cfprefsd` is never involved
//  — deterministic, isolated, and fast. `super.init(suiteName: nil)` satisfies the
//  designated initializer; the underlying standard domain is never read or written
//  because every accessor below goes through `storage`.
//

import Foundation

final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("InMemoryDefaults is test-only") }

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { storage[defaultName] = value } else { storage.removeValue(forKey: defaultName) }
    }

    override func set(_ value: Int, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Float, forKey defaultName: String) { storage[defaultName] = value }

    override func removeObject(forKey defaultName: String) { storage.removeValue(forKey: defaultName) }

    override func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { storage[defaultName] as? Bool ?? false }
    override func integer(forKey defaultName: String) -> Int { storage[defaultName] as? Int ?? 0 }
    override func double(forKey defaultName: String) -> Double { storage[defaultName] as? Double ?? 0 }
}
