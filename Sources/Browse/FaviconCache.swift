import AppKit
import Combine
import ImageIO

// @lat: [[lat.md/architecture/favicons#Persistent favicon cache]]
@MainActor
final class FaviconCache: ObservableObject {
    private struct Entry: Codable {
        var png: Data
        var updated: Date
    }
    private struct Snapshot: Codable {
        var version = 1
        var entries: [String: Entry]
    }
    private let file: URL
    private let limit: Int
    private var entries: [String: Entry] = [:]
    private var images: [String: NSImage] = [:]
    private var pendingSave: Task<Void, Never>?
    private var dirty = false

    init(file: URL, limit: Int = 256) {
        self.file = file
        self.limit = max(1, limit)
        // The cache is disposable. Ignore corrupt or oversized snapshots.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 12 * 1024 * 1024,
           let data = try? Data(contentsOf: file),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 {
            entries = snapshot.entries.filter { key, entry in
                Self.origin(URL(string: key)) == key && Self.validPNG(entry.png)
            }
            trim()
        }
    }

    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, host.utf8.count <= 2048 else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port ?? (scheme == "https" ? 443 : 80)
        return components.string
    }

    func image(for url: URL?) -> NSImage? {
        guard let key = Self.origin(url), let entry = entries[key] else { return nil }
        if let image = images[key] { return image }
        let image = NSImage(data: entry.png)
        images[key] = image
        return image
    }

    func record(_ image: NSImage, for url: URL) {
        guard let key = Self.origin(url), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        let scale = min(64 / image.size.width, 64 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]),
              Self.validPNG(png) else { return }
        objectWillChange.send()
        entries[key] = Entry(png: png, updated: Date())
        images[key] = NSImage(data: png)
        trim()
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Snapshot(entries: entries)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false
        } catch { /* A failed cache write must not prevent browsing or session saves. */ }
    }

    func clear() {
        objectWillChange.send()
        entries.removeAll(); images.removeAll()
        dirty = true
        flush()
    }

    private func trim() {
        let oldest = entries.sorted {
            $0.value.updated == $1.value.updated ? $0.key < $1.key : $0.value.updated < $1.value.updated
        }
        for (key, _) in oldest.prefix(max(0, entries.count - limit)) {
            entries.removeValue(forKey: key)
            images.removeValue(forKey: key)
        }
    }

    private static func validPNG(_ data: Data) -> Bool {
        guard data.count <= 32 * 1024, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 64 && height <= 64
    }
}
