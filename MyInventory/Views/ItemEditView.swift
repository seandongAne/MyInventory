//
//  ItemEditView.swift
//  MyInventory
//
//  Create / edit an item (P0-1). Name + context + category are required; the
//  interval, lead-time override, storage location, and photo are all optional
//  and never block saving (Dev Plan §M1, §M5).
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

enum ItemEditMode {
    case create(context: SupplyContext)
    case edit(SupplyItem)
}

struct ItemEditView: View {
    let mode: ItemEditMode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyContext.sortOrder) private var contexts: [SupplyContext]
    @Query(sort: \SupplyCategory.sortOrder) private var allCategories: [SupplyCategory]

    // Editable fields
    @State private var name: String
    @State private var selectedContext: SupplyContext?
    @State private var selectedCategory: SupplyCategory?
    @State private var hasInterval: Bool
    @State private var intervalMonths: Int
    @State private var useDefaultLead: Bool
    @State private var leadDays: Int
    @State private var trackQuantity: Bool
    @State private var quantity: Int
    @State private var location: String
    @State private var photoData: Data?

    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showingCamera = false
    @State private var showingNewCategoryAlert = false
    @State private var newCategoryName = ""
    @State private var didApplyDefaults = false
    @State private var saveError: String?
    @State private var photoLoadFailed = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    init(mode: ItemEditMode) {
        self.mode = mode
        switch mode {
        case .create(let context):
            _name = State(initialValue: "")
            _selectedContext = State(initialValue: context)
            _selectedCategory = State(initialValue: nil)
            _hasInterval = State(initialValue: false)
            _intervalMonths = State(initialValue: 12)
            _useDefaultLead = State(initialValue: true)
            _leadDays = State(initialValue: 7)   // updated in applyDefaultsIfNeeded
            _trackQuantity = State(initialValue: false)
            _quantity = State(initialValue: 1)
            _location = State(initialValue: "")
            _photoData = State(initialValue: nil)
        case .edit(let item):
            _name = State(initialValue: item.name)
            _selectedContext = State(initialValue: item.category?.context)
            _selectedCategory = State(initialValue: item.category)
            _hasInterval = State(initialValue: item.checkIntervalMonths != nil)
            _intervalMonths = State(initialValue: item.checkIntervalMonths ?? 12)
            _useDefaultLead = State(initialValue: item.leadTimeDaysOverride == nil)
            _leadDays = State(initialValue: item.leadTimeDaysOverride ?? 7)  // updated in applyDefaultsIfNeeded
            _trackQuantity = State(initialValue: item.quantity != nil)
            _quantity = State(initialValue: item.quantity ?? 1)
            _location = State(initialValue: item.storageLocation ?? "")
            _photoData = State(initialValue: item.photo)
        }
    }

    var body: some View {
        Form {
            nameSection
            placementSection
            intervalSection
            leadSection
            quantitySection
            locationSection
            photoSection
        }
        .navigationTitle(isEditing ? "Edit Item" : "New Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: applyDefaultsIfNeeded)
        .onChange(of: photoItem) { _, newItem in
            Task {
                guard let newItem else { return }
                do {
                    if let raw = try await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: raw),
                       let compressed = uiImage.compressedData() {
                        photoData = compressed
                    } else {
                        photoItem = nil
                        photoLoadFailed = true
                    }
                } catch {
                    photoItem = nil
                    photoLoadFailed = true
                }
            }
        }
        .alert("New Category", isPresented: $showingNewCategoryAlert) {
            TextField("Category name", text: $newCategoryName)
            Button("Add") { addCategory() }
            Button("Cancel", role: .cancel) { newCategoryName = "" }
        } message: {
            Text("Add a category to \(selectedContext?.name ?? "this context").")
        }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let msg = saveError { Text(msg) }
        }
        .alert("Photo Unavailable", isPresented: $photoLoadFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The selected photo could not be loaded. Please try another image.")
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section("Name") {
            TextField("e.g. Canned tuna", text: $name)
                .textInputAutocapitalization(.sentences)
        }
    }

    private var placementSection: some View {
        Section {
            Picker("Context", selection: $selectedContext) {
                ForEach(contexts) { context in
                    Text(context.name).tag(context as SupplyContext?)
                }
            }
            .onChange(of: selectedContext) { _, _ in
                // Reset category if it no longer belongs to the chosen context.
                if let cat = selectedCategory,
                   cat.context?.persistentModelID != selectedContext?.persistentModelID {
                    selectedCategory = nil
                }
            }

            Picker("Category", selection: $selectedCategory) {
                Text("None").tag(nil as SupplyCategory?)
                ForEach(categoriesForSelectedContext) { category in
                    Text(category.name).tag(category as SupplyCategory?)
                }
            }

            Button {
                newCategoryName = ""
                showingNewCategoryAlert = true
            } label: {
                Label("New Category", systemImage: "folder.badge.plus")
            }
            .disabled(selectedContext == nil)
        } header: {
            Text("Placement")
        } footer: {
            if selectedContext != nil && selectedCategory == nil {
                Text("Select or create a category to save this item.")
            }
        }
    }

    private var intervalSection: some View {
        Section {
            Toggle("Set a re-check interval", isOn: $hasInterval)
            if hasInterval {
                Stepper(value: $intervalMonths, in: 1...240) {
                    LabeledContent("Every", value: intervalDescription)
                }
            }
        } header: {
            Text("Re-check interval")
        } footer: {
            Text(hasInterval
                 ? "This item is due for a check \(intervalDescription) after each check."
                 : "\u{201C}Never expires\u{201D}: tracked and checkable, but never flagged or notified.")
        }
    }

    private var leadSection: some View {
        Section {
            Toggle("Use global default (\(settings.globalLeadTimeDays) days)", isOn: $useDefaultLead)
            if !useDefaultLead {
                Stepper(value: $leadDays, in: 0...90) {
                    LabeledContent("Warn me", value: "\(leadDays) day\(leadDays == 1 ? "" : "s") early")
                }
            }
        } header: {
            Text("Advance warning")
        } footer: {
            Text("How far ahead of the due date you're warned. Only applies when an interval is set.")
        }
        .disabled(!hasInterval)
    }

    private var quantitySection: some View {
        Section {
            Toggle("Track quantity", isOn: $trackQuantity)
            if trackQuantity {
                Stepper(value: $quantity, in: 1...9999) {
                    LabeledContent("On hand", value: "\(quantity)")
                }
            }
        } header: {
            Text("Quantity (optional)")
        } footer: {
            Text("How many you keep (e.g. 4 batteries). You can update it whenever you log a check.")
        }
    }

    private var locationSection: some View {
        Section("Storage location (optional)") {
            TextField("e.g. Garage shelf 2", text: $location)
        }
    }

    private var photoSection: some View {
        Section("Photo (optional)") {
            if let photoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(.rect(cornerRadius: 12))
            }
            if cameraAvailable {
                Button {
                    showingCamera = true
                } label: {
                    Label(photoData == nil ? "Take Photo" : "Retake Photo", systemImage: "camera")
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photoData == nil ? "Choose from Library" : "Replace from Library", systemImage: "photo.on.rectangle")
            }
            if photoData != nil {
                Button(role: .destructive) {
                    photoData = nil
                    photoItem = nil
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                guard let image,
                      let compressed = image.compressedData() else { return }
                photoData = compressed
                photoItem = nil
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Derived

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var categoriesForSelectedContext: [SupplyCategory] {
        guard let selectedContext else { return [] }
        return allCategories
            .filter { $0.context?.persistentModelID == selectedContext.persistentModelID }
    }

    private var intervalDescription: String {
        let months = intervalMonths
        if months % 12 == 0 {
            let years = months / 12
            return "\(years) year\(years == 1 ? "" : "s")"
        }
        return "\(months) month\(months == 1 ? "" : "s")"
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedContext != nil
        && selectedCategory != nil
    }

    // MARK: Actions

    private func applyDefaultsIfNeeded() {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true

        switch mode {
        case .create:
            if let def = settings.defaultIntervalMonthsOrNil {
                hasInterval = true
                intervalMonths = def
            }
            // Prime the custom-lead stepper from the global default (B4).
            leadDays = settings.globalLeadTimeDays
        case .edit(let item):
            // When no per-item override exists, prime the custom stepper from the global
            // default so toggling to "custom" starts at a sensible value (B4).
            if item.leadTimeDaysOverride == nil {
                leadDays = settings.globalLeadTimeDays
            }
        }
    }

    private func addCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let context = selectedContext else { return }
        guard trimmed.compare(SupplyCategory.uncategorizedName, options: .caseInsensitive) != .orderedSame else {
            saveError = "“\(SupplyCategory.uncategorizedName)” is reserved for items whose category was deleted."
            newCategoryName = ""
            return
        }
        if let existing = categoriesForSelectedContext.first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            // Same name already exists — just select it instead of erroring.
            selectedCategory = existing
            newCategoryName = ""
            return
        }
        let nextOrder = (categoriesForSelectedContext.map(\.sortOrder).max() ?? -1) + 1
        let category = SupplyCategory(name: trimmed, sortOrder: nextOrder)
        category.context = context
        modelContext.insert(category)
        do {
            try modelContext.save()
            selectedCategory = category
        } catch {
            // Discard the pending insert so it can't be flushed later or duplicated (P1).
            modelContext.rollback()
            saveError = error.localizedDescription
        }
        newCategoryName = ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = hasInterval ? intervalMonths : nil
        let leadOverride = useDefaultLead ? nil : leadDays

        switch mode {
        case .create:
            let item = SupplyItem(name: trimmedName, checkIntervalMonths: interval)
            item.category = selectedCategory
            item.leadTimeDaysOverride = leadOverride
            item.quantity = trackQuantity ? quantity : nil
            item.storageLocation = trimmedLocation.isEmpty ? nil : trimmedLocation
            item.photo = photoData
            modelContext.insert(item)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                saveError = error.localizedDescription
                return
            }
        case .edit(let item):
            item.name = trimmedName
            item.category = selectedCategory
            item.checkIntervalMonths = interval
            item.leadTimeDaysOverride = leadOverride
            item.quantity = trackQuantity ? quantity : nil
            item.storageLocation = trimmedLocation.isEmpty ? nil : trimmedLocation
            // Don't rewrite the externally-stored blob when the photo is unchanged.
            if item.photo != photoData {
                item.photo = photoData
            }
            do {
                try modelContext.save()
            } catch {
                // Revert the in-memory edits so the object can't diverge from the
                // store while showing the error (P1-c).
                modelContext.rollback()
                saveError = error.localizedDescription
                return
            }
        }

        requestAuthAndReschedule(intervalSet: interval != nil)
        dismiss()
    }

    private func requestAuthAndReschedule(intervalSet: Bool) {
        Task {
            if intervalSet && !settings.notificationsRequested {
                settings.notificationsRequested = true
                _ = await notifications.requestAuthorization()
            }
            notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
        }
    }
}

private extension UIImage {
    /// Resizes to at most `maxDimension` on the longest side and JPEG-compresses (F5).
    func compressedData(maxDimension: CGFloat = 1024, quality: CGFloat = 0.8) -> Data? {
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }.jpegData(compressionQuality: quality)
    }
}

// MARK: - Previews

#Preview("Create item") {
    let container = try! ModelContainer(
        for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext
    let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
    ctx.insert(supplyCtx)
    let cat = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
    cat.context = supplyCtx
    ctx.insert(cat)
    try? ctx.save()

    return NavigationStack {
        ItemEditView(mode: .create(context: supplyCtx))
    }
    .modelContainer(container)
    .environment(SettingsStore())
    .environment(NotificationManager())
}

#Preview("Edit item") {
    let container = try! ModelContainer(
        for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext
    let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
    ctx.insert(supplyCtx)
    let cat = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
    cat.context = supplyCtx
    ctx.insert(cat)
    let item = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6, storageLocation: "Trunk")
    item.category = cat
    ctx.insert(item)
    try? ctx.save()

    return NavigationStack {
        ItemEditView(mode: .edit(item))
    }
    .modelContainer(container)
    .environment(SettingsStore())
    .environment(NotificationManager())
}
