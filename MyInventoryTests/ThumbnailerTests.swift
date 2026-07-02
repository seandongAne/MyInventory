//
//  ThumbnailerTests.swift
//  MyInventoryTests
//
//  `contentFingerprint` keys the in-memory thumbnail cache (ItemCard). Byte count
//  alone was the pre-fix key — replacing a photo with a same-length image kept
//  serving the stale thumbnail. The fingerprint samples head/middle/tail, so any
//  realistic re-encode of the same length must produce a new key.
//

import XCTest
@testable import MyInventory

final class ThumbnailerTests: XCTestCase {

    func testFingerprintStableForEqualData() {
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        XCTAssertEqual(Thumbnailer.contentFingerprint(data),
                       Thumbnailer.contentFingerprint(Data(data)))
    }

    func testFingerprintChangesForSameLengthDifferentContent() {
        let base = Data((0..<1000).map { UInt8($0 % 251) })
        for flipIndex in [0, 500, 999] {   // one byte inside each sampled region
            var mutated = base
            mutated[flipIndex] ^= 0xFF
            XCTAssertEqual(mutated.count, base.count)
            XCTAssertNotEqual(Thumbnailer.contentFingerprint(mutated),
                              Thumbnailer.contentFingerprint(base),
                              "flip at \(flipIndex) must change the cache key")
        }
    }

    func testFingerprintHandlesTinyData() {
        XCTAssertEqual(Thumbnailer.contentFingerprint(Data()),
                       Thumbnailer.contentFingerprint(Data()))
        XCTAssertNotEqual(Thumbnailer.contentFingerprint(Data([1])),
                          Thumbnailer.contentFingerprint(Data([2])))
    }
}
