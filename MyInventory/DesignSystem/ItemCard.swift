//
//  ItemCard.swift
//  MyInventory
//
//  Primary item card for the vertical layout: a self-contained panel with the
//  item's identity (thumbnail + name + status), its LAST CHECKED / INTERVAL /
//  NEXT DUE stats, and inline Check / Edit / Delete actions — mirroring the
//  teacher's "Supplies Check" demo while keeping our native styling.
//
//  • The identity area is a `NavigationLink(value:)` → pushes ItemDetailView
//    (full detail + check history). Register the destination once on the host
//    NavigationStack (ContentView).
//  • Action buttons are `.borderless` so a tap fires the action instead of the
//    surrounding link.
//  Status is passed in already-derived; never recomputed here.
//

import SwiftUI
import SwiftData
import UIKit

struct ItemCard: View {
    let item: SupplyItem
    let status: SupplyStatus
    /// "Vehicle › Emergency Kit" — shown in cross-context lists (attention view)
    /// where the user needs to know where the item physically lives.
    var breadcrumb: String? = nil
    /// Quick "looked at it, all good" check. Shown as a prominent inline button.
    var onCheck: (() -> Void)? = nil
    /// Opens the edit form (presented as a centered sheet by the call site).
    var onEdit: (() -> Void)? = nil
    /// Requests deletion — the call site routes this through a confirmation dialog.
    var onDelete: (() -> Void)? = nil

    private var hasActions: Bool { onCheck != nil || onEdit != nil || onDelete != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing6) {
            NavigationLink(value: item) {
                identityBlock
            }
            .buttonStyle(.plain)

            statsRow

            if hasActions {
                Divider()
                actionRow
            }
        }
        .padding(Theme.spacing6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            surfaceTint,
            in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(status.style.color.opacity(status == .overdue || status == .needsAttention ? 0.35 : 0), lineWidth: 1)
        )
        .elevation(.card)
    }

    // MARK: Identity (tap → detail)

    private var identityBlock: some View {
        HStack(alignment: .top, spacing: Theme.spacing6) {
            thumbnail

            VStack(alignment: .leading, spacing: Theme.spacing2) {
                HStack(spacing: Theme.spacing2) {
                    Text(item.name.isEmpty ? "Untitled item" : item.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let quantity = item.quantity {
                        Text("×\(quantity)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let breadcrumb {
                    Text(breadcrumb)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: Theme.spacing4) {
                    StatusBadge(status: status)
                    if let loc = item.storageLocation, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, Theme.spacing2)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        // Downsampled + cached — never decode the full stored image per card per render.
        if let data = item.photo,
           let ui = Thumbnailer.thumbnail(for: data, cacheKey: "\(item.uuid.uuidString)-\(data.count)") {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            // No photo yet → name-matched default artwork (Iconography table).
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(Iconography.itemIconName(forItemNamed: item.name))
                        .iconSized(30)
                        .foregroundStyle(Theme.accent)
                )
        }
    }

    // MARK: Stats (last checked / interval / next due)

    private var statsRow: some View {
        HStack(alignment: .top, spacing: Theme.spacing6) {
            statBlock("LAST CHECKED", lastCheckedText)
            statBlock("INTERVAL", intervalText)
            statBlock("NEXT DUE", nextDueText)
        }
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lastCheckedText: String {
        guard let last = item.lastCheck?.date else { return "Never" }
        return last.formatted(date: .abbreviated, time: .omitted)
    }

    private var intervalText: String {
        guard let months = item.checkIntervalMonths else { return "Never" }
        if months % 12 == 0 {
            let years = months / 12
            return "\(years) yr"
        }
        return "\(months) mo"
    }

    private var nextDueText: String {
        guard let due = item.nextDueDate() else { return "—" }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: Theme.spacing4) {
            if let onCheck {
                actionButton("Check", systemImage: "checkmark.circle.fill",
                             tint: Theme.statusOK, action: onCheck)
            }
            if let onEdit {
                actionButton("Edit", systemImage: "pencil",
                             tint: Theme.accent, action: onEdit)
            }
            Spacer(minLength: 0)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.statusOverdue)
                        .frame(width: 40, height: 34)
                        .background(Theme.statusOverdue.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                // .borderless so the tap fires Delete instead of the card's link.
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(item.name)")
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String,
                              tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, Theme.spacing4)
                .padding(.horizontal, Theme.spacing6)
                .background(tint, in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
                .foregroundStyle(Theme.badgeInkOnFill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private var surfaceTint: Color {
        switch status {
        case .overdue:        Theme.statusOverdue.opacity(0.06)
        case .needsAttention: Theme.statusNeedsAttention.opacity(0.06)
        case .dueSoon:        Theme.statusDueSoon.opacity(0.05)
        default:              Theme.cardSurface
        }
    }
}

@MainActor
private func makeItemCardPreviewContainer() -> ModelContainer {
    let container = try! ModelContainer(
        for: SupplyItem.self, SupplyCategory.self, SupplyContext.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext
    let cat = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
    ctx.insert(cat)

    let overdue = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6, storageLocation: "Trunk")
    overdue.category = cat
    ctx.insert(overdue)
    let c1 = CheckRecord(date: Calendar.current.date(byAdding: .month, value: -8, to: .now)!, result: .ok)
    c1.item = overdue
    ctx.insert(c1)

    let dueSoon = SupplyItem(name: "Emergency Blanket", checkIntervalMonths: 12)
    dueSoon.category = cat
    ctx.insert(dueSoon)
    let c2 = CheckRecord(date: Calendar.current.date(byAdding: .day, value: -355, to: .now)!, result: .ok)
    c2.item = dueSoon
    ctx.insert(c2)

    let ok = SupplyItem(name: "Jumper Cables", checkIntervalMonths: 12)
    ok.category = cat
    ctx.insert(ok)
    let c3 = CheckRecord(date: .now, result: .ok)
    c3.item = ok
    ctx.insert(c3)

    let never = SupplyItem(name: "Road Map", checkIntervalMonths: nil)
    never.category = cat
    ctx.insert(never)

    try? ctx.save()
    return container
}

#Preview("ItemCard states") {
    let container = makeItemCardPreviewContainer()
    let ctx = container.mainContext
    let items = (try? ctx.fetch(FetchDescriptor<SupplyItem>())) ?? []

    return NavigationStack {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.spacing6)],
                      spacing: Theme.spacing6) {
                ForEach(items) { item in
                    ItemCard(item: item,
                             status: item.status(leadTimeDays: 14),
                             onCheck: {}, onEdit: {}, onDelete: {})
                }
            }
            .padding(Theme.spacing8)
        }
        .background(ScreenBackground())
    }
    .modelContainer(container)
}
