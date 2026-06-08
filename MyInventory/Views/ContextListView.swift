//
//  ContextListView.swift
//  MyInventory
//
//  Content column: a selected context's categories → items, grouped with cards.
//  Overdue/needs-attention items are pinned to the top of each section.
//  Fuzzy search flattens into a ranked card list.
//

import SwiftUI
import SwiftData

struct ContextListView: View {
    let context: SupplyContext
    @Binding var selectedItem: SupplyItem?

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]
    @Query(sort: \SupplyCategory.sortOrder) private var allCategories: [SupplyCategory]

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var showingAddItem = false
    @State private var showingCategoryManager = false
    @State private var actionError: String?

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else if categories.isEmpty {
                emptyContextState
            } else {
                groupedList
            }
        }
        .navigationTitle(context.name)
        .searchable(text: $searchText, prompt: "Search supplies")
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            debouncedSearch = searchText
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddItem = true } label: {
                    Label("Add Item", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showingCategoryManager = true } label: {
                    Label("Categories", systemImage: "folder")
                }
            }
        }
        .sheet(isPresented: $showingAddItem) {
            NavigationStack {
                ItemEditView(mode: .create(context: context))
            }
        }
        .sheet(isPresented: $showingCategoryManager) {
            NavigationStack {
                CategoryManagerView(context: context)
            }
        }
        .alert("Action failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError { Text(actionError) }
        }
    }

    // MARK: Derived data

    private var isSearching: Bool {
        !debouncedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var contextItems: [SupplyItem] {
        allItems.filter { $0.category?.context?.persistentModelID == context.persistentModelID }
    }

    private var categories: [SupplyCategory] {
        allCategories
            .filter { $0.context?.persistentModelID == context.persistentModelID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func items(in category: SupplyCategory) -> [SupplyItem] {
        contextItems
            .filter { $0.category?.persistentModelID == category.persistentModelID }
            .sorted(by: statusThenName)
    }

    private var searchResults: [SupplyItem] {
        FuzzySearch.rank(contextItems, query: debouncedSearch)
    }

    private func statusThenName(_ a: SupplyItem, _ b: SupplyItem) -> Bool {
        let lead = settings.globalLeadTimeDays
        let pa = a.status(leadTimeDays: lead).sortPriority
        let pb = b.status(leadTimeDays: lead).sortPriority
        if pa != pb { return pa < pb }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: Views

    private var groupedList: some View {
        List(selection: $selectedItem) {
            ForEach(categories) { category in
                let rows = items(in: category)
                Section {
                    if rows.isEmpty {
                        Text("No items")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(rows) { item in
                            itemRow(item)
                        }
                    }
                } header: {
                    sectionHeader(name: category.name, count: rows.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
    }

    private func sectionHeader(name: String, count: Int) -> some View {
        HStack(spacing: Theme.spacing4) {
            Text(name)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.textSecondary.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .textCase(nil)
        .padding(.vertical, Theme.spacing2)
    }

    /// One selectable item row. Driving selection through `List(selection:)` + `.tag`
    /// (rather than a plain Button) is what lets NavigationSplitView push the detail
    /// column on iPhone / compact width — and it still shows in-place on iPad (H1).
    @ViewBuilder
    private func itemRow(_ item: SupplyItem) -> some View {
        let lead = settings.globalLeadTimeDays
        let isSelected = selectedItem?.persistentModelID == item.persistentModelID
        ItemCard(
            item: item,
            status: item.status(leadTimeDays: lead),
            nextDueText: item.statusDetailLabel(globalLead: lead)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .tag(item)
        .listRowInsets(EdgeInsets(top: Theme.spacing2, leading: Theme.spacing8,
                                  bottom: Theme.spacing2, trailing: Theme.spacing8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { itemContextMenu(item) }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: SupplyItem) -> some View {
        let otherCategories = categories.filter {
            $0.persistentModelID != item.category?.persistentModelID
        }
        if !otherCategories.isEmpty {
            Menu {
                ForEach(otherCategories) { cat in
                    Button {
                        moveItem(item, to: cat)
                    } label: {
                        Label(cat.name, systemImage: cat.isUncategorized ? "tray" : "folder")
                    }
                }
            } label: {
                Label("Move to Category", systemImage: "arrow.up.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteItem(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var searchResultsList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: debouncedSearch)
            } else {
                List(selection: $selectedItem) {
                    Section {
                        ForEach(searchResults) { item in
                            itemRow(item)
                        }
                    } header: {
                        sectionHeader(name: "Results", count: searchResults.count)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ScreenBackground())
            }
        }
    }

    private var emptyContextState: some View {
        ContentUnavailableView {
            Label("No categories yet", systemImage: "folder")
        } description: {
            Text("Add a category first, then add the supplies you keep in your \(context.name.lowercased()).")
        } actions: {
            Button {
                showingCategoryManager = true
            } label: {
                Label("Add Category", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Mutations

    private func moveItem(_ item: SupplyItem, to category: SupplyCategory) {
        item.category = category
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription   // surfaced, not just logged (P1-c)
        }
    }

    private func deleteItem(_ item: SupplyItem) {
        let uuid = item.uuid
        let wasSelected = selectedItem?.persistentModelID == item.persistentModelID
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return   // item still exists; selection + notifications untouched (P2-a)
        }
        if wasSelected { selectedItem = nil }
        notifications.cancelNotifications(forItemUUID: uuid)
        rescheduleNotifications()
    }

    private func rescheduleNotifications() {
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}

// MARK: - Preview

@MainActor
private func makeContextListPreviewContainer() -> ModelContainer {
    let container = try! ModelContainer(
        for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext

    let vehicleCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
    ctx.insert(vehicleCtx)

    let cat1 = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
    cat1.context = vehicleCtx
    ctx.insert(cat1)

    let cat2 = SupplyCategory(name: "Fluids", sortOrder: 1)
    cat2.context = vehicleCtx
    ctx.insert(cat2)

    let item1 = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6)
    item1.category = cat1
    ctx.insert(item1)
    let check1 = CheckRecord(date: Calendar.current.date(byAdding: .month, value: -7, to: .now)!, result: .ok)
    check1.item = item1
    ctx.insert(check1)

    let item2 = SupplyItem(name: "Emergency Blanket", checkIntervalMonths: 12)
    item2.category = cat1
    ctx.insert(item2)

    let item3 = SupplyItem(name: "Engine Oil", checkIntervalMonths: 3, storageLocation: "Trunk")
    item3.category = cat2
    ctx.insert(item3)
    let check3 = CheckRecord(date: .now, result: .replaced, comment: "Changed to 5W-30")
    check3.item = item3
    ctx.insert(check3)

    let item4 = SupplyItem(name: "Jumper Cables", checkIntervalMonths: nil)
    item4.category = cat2
    ctx.insert(item4)

    try? ctx.save()
    return container
}

#Preview("ContextListView – populated") {
    let container = makeContextListPreviewContainer()
    let context = try! container.mainContext.fetch(FetchDescriptor<SupplyContext>()).first!
    NavigationStack {
        ContextListView(context: context, selectedItem: .constant(nil))
    }
    .modelContainer(container)
    .environment(SettingsStore())
    .environment(NotificationManager())
}
