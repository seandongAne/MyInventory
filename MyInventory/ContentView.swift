//
//  ContentView.swift
//  MyInventory
//
//  Root vertical single-page layout (replaces the old three-column
//  NavigationSplitView per the teacher's "Supplies Check" demo):
//   • a pinned horizontal "Programs" selector (Needs Attention + contexts)
//   • below it, the selected program's items as a vertical grid of cards
//   • tapping a card pushes ItemDetailView onto the stack (no detail column)
//
//  Tuned for iPad (the only target device); it still runs on iPhone.
//

import SwiftUI
import SwiftData
import UIKit

/// What the Programs bar can select: the cross-context attention list, or one context.
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
    @State private var path = NavigationPath()
    @State private var showingSettings = false
    @State private var seedError: String?

    // First-run guide: welcome cards (all devices) → coach-marks (iPad only).
    @State private var showingWelcome = false
    @State private var runCoachmarks = false
    @State private var wantsCoachmarks = false

    // App-wide search lives at the root, so a user can find an item without first
    // knowing which context (Vehicle/Bag/House) it lives in.
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
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground()
                if isSearching {
                    globalSearchResults
                } else {
                    mainContent
                }
            }
            .navigationTitle("Supplies Check")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search all supplies")
            .task(id: searchText) {
                // On cancellation (a newer keystroke) bail out — otherwise the body
                // would fall through and write immediately, defeating the debounce.
                guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
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
            // One destination registration serves every NavigationLink(value:) in
            // the item cards (ContextListView / AttentionListView).
            .navigationDestination(for: SupplyItem.self) { item in
                ItemDetailView(item: item, onDelete: { if !path.isEmpty { path.removeLast() } })
                    .id(item.persistentModelID)
            }
            // Tapping a global-search result opens the item directly.
            .sheet(item: $searchResultItem) { item in
                NavigationStack {
                    ItemDetailView(item: item, onDelete: { searchResultItem = nil })
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
        .tint(Theme.accent)
        .coachmarks(coachmarkSteps, isActive: $runCoachmarks, onFinish: completeOnboarding)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView(onReplayGuide: startOnboarding) }
        }
        .sheet(isPresented: $showingWelcome, onDismiss: afterWelcome) {
            WelcomeView { completed in
                wantsCoachmarks = completed
                showingWelcome = false
            }
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
            if isUITesting {
                seedUITestSample()
                // Verification harness only: batchable same-day dues.
                if ProcessInfo.processInfo.arguments.contains("-seedBatch") {
                    try? SeedData.seedBatchSampleIfNeeded(in: modelContext)
                }
            }
            applyInitialSidebarSelection()
            await refreshNotifications()
            // A notification tap may have cold-started the app before this view
            // existed — consume any deep link that's already waiting.
            handleDeepLink(notifications.pendingDeepLink)
            maybeStartOnboarding()
        }
        .onChange(of: contexts) { _, _ in
            applyInitialSidebarSelection()
        }
        .onChange(of: sidebarSelection) { _, _ in
            // Switching programs returns to the list — a pushed detail from the
            // previous program no longer applies.
            path = NavigationPath()
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

    // MARK: Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            Text("Today, \(Date.now.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.spacing8)
                .padding(.top, Theme.spacing4)

            ProgramsBar(
                contexts: contexts,
                selection: $sidebarSelection,
                attentionCount: attentionCount,
                onAddContext: { newContextName = ""; showingAddContext = true },
                onRename: { context in
                    renameContextName = context.name
                    contextPendingRename = context
                },
                onRequestDelete: { requestDeleteContext($0) }
            )
            .padding(.top, Theme.spacing4)

            Divider()
                .padding(.top, Theme.spacing4)

            contentForSelection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var contentForSelection: some View {
        switch sidebarSelection {
        case .attention:
            AttentionListView()
        case .context(let context):
            ContextListView(context: context)
                .id(context.persistentModelID)
        case nil:
            ContentUnavailableView(
                "Select a Program",
                systemImage: "square.grid.2x2",
                description: Text("Pick a program above to see its supplies.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// First-launch landing: open the first context so items are visible right
    /// away. UI tests stay on the placeholder and drive selection explicitly.
    private func applyInitialSidebarSelection() {
        guard sidebarSelection == nil, !isUITesting else { return }
        if let first = contexts.first { sidebarSelection = .context(first) }
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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

    // MARK: First-run guide

    /// One short coach-mark shown after the welcome cards (iPad only). It points at
    /// the empty context's prominent "Start from a Template" button — a content
    /// element that's reliably present and correctly positioned on first launch.
    private var coachmarkSteps: [CoachmarkStep] {
        [
            CoachmarkStep(target: .addFirst,
                          title: "Add your first supplies",
                          message: "Start from a ready-made checklist, or add items yourself. Once items are in, tap an item's green ✓ to mark it checked — and Needs Attention will show whatever's due next.")
        ]
    }

    /// Show the guide on a real first launch, or whenever a test/Settings asks.
    private func maybeStartOnboarding() {
        let args = ProcessInfo.processInfo.arguments
        // Verification hook: jump straight to the coach-marks (skip the cards).
        if args.contains("-showCoachmarks") {
            runCoachmarks = true
            return
        }
        let forced = args.contains("-showOnboarding")
        if forced || (!settings.hasCompletedOnboarding && !isUITesting) {
            showingWelcome = true
        }
    }

    /// Replays the guide on demand (from Settings).
    private func startOnboarding() {
        showingSettings = false
        showingWelcome = true
    }

    /// After the welcome cards close: run coach-marks if the user tapped
    /// "Get Started" (not "Skip"); otherwise we're done.
    private func afterWelcome() {
        if wantsCoachmarks {
            runCoachmarks = true
        } else {
            completeOnboarding()
        }
        wantsCoachmarks = false
    }

    private func completeOnboarding() {
        settings.hasCompletedOnboarding = true
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
        let wasSelected: Bool = {
            if case .context(let selected) = sidebarSelection {
                return selected.persistentModelID == context.persistentModelID
            }
            return false
        }()
        for item in items { modelContext.delete(item) }
        modelContext.delete(context)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            contextActionError = error.localizedDescription
            return
        }

        if wasSelected {
            sidebarSelection = nil   // onChange(contexts) re-lands on the first context
            path = NavigationPath()
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

// MARK: - Global search result row

private struct GlobalSearchResultRow: View {
    let item: SupplyItem
    let status: SupplyStatus

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            Image(status.style.iconName)
                .iconSized(17)
                .foregroundStyle(status.style.color)
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
