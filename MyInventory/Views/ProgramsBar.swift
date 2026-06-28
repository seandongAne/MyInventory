//
//  ProgramsBar.swift
//  MyInventory
//
//  Horizontal "Programs" selector pinned at the top of the vertical layout —
//  it replaces the old NavigationSplitView sidebar. A "Needs Attention" card
//  plus one card per context (with overdue / due-soon pills), and a trailing
//  "+" to add a context. Selecting a card drives the page's content below.
//

import SwiftUI
import SwiftData

struct ProgramsBar: View {
    let contexts: [SupplyContext]
    @Binding var selection: SidebarSelection?
    let attentionCount: Int
    var onAddContext: () -> Void
    var onRename: (SupplyContext) -> Void
    var onRequestDelete: (SupplyContext) -> Void

    @Environment(SettingsStore.self) private var settings

    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing4) {
            Text("Programs")
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.spacing8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacing6) {
                    attentionCard
                    ForEach(contexts) { context in
                        contextCard(context)
                    }
                    addCard
                }
                .padding(.horizontal, Theme.spacing8)
                .padding(.vertical, Theme.spacing2)
            }
        }
    }

    // MARK: Cards

    private var attentionCard: some View {
        Button {
            selection = .attention
        } label: {
            card(title: "Needs Attention",
                 iconName: "icon-status-attention",
                 tint: Theme.statusOverdue,
                 selected: isAttentionSelected) {
                if attentionCount > 0 {
                    pill("\(attentionCount) to review", color: Theme.statusOverdue, active: true)
                } else {
                    pill("All clear", color: Theme.statusOK, active: false)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func contextCard(_ context: SupplyContext) -> some View {
        let lead = settings.globalLeadTimeDays
        let items = context.allItems
        let overdue = items.filter { $0.status(leadTimeDays: lead) == .overdue }.count
        let soon = items.filter { $0.status(leadTimeDays: lead) == .dueSoon }.count
        let brand = SeedData.color(forContextNamed: context.name)

        return Button {
            selection = .context(context)
        } label: {
            card(title: context.name,
                 iconName: Iconography.contextIconName(forContextNamed: context.name),
                 tint: brand,
                 selected: isSelected(context)) {
                pill("\(overdue) overdue", color: Theme.statusOverdue, active: overdue > 0)
                pill("\(soon) soon", color: Theme.statusDueSoon, active: soon > 0)
            }
        }
        .buttonStyle(.plain)
        // Long-press menu mirrors the old sidebar row: rename / delete a context.
        .contextMenu {
            Button {
                onRename(context)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onRequestDelete(context)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addCard: some View {
        Button(action: onAddContext) {
            VStack(spacing: Theme.spacing4) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.accent)
                Text("Add")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 96, height: cardHeight)
            .frame(maxWidth: .infinity)
            .background(Theme.accentSoft,
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Context")
    }

    // MARK: Card shell

    @ViewBuilder
    private func card<Pills: View>(title: String, iconName: String, tint: Color,
                                   selected: Bool,
                                   @ViewBuilder pills: () -> Pills) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(iconName)
                    .iconSized(20)
                    .foregroundStyle(tint)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: Theme.spacing2) {
                pills()
            }
        }
        .padding(Theme.spacing6)
        .frame(width: cardWidth, height: cardHeight, alignment: .leading)
        .background(Theme.cardSurface,
                    in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2)
        )
        .elevation(.card)
    }

    private func pill(_ text: String, color: Color, active: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(active ? color : Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((active ? color : Theme.textSecondary).opacity(0.14), in: Capsule())
            // Two pills share a fixed-width (168pt) card. Normal counts fit, but
            // 3-digit counts or longer localized labels must scale down to fit
            // rather than truncate/overflow the card on an 11" iPad.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: Selection helpers

    private func isSelected(_ context: SupplyContext) -> Bool {
        if case .context(let selected) = selection {
            return selected.persistentModelID == context.persistentModelID
        }
        return false
    }

    private var isAttentionSelected: Bool {
        if case .attention = selection { return true }
        return false
    }
}
