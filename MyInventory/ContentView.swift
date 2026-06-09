//
//  ContentView.swift
//  MyInventory
//
//  Root three-column NavigationSplitView (Dev Plan §6.5):
//   • Sidebar  — Needs Attention + the contexts (+ Settings)
//   • Content  — the attention list, or a context's categories → items
//   • Detail   — the selected item
//
//  On iPhone / narrow multitasking this collapses to a single nav stack for free.
//

import SwiftUI
import SwiftData
import UIKit

/// What the sidebar can select: the cross-context attention list, or one context.
enum SidebarSelection: Hashable {
    case attention
    case context(SupplyContext)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyContext.sortOrder) private var contexts: [SupplyContext]
    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]

    @State private var sidebarSelection: SidebarSelection?
    @State private var selectedItem: SupplyItem?
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var seedError: String?

    // App-wide search lives on the sidebar (root), so a user can find an item
    // without first knowing which context (Vehicle/Bag/House) it lives in.
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResultItem: SupplyItem?

    // Add / rename / delete top-level contexts (Vehicle/Bag/House and any the user adds).
    @State private var showingAddContext = false
    @State private var newContextName = ""
    @State private var contextPendingRename: SupplyContext?
    @State private var renameContextName = ""
    @State private var contextPendingDeletion: SupplyContext?
    @State private var contextActionError: String?

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
            if isUITesting { seedUITestSample() }
            applyInitialSidebarSelection()
            await refreshNotifications()
            // A notification tap may have cold-started the app before this view
            // existed — consume any deep link that's already waiting.
            handleDeepLink(notifications.pendingDeepLink)
        }
        .onChange(of: contexts) { _, _ in
            applyInitialSidebarSelection()
        }
        .onChange(of: sidebarSelection) { _, _ in
            selectedItem = nil   // item from another list no longer applies
        }
        .onChange(of: notifications.pendingDeepLink) { _, link in
            handleDeepLink(link)
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
                sidebarList
            }
        }
        .navigationTitle("MyInventory")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search all supplies")
        .task(id: searchText) {
            // On cancellation (a newer keystroke) bail out — otherwise the body
            // would fall through and write immediately, defeating the debounce.
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            debouncedSearch = searchText
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    newContextName = ""
                    showingAddContext = true
                } label: {
                    Label("Add Context", systemImage: "plus")
                }
            }
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
                ItemDetailView(item: item, onDelete: {
                    // The same item may also be selected in the detail column —
                    // leaving it there would re-render a deleted model (crash).
                    if selectedItem?.persistentModelID == item.persistentModelID {
                        selectedItem = nil
                    }
                    searchResultItem = nil
                })
            }
        }
        .alert("New Context", isPresented: $showingAddContext) {
            TextField("Name (e.g. Cabin, Boat)", text: $newContextName)
            Button("Add") { addContext() }
            Button("Cancel", role: .cancel) { newContextName = "" }
        } message: {
            Text("Add a top-level place for your supplies, alongside Vehicle, Bag, and House.")
        }
        .alert("Rename Context", isPresented: Binding(
            get: { contextPendingRename != nil },
            set: { if !$0 { contextPendingRename = nil } }
        )) {
            TextField("Name", text: $renameContextName)
            Button("Save") { renameContext() }
            Button("Cancel", role: .cancel) { contextPendingRename = nil }
        }
        .confirmationDialog(
            "Delete “\(contextPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { contextPendingDeletion != nil },
                set: { if !$0 { contextPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let context = contextPendingDeletion {
                    contextPendingDeletion = nil
                    deleteContext(context)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let context = contextPendingDeletion {
                let n = context.allItems.count
                Text(n == 0
                     ? "This removes the context."
                     : "This permanently deletes the context, its \(n) item\(n == 1 ? "" : "s"), and all their check history.")
            }
        }
        .alert("Action failed", isPresented: Binding(
            get: { contextActionError != nil },
            set: { if !$0 { contextActionError = nil } }
        )) {
            Button("OK", role: .cancel) { contextActionError = nil }
        } message: {
            if let contextActionError { Text(contextActionError) }
        }
    }

    private var sidebarList: some View {
        List(selection: $sidebarSelection) {
            Section {
                AttentionSidebarRow(count: attentionCount)
                    .tag(SidebarSelection.attention)
            }
            Section("Supplies") {
                ForEach(contexts) { context in
                    ContextSidebarRow(context: context)
                        .tag(SidebarSelection.context(context))
                        // Long-press menu: more discoverable AND more reliable
                        // than swipe on a split-view sidebar row (swipes there
                        // often register as selection).
                        .contextMenu {
                            Button {
                                renameContextName = context.name
                                contextPendingRename = context
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                requestDeleteContext(context)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete(perform: requestDeleteContext)
            }
        }
    }

    /// First-launch landing. iPad has room for all three columns, so it opens
    /// the first context. On iPhone (collapsed navigation) auto-pushing a
    /// context would hide the search field and the attention overview behind a
    /// Back button — so land on Needs Attention when something is due, else
    /// stay on the sidebar. UI tests always stay on the sidebar.
    private func applyInitialSidebarSelection() {
        guard sidebarSelection == nil, !isUITesting else { return }
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let first = contexts.first { sidebarSelection = .context(first) }
        } else if attentionCount > 0 {
            sidebarSelection = .attention
        }
    }

    private var attentionCount: Int {
        allItems.filter { $0.status(leadTimeDays: settings.globalLeadTimeDays).isAttention }.count
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
        switch sidebarSelection {
        case .attention:
            AttentionListView(selectedItem: $selectedItem)
        case .context(let context):
            ContextListView(context: context, selectedItem: $selectedItem)
                .id(context.persistentModelID)
        case nil:
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

    // MARK: UI-test support

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    private func seedUITestSample() {
        try? SeedData.seedUITestSampleIfNeeded(in: modelContext)
    }

    // MARK: Deep links (notification taps)

    private func handleDeepLink(_ link: NotificationManager.DeepLink?) {
        guard let link else { return }
        notifications.pendingDeepLink = nil
        switch link {
        case .attention:
            sidebarSelection = .attention
        case .item(let uuid):
            if let item = allItems.first(where: { $0.uuid == uuid }) {
                searchResultItem = item
            }
        }
    }

    // MARK: Context management

    private func addContext() {
        let trimmed = newContextName.trimmingCharacters(in: .whitespacesAndNewlines)
        newContextName = ""
        guard !trimmed.isEmpty else { return }
        guard !contexts.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else {
            contextActionError = "A context named “\(trimmed)” already exists."
            return
        }
        let nextOrder = (contexts.map(\.sortOrder).max() ?? -1) + 1
        let context = SupplyContext(name: trimmed, sortOrder: nextOrder)
        modelContext.insert(context)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            contextActionError = error.localizedDescription
        }
    }

    private func requestDeleteContext(_ offsets: IndexSet) {
        guard let index = offsets.first else { return }
        requestDeleteContext(contexts[index])
    }

    private func requestDeleteContext(_ context: SupplyContext) {
        // Keep at least one context: the app always needs somewhere to put supplies,
        // and it stops the first-launch defaults from being re-seeded over an empty store.
        guard contexts.count > 1 else {
            contextActionError = "You need at least one context. Add another before deleting this one."
            return
        }
        contextPendingDeletion = context
    }

    private func renameContext() {
        guard let context = contextPendingRename else { return }
        contextPendingRename = nil
        let trimmed = renameContextName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameContextName = ""
        guard !trimmed.isEmpty, trimmed != context.name else { return }
        guard !contexts.contains(where: {
            $0.persistentModelID != context.persistentModelID
            && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else {
            contextActionError = "A context named “\(trimmed)” already exists."
            return
        }
        context.name = trimmed
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            contextActionError = error.localizedDescription
            return
        }
        // Notification bodies embed the context name — refresh them.
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }

    private func deleteContext(_ context: SupplyContext) {
        // Delete the context's items explicitly. The context→categories rule is
        // .cascade, but categories→items is .nullify — so without this the items would
        // be left orphaned (reachable from no context). item→checks is .cascade, so
        // deleting each item also removes its check history.
        let items = context.allItems
        let uuids = items.map(\.uuid)
        for item in items { modelContext.delete(item) }
        modelContext.delete(context)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            contextActionError = error.localizedDescription
            return
        }

        if case .context(let selected) = sidebarSelection,
           selected.persistentModelID == context.persistentModelID {
            sidebarSelection = nil
            selectedItem = nil
        }
        // Reminders for the now-deleted items must be cancelled and the rest refreshed.
        for uuid in uuids { notifications.cancelNotifications(forItemUUID: uuid) }
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }

    // MARK: Notifications

    private func refreshNotifications() async {
        await notifications.refreshAuthorizationStatus()
        notifications.rescheduleAll(in: modelContext,
                                    globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}

// MARK: - Sidebar rows

private struct AttentionSidebarRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.statusOverdue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.statusOverdue)
            }

            Text("Needs Attention")

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.statusOverdue, in: Capsule())
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusOK)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContextSidebarRow: View {
    let context: SupplyContext
    @Environment(SettingsStore.self) private var settings

    private var attentionCount: Int {
        context.allItems.filter {
            $0.status(leadTimeDays: settings.globalLeadTimeDays).isAttention
        }.count
    }

    var body: some View {
        let brand = SeedData.color(forContextNamed: context.name)
        HStack(spacing: Theme.spacing6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(brand.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: SeedData.symbol(forContextNamed: context.name))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(brand)
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
