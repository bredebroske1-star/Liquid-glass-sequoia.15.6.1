import AppKit
import SwiftUI

private enum GlassAppIconCache {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 96
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private static let lock = NSLock()

    static let placeholder = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "App")
        ?? NSImage(size: NSSize(width: 32, height: 32))

    static func imageData(for url: URL) -> Data? {
        let key = url.path as NSString
        lock.lock()
        defer { lock.unlock() }

        if let cachedData = cache.object(forKey: key) {
            return cachedData as Data
        }

        let appIcon = NSWorkspace.shared.icon(forFile: url.path)
        let result = makeWhiteMark(from: appIcon) ?? appIcon
        guard let data = result.tiffRepresentation else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    private static func makeWhiteMark(from image: NSImage) -> NSImage? {
        let pixelSize = 32
        guard let source = bitmap(size: pixelSize),
              let destination = bitmap(size: pixelSize),
              let sourceContext = NSGraphicsContext(bitmapImageRep: source)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = sourceContext
        sourceContext.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        sourceContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let sourceBytes = source.bitmapData, let destinationBytes = destination.bitmapData else {
            return nil
        }

        var backgroundLuminance: CGFloat = 0
        var backgroundSamples: CGFloat = 0
        for position in 4..<(pixelSize - 4) {
            for offset in [
                position * source.bytesPerRow + 4,
                position * source.bytesPerRow + (pixelSize - 2) * 4,
                4 + position * 4,
                (pixelSize - 2) * 4 + position * source.bytesPerRow
            ] {
                let alpha = CGFloat(sourceBytes[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                backgroundLuminance += luminance(
                    red: sourceBytes[offset],
                    green: sourceBytes[offset + 1],
                    blue: sourceBytes[offset + 2],
                    alpha: alpha
                )
                backgroundSamples += 1
            }
        }

        guard backgroundSamples > 0 else { return nil }
        backgroundLuminance /= backgroundSamples

        for y in 0..<pixelSize {
            let rowOffset = y * source.bytesPerRow
            for x in 0..<pixelSize {
                let offset = rowOffset + x * 4
                let alpha = CGFloat(sourceBytes[offset + 3]) / 255
                let contrast = abs(
                    luminance(
                        red: sourceBytes[offset],
                        green: sourceBytes[offset + 1],
                        blue: sourceBytes[offset + 2],
                        alpha: alpha
                    ) - backgroundLuminance
                )
                let amount = min(max((contrast - 0.08) / 0.34, 0), 1)
                let coverage = UInt8((amount * amount * (3 - 2 * amount) * alpha * 255).rounded())
                destinationBytes[offset] = coverage
                destinationBytes[offset + 1] = coverage
                destinationBytes[offset + 2] = coverage
                destinationBytes[offset + 3] = coverage
            }
        }

        let result = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        result.addRepresentation(destination)
        return result
    }

    private static func bitmap(size: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private static func luminance(red: UInt8, green: UInt8, blue: UInt8, alpha: CGFloat) -> CGFloat {
        guard alpha > 0 else { return 0 }
        let red = min(CGFloat(red) / 255 / alpha, 1)
        let green = min(CGFloat(green) / 255 / alpha, 1)
        let blue = min(CGFloat(blue) / 255 / alpha, 1)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

struct GlassAppIcon: View {
    let url: URL
    var size: CGFloat = 42
    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? GlassAppIconCache.placeholder)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(size * 0.28)
            .background {
                RoundedRectangle(cornerRadius: size * 0.44, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.44, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.17),
                                        .cyan.opacity(0.065),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.44, style: .continuous)
                            .stroke(.white.opacity(0.27), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.13), radius: 8, y: 4)
            .task(id: url) {
                let data = await Task.detached(priority: .utility) {
                    GlassAppIconCache.imageData(for: url)
                }.value
                if let data {
                    icon = NSImage(data: data)
                }
            }
    }
}
