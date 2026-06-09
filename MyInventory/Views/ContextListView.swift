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
    @State private var showingTemplates = false
    @State private var bulkCheckCategory: SupplyCategory?
    @State private var itemPendingDeletion: SupplyItem?
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
            // On cancellation (a newer keystroke) bail out — otherwise the body
            // would fall through and write immediately, defeating the debounce.
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            debouncedSearch = searchText
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // primaryAction keeps the common path one tap: tap = Add Item,
                // long-press reveals the template option.
                Menu {
                    Button { showingAddItem = true } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                    Button { showingTemplates = true } label: {
                        Label("Add from Template", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    showingAddItem = true
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
        .sheet(isPresented: $showingTemplates) {
            NavigationStack {
                TemplatePickerView(context: context)
            }
        }
        .confirmationDialog(
            "Mark all items in “\(bulkCheckCategory?.name ?? "")” as checked?",
            isPresented: Binding(
                get: { bulkCheckCategory != nil },
                set: { if !$0 { bulkCheckCategory = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mark \(bulkCheckCategory.map { items(in: $0).count } ?? 0) as Checked") {
                if let category = bulkCheckCategory {
                    bulkCheckCategory = nil
                    bulkCheck(category)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logs an OK check for every item, resetting each re-check countdown.")
        }
        .confirmationDialog(
            "Delete “\(itemPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = itemPendingDeletion {
                    itemPendingDeletion = nil
                    deleteItem(item)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item and its full check history.")
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
                    sectionHeader(name: category.name, count: rows.count, category: category)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
    }

    private func sectionHeader(name: String, count: Int, category: SupplyCategory? = nil) -> some View {
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
            if let category, count > 0 {
                Menu {
                    Button {
                        bulkCheckCategory = category
                    } label: {
                        Label("Mark All as Checked", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
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
        // The most frequent action — "looked at it, all good" — is one swipe,
        // mirroring the notification's Mark-as-Checked action.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                quickCheck(item)
            } label: {
                Label("Checked", systemImage: "checkmark.circle.fill")
            }
            .tint(Theme.statusOK)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                itemPendingDeletion = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu { itemContextMenu(item) }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: SupplyItem) -> some View {
        Button {
            quickCheck(item)
        } label: {
            Label("Mark as Checked", systemImage: "checkmark.circle")
        }
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
        // Destructive: routes through the same confirmation as everywhere else —
        // never delete an item (and its history) straight off a long-press.
        Button(role: .destructive) {
            itemPendingDeletion = item
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
            Text("Start from a ready-made checklist, or add a category first and then the supplies you keep in your \(context.name.lowercased()).")
        } actions: {
            Button {
                showingTemplates = true
            } label: {
                Label("Start from a Template", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderedProminent)
            Button {
                showingCategoryManager = true
            } label: {
                Label("Add Category", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
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

    /// One-swipe "looked at it, all good" — logs an OK check without the sheet.
    /// (For a different result or a note, open the item and use "Check now".)
    private func quickCheck(_ item: SupplyItem) {
        let record = CheckRecord(date: .now, result: .ok)
        record.item = item
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        Haptics.success()
        rescheduleNotifications()
    }

    /// Logs an OK check for every item in the category — the "I went through the
    /// whole emergency kit" flow. One save; rolled back atomically on failure.
    private func bulkCheck(_ category: SupplyCategory) {
        let rows = items(in: category)
        guard !rows.isEmpty else { return }
        for item in rows {
            let record = CheckRecord(date: .now, result: .ok)
            record.item = item
            modelContext.insert(record)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        Haptics.success()
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
