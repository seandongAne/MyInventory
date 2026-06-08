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
    @State private var listAppeared = false

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
        ZStack {
            ScreenBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(categories) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, Theme.spacing8)
                .padding(.top, Theme.spacing6)
                .padding(.bottom, Theme.spacing12)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            listAppeared = true
        }
        .onDisappear {
            // Reset so the stagger replays on re-entry.
            listAppeared = false
        }
    }

    private func categorySection(_ category: SupplyCategory) -> some View {
        let rows = items(in: category)
        return VStack(alignment: .leading, spacing: Theme.spacing4) {
            // Section header
            HStack(spacing: Theme.spacing4) {
                Text(category.name)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Theme.textPrimary)
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.textSecondary.opacity(0.15), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, Theme.spacing2)

            if rows.isEmpty {
                Text("No items")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.spacing4)
                    .padding(.vertical, Theme.spacing8)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.persistentModelID) { index, item in
                    itemButton(item, index: index)
                }
            }
        }
        .padding(.bottom, Theme.spacing12)
    }

    private func itemButton(_ item: SupplyItem, index: Int = 0) -> some View {
        let isSelected = selectedItem?.persistentModelID == item.persistentModelID
        let lead = settings.globalLeadTimeDays
        return Button {
            selectedItem = item
        } label: {
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
        }
        .buttonStyle(.plain)
        .contextMenu {
            let otherCategories = categories.filter {
                $0.persistentModelID != item.category?.persistentModelID
            }
            if !otherCategories.isEmpty {
                Menu {
                    ForEach(otherCategories) { cat in
                        Button {
                            moveItem(item, to: cat)
                        } label: {
                            Label(cat.name,
                                  systemImage: cat.isUncategorized ? "tray" : "folder")
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
        .padding(.bottom, Theme.spacing4)
        .opacity(listAppeared ? 1 : 0)
        .offset(y: listAppeared ? 0 : 12)
        .animation(
            Theme.springGentle.delay(min(Double(index), 8) * 0.04),
            value: listAppeared
        )
    }

    private var searchResultsList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: debouncedSearch)
            } else {
                ZStack {
                    ScreenBackground()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text("Results")
                                .font(.title3.weight(.semibold))
                                .fontDesign(.rounded)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, Theme.spacing2)
                                .padding(.bottom, Theme.spacing4)

                            ForEach(searchResults) { item in
                                let lead = settings.globalLeadTimeDays
                                Button {
                                    selectedItem = item
                                } label: {
                                    ItemCard(
                                        item: item,
                                        status: item.status(leadTimeDays: lead),
                                        nextDueText: item.statusDetailLabel(globalLead: lead)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                                            .strokeBorder(Theme.accent, lineWidth: 2)
                                            .opacity(selectedItem?.persistentModelID == item.persistentModelID ? 1 : 0)
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, Theme.spacing4)
                            }
                        }
                        .padding(.horizontal, Theme.spacing8)
                        .padding(.top, Theme.spacing6)
                        .padding(.bottom, Theme.spacing12)
                    }
                    .scrollContentBackground(.hidden)
                }
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
            print("[MyInventory] Failed to move item: \(error)")
        }
    }

    private func deleteItem(_ item: SupplyItem) {
        if selectedItem?.persistentModelID == item.persistentModelID {
            selectedItem = nil
        }
        notifications.cancelNotifications(forItemUUID: item.uuid)
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            print("[MyInventory] Failed to save after item delete: \(error)")
        }
        rescheduleNotifications()
    }

    private func rescheduleNotifications() {
        let items = (try? modelContext.fetch(FetchDescriptor<SupplyItem>())) ?? []
        Task {
            await notifications.reschedule(items: items,
                                           globalLeadTimeDays: settings.globalLeadTimeDays)
        }
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
