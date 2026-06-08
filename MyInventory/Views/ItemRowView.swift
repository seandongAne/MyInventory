//
//  ItemRowView.swift
//  MyInventory
//
//  One item row: thumbnail/symbol, name, derived status badge, next-due detail,
//  and small location/photo indicators (Dev Plan §7, §6.4).
//

import SwiftUI
import UIKit

struct ItemRowView: View {
    let item: SupplyItem
    let globalLeadTimeDays: Int
    /// When true, shows the item's category name — useful in search results (F4).
    var showCategory: Bool = false

    private var status: SupplyStatus {
        item.status(leadTimeDays: globalLeadTimeDays)
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? "Untitled item" : item.name)
                    .font(.headline)
                    .lineLimit(1)

                if showCategory, let catName = item.category?.name, !catName.isEmpty {
                    Text(catName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    indicators
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // Subtle highlight + leading accent for items needing attention.
        .listRowBackground(status.isAttention ? Color.red.opacity(0.06) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.statusDetailLabel(globalLead: globalLeadTimeDays))")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = item.photo, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 10))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(status.color.opacity(0.12))
                Image(systemName: status.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(status.color)
            }
            .frame(width: 48, height: 48)
        }
    }

    @ViewBuilder
    private var indicators: some View {
        HStack(spacing: 6) {
            if item.hasLocation {
                Image(systemName: "mappin.and.ellipse")
            }
            if item.hasPhoto {
                Image(systemName: "photo")
            }
        }
        .imageScale(.small)
        .foregroundStyle(.secondary)
    }
}
