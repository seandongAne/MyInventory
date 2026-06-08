//
//  ContentView.swift
//  MyInventory
//
//  Root three-column NavigationSplitView (Dev Plan §6.5):
//   • Sidebar  — the three contexts (+ Settings)
//   • Content  — selected context's categories → items (overdue pinned)
//   • Detail   — the selected item
//
//  On iPhone / narrow multitasking this collapses to a single nav stack for free.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyContext.sortOrder) private var contexts: [SupplyContext]
    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]

    @State private var selectedContext: SupplyContext?
    @State private var selectedItem: SupplyItem?
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var seedError: String?

    // App-wide search lives on the sidebar (root), so a user can find an item
    // without first knowing which context (Vehicle/Bag/House) it lives in.
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResultItem: SupplyItem?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            content
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .alert("Couldn't set up your data", isPresented: Binding(
            get: { seedError != nil },
            set: { if !$0 { seedError = nil } }
        )) {
            Button("Try Again") { seedContexts() }
            Button("OK", role: .cancel) { seedError = nil }
        } message: {
            if let seedError { Text(seedError) }
        }
        .task {
            seedContexts()
            if selectedContext == nil { selectedContext = contexts.first }
            await refreshNotifications()
        }
        .onChange(of: contexts) { _, newValue in
            if selectedContext == nil { selectedContext = newValue.first }
        }
        .onChange(of: selectedContext) { _, _ in
            selectedItem = nil   // item from another context no longer applies
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshNotifications() }
            }
        }
    }

    // MARK: Columns

    private var sidebar: some View {
        Group {
            if isSearching {
                globalSearchResults
            } else {
                contextList
            }
        }
        .navigationTitle("MyInventory")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search all supplies")
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            debouncedSearch = searchText
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
        }
        // Tapping a result opens the item directly — works the same on iPhone and
        // iPad regardless of how the split view is collapsed.
        .sheet(item: $searchResultItem) { item in
            NavigationStack {
                ItemDetailView(item: item, onDelete: { searchResultItem = nil })
            }
        }
    }

    private var contextList: some View {
        List(selection: $selectedContext) {
            Section("Supplies") {
                ForEach(contexts) { context in
                    ContextSidebarRow(context: context)
                        .tag(context)
                }
            }
        }
    }

    // MARK: Global search

    private var isSearching: Bool {
        !debouncedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchResults: [SupplyItem] {
        FuzzySearch.rank(allItems, query: debouncedSearch)
    }

    @ViewBuilder
    private var globalSearchResults: some View {
        if searchResults.isEmpty {
            ContentUnavailableView.search(text: debouncedSearch)
        } else {
            List {
                Section {
                    ForEach(searchResults) { item in
                        Button {
                            searchResultItem = item
                        } label: {
                            GlobalSearchResultRow(
                                item: item,
                                status: item.status(leadTimeDays: settings.globalLeadTimeDays)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedContext {
            ContextListView(context: selectedContext, selectedItem: $selectedItem)
                .id(selectedContext.persistentModelID)
        } else {
            ContentUnavailableView(
                "Select a context",
                systemImage: "square.grid.2x2",
                description: Text("Choose Vehicle, Bag, or House to see its supplies.")
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedItem {
            ItemDetailView(item: selectedItem, onDelete: { self.selectedItem = nil })
                .id(selectedItem.persistentModelID)
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "shippingbox",
                description: Text("Pick an item to see its details and check history.")
            )
        }
    }

    // MARK: Seeding

    private func seedContexts() {
        do {
            try SeedData.seedDefaultContextsIfNeeded(in: modelContext)
        } catch {
            seedError = error.localizedDescription
        }
    }

    // MARK: Notifications

    private func refreshNotifications() async {
        await notifications.refreshAuthorizationStatus()
        notifications.rescheduleAll(in: modelContext,
                                    globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}

// MARK: - Sidebar row

private struct ContextSidebarRow: View {
    let context: SupplyContext
    @Environment(SettingsStore.self) private var settings

    private var attentionCount: Int {
        context.allItems.filter {
            $0.status(leadTimeDays: settings.globalLeadTimeDays).isAttention
        }.count
    }

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: SeedData.symbol(forContextNamed: context.name))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            Text(context.name)

            Spacer()

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.statusOverdue, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Global search result row

private struct GlobalSearchResultRow: View {
    let item: SupplyItem
    let status: SupplyStatus

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            Image(systemName: status.style.symbol)
                .foregroundStyle(status.style.color)
                .imageScale(.medium)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.isEmpty ? "Untitled item" : item.name)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(breadcrumb)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Theme.spacing4)

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "Vehicle › Emergency Kit" — tells the user where the item lives, since a
    /// global search spans every context.
    private var breadcrumb: String {
        let ctx = item.context?.name ?? "—"
        let cat = item.category?.name ?? SupplyCategory.uncategorizedName
        return "\(ctx) › \(cat)"
    }
}

#Preview("iPad Landscape", traits: .landscapeLeft) {
    ContentView()
        .modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self],
                        inMemory: true)
        .environment(SettingsStore())
        .environment(NotificationManager())
}
