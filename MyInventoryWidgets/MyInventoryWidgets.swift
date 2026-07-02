//
//  MyInventoryWidgets.swift
//  MyInventoryWidgets
//
//  Home-screen + lock-screen widget showing how many supplies need attention
//  and what's due next. The widget never touches the SwiftData store — it
//  renders the JSON snapshot the app writes to the shared app-group container
//  on every data change / foreground (see WidgetBridge.swift in the app target).
//

import WidgetKit
import SwiftUI

// MARK: - Snapshot (mirror of WidgetBridge.Snapshot — keep in sync)

struct WidgetSnapshot: Codable {
    struct Upcoming: Codable {
        let name: String
        let dueDate: Date
    }
    let generatedAt: Date
    let overdue: Int
    let flagged: Int
    let neverChecked: Int
    let upcoming: [Upcoming]

    var attentionTotal: Int { overdue + flagged + neverChecked }

    /// How many `upcoming` due dates have passed since the snapshot was
    /// written. The widget can't re-derive status without the store, but it
    /// CAN see a frozen future due date slip past the current timeline entry —
    /// counting those lets a stale snapshot degrade toward "needs attention"
    /// instead of asserting "All good" forever.
    func newlyDueCount(asOf date: Date) -> Int {
        upcoming.filter { $0.dueDate <= date }.count
    }

    /// Attention count to display at `date`: the counts frozen at
    /// `generatedAt` plus everything that has come due since.
    func attentionTotal(asOf date: Date) -> Int {
        attentionTotal + newlyDueCount(asOf: date)
    }

    /// Timeline-entry instants: `now`, plus one entry at each still-future
    /// due date, ascending — so the widget flips to "needs attention" at the
    /// moment an item comes due even if WidgetKit grants no timeline reload
    /// until then.
    func timelineEntryDates(now: Date) -> [Date] {
        [now] + upcoming.map(\.dueDate).filter { $0 > now }.sorted()
    }

    static let appGroupID = "group.CharlieW.MyInventory"
    static let filename = "widget-snapshot.json"

    static func load() -> WidgetSnapshot? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static let placeholder = WidgetSnapshot(
        generatedAt: .now,
        overdue: 2,
        flagged: 1,
        neverChecked: 0,
        upcoming: [Upcoming(name: "First Aid Kit", dueDate: .now.addingTimeInterval(86_400 * 12))]
    )
}

// MARK: - Timeline

struct AttentionEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct AttentionProvider: TimelineProvider {
    func placeholder(in context: Context) -> AttentionEntry {
        AttentionEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AttentionEntry) -> Void) {
        completion(AttentionEntry(date: .now, snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AttentionEntry>) -> Void) {
        // The app pushes a reload on every data change; the hourly refresh
        // re-reads the file. The snapshot itself is frozen at generatedAt, so
        // in between we pre-bake one entry at each upcoming due date — the
        // view counts dues that have passed its entry.date, so the widget
        // flips to "needs attention" the moment an item comes due instead of
        // showing "All good" until the next reload.
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        let dates = snapshot?.timelineEntryDates(now: now) ?? [now]
        let entries = dates.map { AttentionEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

// MARK: - Views

struct AttentionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttentionEntry

    var body: some View {
        // No snapshot (widget added before first app launch, file protected
        // before first unlock, app group misprovisioned, schema mismatch) is
        // UNKNOWN status, never "All good" — that would be a false safety
        // signal for an emergency-supplies widget.
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular: circular(snapshot)
                case .accessoryRectangular: rectangular(snapshot)
                default: small(snapshot)
                }
            } else {
                switch family {
                case .accessoryCircular: circularUnavailable
                case .accessoryRectangular: rectangularUnavailable
                default: smallUnavailable
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // Dues that passed after the snapshot was written count as attention, so a
    // stale snapshot degrades toward "needs attention", never a stale "All good".
    private func attentionCount(_ snapshot: WidgetSnapshot) -> Int {
        snapshot.attentionTotal(asOf: entry.date)
    }

    private func nextUp(_ snapshot: WidgetSnapshot) -> WidgetSnapshot.Upcoming? {
        snapshot.upcoming.first { $0.dueDate > entry.date }
    }

    @ViewBuilder private func small(_ snapshot: WidgetSnapshot) -> some View {
        let attentionCount = self.attentionCount(snapshot)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: attentionCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(attentionCount > 0 ? .red : .green)
                Spacer()
            }
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("need\(attentionCount == 1 ? "s" : "") attention")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("All good")
                    .font(.title3.weight(.semibold))
                if let nextUp = nextUp(snapshot) {
                    Text("\(nextUp.name) due \(nextUp.dueDate, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Nothing scheduled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func circular(_ snapshot: WidgetSnapshot) -> some View {
        let attentionCount = self.attentionCount(snapshot)
        if attentionCount > 0 {
            VStack(spacing: 0) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("\(attentionCount)")
                    .font(.title2.weight(.bold))
            }
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
        }
    }

    @ViewBuilder private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        let attentionCount = self.attentionCount(snapshot)
        VStack(alignment: .leading, spacing: 1) {
            if attentionCount > 0 {
                Text("\(attentionCount) need\(attentionCount == 1 ? "s" : "") attention")
                    .font(.headline)
            } else {
                Text("Supplies: all good")
                    .font(.headline)
            }
            if let nextUp = nextUp(snapshot) {
                Text("\(nextUp.name) due \(nextUp.dueDate, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Snapshot-unavailable (neutral, deliberately neither green nor red)

    @ViewBuilder private var smallUnavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("Open MyInventory")
                .font(.title3.weight(.semibold))
            Text("No supplies status yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var circularUnavailable: some View {
        VStack(spacing: 0) {
            Image(systemName: "shippingbox")
                .font(.caption2)
            Text("?")
                .font(.title2.weight(.bold))
        }
    }

    @ViewBuilder private var rectangularUnavailable: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("MyInventory")
                .font(.headline)
            Text("Open the app to update supplies status")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MyInventoryAttention", provider: AttentionProvider()) { entry in
            AttentionWidgetView(entry: entry)
        }
        .configurationDisplayName("Supplies Status")
        .description("How many supplies are overdue, flagged, or waiting on a first check.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct MyInventoryWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AttentionWidget()
    }
}
