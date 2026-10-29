import UIKit
import ImageIO

/// Tile threads only consult memory. The main actor schedules disk/network work,
/// then invalidates the tile view; drawing never waits for a download.
enum ImageCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    @MainActor private static var loading: [String: Task<UIImage?, Never>] = [:]
    private static let dir = URL.cachesDirectory.appending(path: "placed-images", directoryHint: .isDirectory)

    static func cached(_ file: String) -> UIImage? { memory.object(forKey: file as NSString) }

    @MainActor static func load(_ file: String) async -> UIImage? {
        guard file.range(of: "^[a-f0-9]{64}\\.(png|jpg)$", options: .regularExpression) != nil else { return nil }
        if let image = cached(file) { return image }
        if let task = loading[file] { return await task.value }
        let task = Task<UIImage?, Never> {
            let url = dir.appending(path: file)
            var data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            if data == nil, let api = API.current {
                data = try? await api.image(file: file)
                if let bytes = data {
                    await Task.detached(priority: .utility) {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? bytes.write(to: url, options: .atomic)
                        trimDisk()
                    }.value
                }
            }
            guard let data, let image = await Task.detached(priority: .utility, operation: {
                // Decode once, before CATiledLayer asks for the image on several threads.
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: cg)
            }).value else { return nil }
            memory.setObject(image, forKey: file as NSString, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
        loading[file] = task
        let image = await task.value
        loading[file] = nil
        return image
    }

    /// Content-addressed server resources are immutable; this is only a bounded device cache.
    private static func trimDisk() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let info = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > 80 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: url)
            size -= bytes
        }
    }

    static func draw(_ item: ClaudeItem, in ctx: CGContext) {
        guard let file = item.file, let image = cached(file)?.cgImage,
              let x = item.x, let y = item.y, let w = item.w, let h = item.h else { return }
        let box = CGRect(x: x, y: y, width: w, height: h)
        var target = box
        if item.fit != "stretch" {
            let sx = w / Double(image.width), sy = h / Double(image.height)
            let scale = item.fit == "cover" ? max(sx, sy) : min(sx, sy)
            let iw = Double(image.width) * scale, ih = Double(image.height) * scale
            target = CGRect(x: x + (w - iw) / 2, y: y + (h - ih) / 2, width: iw, height: ih)
        }
        ctx.saveGState()
        ctx.clip(to: box)
        ctx.setAlpha(item.opacity ?? 1)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: target.size))
        ctx.restoreGState()
    }
}
