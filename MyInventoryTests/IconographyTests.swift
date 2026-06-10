//
//  IconographyTests.swift
//  MyInventoryTests
//
//  Pure lookup tests for the custom icon mappings: context icons, the
//  name → default-item-icon keyword table (incl. ordering traps), status
//  and check-result icons.
//

import XCTest
@testable import MyInventory

final class IconographyTests: XCTestCase {

    // MARK: Context icons

    func testSeededContextsGetDedicatedIcons() {
        XCTAssertEqual(Iconography.contextIconName(forContextNamed: "Vehicle"), "icon-context-vehicle")
        XCTAssertEqual(Iconography.contextIconName(forContextNamed: "Bag"), "icon-context-bag")
        XCTAssertEqual(Iconography.contextIconName(forContextNamed: "House"), "icon-context-house")
    }

    func testUnknownContextFallsBackToCrate() {
        XCTAssertEqual(Iconography.contextIconName(forContextNamed: "Office"), "icon-context-generic")
    }

    // MARK: Default item icons — basic matching, English and Chinese

    func testEnglishKeywordMatching() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "First Aid Kit"), "icon-item-first-aid")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Canned Tuna"), "icon-item-food")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "AA Batteries"), "icon-item-battery")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Water Bottle"), "icon-item-water")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Jumper Cables"), "icon-item-tool")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Emergency Blanket"), "icon-item-sleeping")
    }

    func testChineseKeywordMatching() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "急救包"), "icon-item-first-aid")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "矿泉水"), "icon-item-water")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "充电宝"), "icon-item-power")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "对讲机"), "icon-item-radio")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "压缩干粮"), "icon-item-food")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "FLASHLIGHT"), "icon-item-flashlight")
    }

    func testUnknownNameFallsBackToGenericBox() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Mystery Thing"), "icon-item-generic")
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: ""), "icon-item-generic")
    }

    // MARK: Default item icons — table-ordering traps

    /// "Candle" contains "can" (food); the lantern entry must win.
    func testCandleBeatsCannedFood() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Candle"), "icon-item-lantern")
    }

    /// "Waterproof Matches" contains "water"; the flame entry must win.
    func testWaterproofMatchesBeatsWater() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Waterproof Matches"), "icon-item-flame")
    }

    /// "面罩" contains "面" (food keyword); the mask entry must win.
    func testFaceMaskBeatsNoodleFood() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "防尘面罩"), "icon-item-mask")
    }

    /// "充电宝" must not fall through to battery via "电".
    func testPowerBankBeatsBattery() {
        XCTAssertEqual(Iconography.itemIconName(forItemNamed: "Power Bank Charger"), "icon-item-power")
    }

    // MARK: Status + check-result icons

    func testEveryStatusHasACustomIcon() {
        let statuses: [SupplyStatus] = [.overdue, .dueSoon, .needsAttention, .ok, .neverChecked, .neverExpires]
        let expected = ["icon-status-overdue", "icon-status-due-soon", "icon-status-attention",
                        "icon-status-ok", "icon-status-never-checked", "icon-status-no-expiry"]
        XCTAssertEqual(statuses.map { $0.style.iconName }, expected)
    }

    func testEveryCheckResultHasACustomIcon() {
        XCTAssertEqual(CheckResult.ok.iconName, "icon-status-ok")
        XCTAssertEqual(CheckResult.replaced.iconName, "icon-status-replaced")
        XCTAssertEqual(CheckResult.needsAttention.iconName, "icon-status-attention")
    }
}
