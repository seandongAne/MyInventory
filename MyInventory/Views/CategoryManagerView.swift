//
//  CategoryManagerView.swift
//  MyInventory
//
//  Create / remove categories. Deleting a non-empty category prompts the user
//  to pick a destination for its items. The Uncategorized bucket shows its
//  items inline so they can be moved out at any time.
//

import SwiftUI
import SwiftData

struct CategoryManagerView: View {
    let context: SupplyContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<SupplyCategory> { $0.deletedAt == nil }, sort: \SupplyCategory.sortOrder)
    private var allCategories: [SupplyCategory]

    @State private var showingAddAlert = false
    @State private var newName = ""
    @State private var categoryToRename: SupplyCategory?
    @State private var renameName = ""
    @State private var saveError: String?

    // Delete-with-move flow
    @State private var categoryToDelete: SupplyCategory?
    @State private var moveDestination: SupplyCategory?
    @State private var showingMoveSheet = false
    @State private var moveError: String?

    // Move a single item to another category
    @State private var itemToMove: SupplyItem?
    @State private var showingItemMoveSheet = false

    private var categories: [SupplyCategory] {
        allCategories.filter { $0.context?.persistentModelID == context.persistentModelID }
    }

    private var otherCategories: [SupplyCategory] {
        categories.filter { $0.persistentModelID != categoryToDelete?.persistentModelID }
    }

    var body: some View {
        List {
            if categories.isEmpty {
                ContentUnavailableView(
                    "No categories",
                    systemImage: "folder",
                    description: Text("Add a category to start organizing this context.")
                )
            } else {
                ForEach(categories) { category in
                    categoryRow(category)
                }
                .onDelete(perform: initiateDelete)
            }
        }
        .navigationTitle("\(context.name) Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    newName = ""
                    showingAddAlert = true
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
            }
        }
        .alert("New Category", isPresented: $showingAddAlert) {
            TextField("Category name", text: $newName)
            Button("Add") { addCategory() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename Category", isPresented: Binding(
            get: { categoryToRename != nil },
            set: { if !$0 { categoryToRename = nil } }
        )) {
            TextField("Name", text: $renameName)
            Button("Save") { renameCategory() }
            Button("Cancel", role: .cancel) { categoryToRename = nil }
        }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let msg = saveError { Text(msg) }
        }
        // Delete with move destination picker
        .sheet(isPresented: $showingMoveSheet) {
            moveItemsSheet
        }
        // Move single item
        .sheet(isPresented: $showingItemMoveSheet) {
            if let item = itemToMove {
                moveItemSheet(item: item)
            }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func categoryRow(_ category: SupplyCategory) -> some View {
        let items = category.unwrappedItems
        DisclosureGroup {
            if items.isEmpty {
                Text("No items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.sorted(by: { $0.name < $1.name })) { item in
                    HStack {
                        Text(item.name)
                            .font(.subheadline)
                        Spacer()
                        Button {
                            itemToMove = item
                            showingItemMoveSheet = true
                        } label: {
                            Label("Move", systemImage: "arrow.up.arrow.down")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } label: {
            HStack {
                Label(category.name, systemImage: category.isUncategorized ? "tray" : "folder")
                Spacer()
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .deleteDisabled(category.isUncategorized && !items.isEmpty)
        .contextMenu {
            // The Uncategorized bucket's identity IS its name — renaming it would
            // silently detach the fallback semantics, so it can't be renamed.
            if !category.isUncategorized {
                Button {
                    renameName = category.name
                    categoryToRename = category
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if !(category.isUncategorized && !items.isEmpty) {
                Button(role: .destructive) {
                    requestDelete(category)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Sheets

    private var moveItemsSheet: some View {
        NavigationStack {
            let cat = categoryToDelete
            let itemCount = cat?.unwrappedItems.count ?? 0
            Form {
                Section {
                    Picker("Move items to", selection: $moveDestination) {
                        Text("Uncategorized").tag(nil as SupplyCategory?)
                        ForEach(otherCategories.filter { !$0.isUncategorized }) { c in
                            Text(c.name).tag(c as SupplyCategory?)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Move \(itemCount) item\(itemCount == 1 ? "" : "s") to")
                } footer: {
                    Text("Then delete the \(cat?.name ?? "") category.")
                }
            }
            .navigationTitle("Delete Category")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Couldn't delete category", isPresented: Binding(
                get: { moveError != nil },
                set: { if !$0 { moveError = nil } }
            )) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                if let moveError { Text(moveError) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingMoveSheet = false
                        categoryToDelete = nil
                        moveDestination = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        confirmDelete()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moveItemSheet(item: SupplyItem) -> some View {
        let destinations = categories.filter {
            $0.persistentModelID != item.category?.persistentModelID
        }
        NavigationStack {
            Form {
                Section {
                    ForEach(destinations) { cat in
                        Button {
                            item.move(to: cat)   // reassign + touch() so the move wins LWW on merge
                            saveAndDismissItemMove()
                        } label: {
                            HStack {
                                Label(cat.name, systemImage: cat.isUncategorized ? "tray" : "folder")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text("Move \(item.name) to")
                }
            }
            .navigationTitle("Move Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingItemMoveSheet = false
                        itemToMove = nil
                    }
                }
            }
        }
    }

    // MARK: Mutations

    private func addCategory() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.compare(SupplyCategory.uncategorizedName, options: .caseInsensitive) != .orderedSame else {
            saveError = "“\(SupplyCategory.uncategorizedName)” is reserved for items whose category was deleted."
            newName = ""
            return
        }
        guard !categories.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else {
            saveError = "A category named “\(trimmed)” already exists in \(context.name)."
            newName = ""
            return
        }
        let nextOrder = (categories.map(\.sortOrder).max() ?? -1) + 1
        let category = SupplyCategory(name: trimmed, sortOrder: nextOrder)
        category.context = context
        modelContext.insert(category)
        do {
            try modelContext.save()
        } catch {
            // Discard the pending insert so it can't be flushed by a later unrelated
            // save or cause a duplicate on retry (P1).
            modelContext.rollback()
            saveError = error.localizedDescription
        }
        newName = ""
    }

    private func initiateDelete(_ offsets: IndexSet) {
        guard let index = offsets.first else { return }
        requestDelete(categories[index])
    }

    private func requestDelete(_ category: SupplyCategory) {
        // Uncategorized with items: deletion is disabled at the row level. An
        // EMPTY Uncategorized is safe to delete (it's recreated on demand), and
        // falls through to the empty-category path below — no silent no-op.
        if category.isUncategorized && !category.unwrappedItems.isEmpty { return }

        if category.unwrappedItems.isEmpty {
            // Empty category — soft-delete immediately without a sheet.
            category.markDeleted()
            save()
        } else {
            // Non-empty — ask where to move the items first.
            categoryToDelete = category
            moveDestination = nil
            showingMoveSheet = true
        }
    }

    private func renameCategory() {
        guard let category = categoryToRename else { return }
        categoryToRename = nil
        let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameName = ""
        guard !trimmed.isEmpty, trimmed != category.name else { return }
        guard trimmed.compare(SupplyCategory.uncategorizedName, options: .caseInsensitive) != .orderedSame else {
            saveError = "“\(SupplyCategory.uncategorizedName)” is reserved for items whose category was deleted."
            return
        }
        guard !categories.contains(where: {
            $0.persistentModelID != category.persistentModelID
            && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else {
            saveError = "A category named “\(trimmed)” already exists in \(context.name)."
            return
        }
        category.name = trimmed
        category.touch()
        save()
    }

    private func confirmDelete() {
        guard let category = categoryToDelete else { return }
        // Use the relationship directly — no fetch that could fail and silently
        // drop items, which would then be orphaned by the .nullify delete rule.
        let items = category.unwrappedItems
        let destination = moveDestination ?? uncategorizedBucket()
        for item in items {
            item.move(to: destination)   // reparent + touch() must win LWW on the next merge
        }
        category.markDeleted()   // soft-delete the now-empty category

        do {
            try modelContext.save()
        } catch {
            // Keep the sheet open with an in-context error so the user doesn't lose
            // their move selection and can retry (P3).
            modelContext.rollback()
            moveError = error.localizedDescription
            return
        }

        showingMoveSheet = false
        categoryToDelete = nil
        moveDestination = nil
    }

    private func saveAndDismissItemMove() {
        do {
            try modelContext.save()
        } catch {
            // Revert the in-memory category change so it can't look moved-but-unsaved (P1-c).
            modelContext.rollback()
            saveError = error.localizedDescription
        }
        showingItemMoveSheet = false
        itemToMove = nil
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }

    private func uncategorizedBucket() -> SupplyCategory {
        SupplyCategory.uncategorizedBucket(in: context, modelContext: modelContext)
    }
}
