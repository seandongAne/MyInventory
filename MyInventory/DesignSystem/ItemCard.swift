//
//  ItemCard.swift
//  MyInventory
//
//  Primary list row: left accent bar + thumbnail + text block + StatusBadge.
//  Status is passed in already-derived; never recomputed here.
//

import SwiftUI
import SwiftData
import UIKit

struct ItemCard: View {
    let item: SupplyItem
    let status: SupplyStatus
    let nextDueText: String?
    /// "Vehicle › Emergency Kit" — shown in cross-context lists (attention view)
    /// where the user needs to know where the item physically lives.
    var breadcrumb: String? = nil

    var body: some View {
        HStack(spacing: Theme.spacing6) {

            // Leading status accent bar
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(status.style.color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

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
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let breadcrumb {
                    Text(breadcrumb)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let nextDueText {
                    Text(nextDueText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
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

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(Theme.spacing6)
        .background(
            surfaceTint,
            in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(status.style.color.opacity(status == .overdue || status == .needsAttention ? 0.35 : 0), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(status.style.label)")
    }

    @ViewBuilder private var thumbnail: some View {
        // Downsampled + cached — never decode the full stored image per row per render.
        if let data = item.photo,
           let ui = Thumbnailer.thumbnail(for: data, cacheKey: "\(item.uuid.uuidString)-\(data.count)") {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // No photo yet → name-matched default artwork (Iconography table).
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(Iconography.itemIconName(forItemNamed: item.name))
                        .iconSized(26)
                        .foregroundStyle(Theme.accent)
                )
        }
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

    ScrollView {
        LazyVStack(spacing: Theme.spacing6) {
            ForEach(items) { item in
                ItemCard(item: item,
                         status: item.status(leadTimeDays: 14),
                         nextDueText: item.statusDetailLabel(globalLead: 14))
            }
        }
        .padding(.horizontal, Theme.spacing8)
        .padding(.top, Theme.spacing6)
    }
    .background(ScreenBackground())
    .modelContainer(container)
}
