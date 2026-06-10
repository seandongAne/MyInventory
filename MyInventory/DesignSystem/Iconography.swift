//
//  Iconography.swift
//  MyInventory
//
//  Single source of truth mapping domain objects → custom template icons
//  (Assets.xcassets/Icons, the "Quiet Readiness" line family). All assets are
//  monochrome templates: tint via .foregroundStyle. Lookups are pure/testable.
//
//  Note: SF Symbols remain the right choice for generic chrome (plus, trash,
//  folder, chevron…) and for system surfaces that require symbol NAMES
//  (App Intents, the widget). This file owns *identity* icons only:
//  contexts, statuses, and default item artwork.
//

import SwiftUI

enum Iconography {

    // MARK: - Contexts

    /// Custom icon asset for a context, matched by name (mirrors the brand
    /// colors in `SeedData.color(forContextNamed:)`). Falls back to the crate
    /// for any user-created context.
    static func contextIconName(forContextNamed name: String) -> String {
        switch name {
        case "Vehicle": return "icon-context-vehicle"
        case "Bag": return "icon-context-bag"
        case "House": return "icon-context-house"
        default: return "icon-context-generic"
        }
    }

    // MARK: - Default item icons

    /// Default artwork for an item without a photo, inferred from its name.
    /// Case-insensitive substring match against English + Chinese keywords;
    /// first table entry that matches wins, so ORDER MATTERS — specific or
    /// trap-prone entries (mask before food's "面", flame before water's
    /// "water…proof", lantern's "candle" before food's "can") come first.
    static func itemIconName(forItemNamed name: String) -> String {
        let needle = name.lowercased()
        for entry in itemKeywordTable
        where entry.keywords.contains(where: { needle.contains($0) }) {
            return entry.icon
        }
        return "icon-item-generic"
    }

    /// Keyword → asset table. Keywords must be lowercase.
    private static let itemKeywordTable: [(keywords: [String], icon: String)] = [
        (["first aid", "first-aid", "medkit", "急救"],                         "icon-item-first-aid"),
        (["medicine", "pill", "aspirin", "ibuprofen", "bandage", "药", "绷带"], "icon-item-medicine"),
        (["extinguisher", "灭火"],                                             "icon-item-extinguisher"),
        (["mask", "respirator", "n95", "kn95", "口罩", "面罩", "面具"],          "icon-item-mask"),
        (["flashlight", "torch", "headlamp", "手电", "头灯"],                   "icon-item-flashlight"),
        (["lantern", "candle", "lamp", "灯笼", "蜡烛", "营地灯", "油灯"],        "icon-item-lantern"),
        (["power bank", "powerbank", "charger", "充电宝", "移动电源"],           "icon-item-power"),
        (["battery", "batteries", "电池"],                                     "icon-item-battery"),
        (["radio", "walkie", "对讲", "收音"],                                   "icon-item-radio"),
        (["match", "lighter", "flint", "火柴", "打火机", "打火石"],              "icon-item-flame"),
        (["fuel", "gasoline", "petrol", "propane", "汽油", "燃料", "煤气"],      "icon-item-fuel"),
        (["knife", "blade", "multitool", "multi-tool", "刀"],                  "icon-item-knife"),
        (["tool", "wrench", "plier", "screwdriver", "jumper cable",
          "工具", "扳手", "钳", "螺丝刀"],                                       "icon-item-tool"),
        (["rope", "cord", "paracord", "绳"],                                   "icon-item-rope"),
        (["tent", "shelter", "tarp", "帐篷", "天幕"],                           "icon-item-tent"),
        (["sleeping", "blanket", "mat", "pad", "睡袋", "毯", "防潮垫"],          "icon-item-sleeping"),
        (["shirt", "jacket", "cloth", "sock", "poncho", "raincoat",
          "衣", "袜"],                                                         "icon-item-clothing"),
        (["document", "passport", "paper", "id card", "证件", "护照", "文件"],   "icon-item-document"),
        (["cash", "money", "currency", "现金", "钱"],                           "icon-item-cash"),
        (["whistle", "哨"],                                                    "icon-item-whistle"),
        (["food", "can", "tuna", "ration", "mre", "rice", "noodle", "snack",
          "biscuit", "罐头", "食", "米", "面", "干粮"],                          "icon-item-food"),
        (["water", "bottle", "水"],                                            "icon-item-water"),
    ]
}

// MARK: - Check results

extension CheckResult {
    /// Custom template icon for check-history rows and the CheckSheet picker.
    /// UI-layer extension so the (CloudKit-safe) model stays free of asset names.
    var iconName: String {
        switch self {
        case .ok: return "icon-status-ok"
        case .replaced: return "icon-status-replaced"
        case .needsAttention: return "icon-status-attention"
        }
    }
}

// MARK: - Sizing helper

extension Image {
    /// Renders a template icon at a fixed point size (the custom SVG assets
    /// don't respond to `.font`/`.imageScale` the way SF Symbols do).
    func iconSized(_ side: CGFloat) -> some View {
        resizable()
            .scaledToFit()
            .frame(width: side, height: side)
    }
}
