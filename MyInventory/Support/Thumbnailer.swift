//
//  Thumbnailer.swift
//  MyInventory
//
//  ImageIO-based downsampling with an in-memory cache. List rows display photos
//  at ~48 pt; decoding the full stored image (≤1024 px) for every row on every
//  render churns CPU/memory while scrolling. This decodes a small thumbnail
//  directly from the encoded data (never inflating the full bitmap) and caches it.
//

import UIKit
import ImageIO

enum Thumbnailer {

    private static let cache = NSCache<NSString, UIImage>()

    /// Returns a downsampled thumbnail for `data`, cached under `cacheKey`.
    /// `maxPixel` is the longest side in pixels (144 ≈ 48 pt @3x).
    static func thumbnail(for data: Data, cacheKey: String, maxPixel: CGFloat = 144) -> UIImage? {
        let key = "\(cacheKey)-\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }

        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }
}
