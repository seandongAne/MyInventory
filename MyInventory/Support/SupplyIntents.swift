//
//  SupplyIntents.swift
//  MyInventory
//
//  App Intents (Shortcuts / Siri): "Mark <item> as checked in MyInventory".
//  Intents run in the app's process and go through the same shared container,
//  save-with-rollback discipline, and notification reschedule as the UI.
//

import AppIntents
import Foundation
import SwiftData

struct SupplyItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Supply"
    static let defaultQuery = SupplyItemEntityQuery()

    let id: UUID
    let name: String
    let contextName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: contextName.map { "\($0)" }
        )
    }

    @MainActor
    static func make(from item: SupplyItem) -> SupplyItemEntity {
        SupplyItemEntity(id: item.uuid, name: item.name, contextName: item.context?.name)
    }
}

struct SupplyItemEntityQuery: EntityStringQuery {

    func entities(for identifiers: [UUID]) async throws -> [SupplyItemEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SupplyItemEntity] {
        try await MainActor.run {
            let items = try fetchItems()
            return FuzzySearch.rank(items, query: string).prefix(10).map(SupplyItemEntity.make(from:))
        }
    }

    func suggestedEntities() async throws -> [SupplyItemEntity] {
        try await Array(allEntities().prefix(20))
    }

    private func allEntities() async throws -> [SupplyItemEntity] {
        try await MainActor.run {
            try fetchItems().map(SupplyItemEntity.make(from:))
        }
    }

    @MainActor
    private func fetchItems() throws -> [SupplyItem] {
        guard case .success(let container) = AppModelContainer.shared else { return [] }
        return try container.mainContext.fetch(
            FetchDescriptor<SupplyItem>(sortBy: [SortDescriptor(\.name)])
        )
    }
}

struct MarkSupplyCheckedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Supply as Checked"
    static let description = IntentDescription("Logs an OK check for a supply item, resetting its re-check countdown.")

    @Parameter(title: "Supply")
    var item: SupplyItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .success(let container) = AppModelContainer.shared else {
            throw SupplyIntentError.storeUnavailable
        }
        let modelContext = container.mainContext
        let targetUUID = item.id
        var descriptor = FetchDescriptor<SupplyItem>(predicate: #Predicate { $0.uuid == targetUUID })
        descriptor.fetchLimit = 1
        guard let supply = try modelContext.fetch(descriptor).first else {
            throw SupplyIntentError.itemNotFound
        }

        let record = CheckRecord(date: .now, result: .ok)
        record.item = supply
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        NotificationManager.shared.rescheduleAll(
            in: modelContext,
            globalLeadTimeDays: SettingsStore().globalLeadTimeDays
        )
        return .result(dialog: "Marked “\(supply.name)” as checked.")
    }
}

enum SupplyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable
    case itemNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable: "MyInventory couldn't open its data store."
        case .itemNotFound: "That supply no longer exists."
        }
    }
}

struct MyInventoryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MarkSupplyCheckedIntent(),
            phrases: [
                "Mark a supply as checked in \(.applicationName)",
                "Log a check in \(.applicationName)"
            ],
            shortTitle: "Mark Checked",
            systemImageName: "checkmark.circle"
        )
    }
}
