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
        // The app pushes a reload on every data change; the hourly refresh just
        // keeps relative "due" wording from going stale in between.
        let entry = AttentionEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

// MARK: - Views

struct AttentionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttentionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: small
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var attentionCount: Int { entry.snapshot?.attentionTotal ?? 0 }

    private var nextUp: WidgetSnapshot.Upcoming? {
        entry.snapshot?.upcoming.first { $0.dueDate > entry.date }
    }

    @ViewBuilder private var small: some View {
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
                if let nextUp {
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

    @ViewBuilder private var circular: some View {
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

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if attentionCount > 0 {
                Text("\(attentionCount) need\(attentionCount == 1 ? "s" : "") attention")
                    .font(.headline)
            } else {
                Text("Supplies: all good")
                    .font(.headline)
            }
            if let nextUp {
                Text("\(nextUp.name) due \(nextUp.dueDate, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
