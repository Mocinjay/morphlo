import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ConvertError: LocalizedError {
    case unreadable(String)
    case noVideoTrack
    case noFrames

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn't read \(name)"
        case .noVideoTrack: return "No video track"
        case .noFrames: return "Couldn't extract frames"
        }
    }
}

/// Turns any dropped file into files Claude can read.
enum Converter {
    static func convert(_ url: URL, outDir: URL) async throws -> [URL] {
        let type = url.contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) {
            return try await VideoConverter.convert(url, outDir: outDir)
        }
        if let type, type.conforms(to: .image) {
            return [try ImageConverter.convert(url, outDir: outDir)]
        }
        return [url] // PDFs, text, etc. pass straight through
    }

    static func needsWork(_ url: URL) -> Bool {
        guard let type = url.contentType else { return false }
        if type.conforms(to: .movie) { return true }
        if type.conforms(to: .image) { return ImageConverter.needsConversion(url) }
        return false
    }
}

// MARK: - Images

enum ImageConverter {
    /// Formats Claude reads natively.
    static let native: [UTType] = [.jpeg, .png, .gif, .webP]
    static let maxBytes = 10 * 1024 * 1024
    static let maxEdge = 8000

    static func isNative(_ type: UTType) -> Bool { native.contains { type.conforms(to: $0) } }

    static func needsConversion(_ url: URL, maxEdge edgeLimit: Int? = nil) -> Bool {
        guard let type = url.contentType, type.conforms(to: .image) else { return false }
        if !isNative(type) { return true }
        if isAnimated(url) { return false } // re-encoding would throw away the animation
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { return true }
        if let (w, h) = pixelSize(url), max(w, h) > min(maxEdge, edgeLimit ?? Settings.maxImageEdge) { return true }
        return false
    }

    static func isAnimated(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    static func hasAlpha(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Returns the original URL if Claude can already read it, otherwise a JPEG copy with
    /// orientation applied and metadata (including GPS) stripped.
    static func convert(_ url: URL, outDir: URL, maxEdge edgeLimit: Int? = nil) throws -> URL {
        guard needsConversion(url, maxEdge: edgeLimit) else { return url }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let longest = pixelSize(url).map { max($0.0, $0.1) } ?? Settings.maxImageEdge
        var edge = min(edgeLimit ?? Settings.maxImageEdge, longest, maxEdge)
        var quality = Settings.jpegQuality
        // Keep transparency: images with alpha become PNG instead of JPEG.
        let alpha = hasAlpha(src)
        let out = WorkDir.unique(in: outDir, base: url.baseName, ext: alpha ? "png" : "jpg")

        for _ in 0..<5 {
            guard let image = thumbnail(src, maxEdge: edge) else { throw ConvertError.unreadable(url.lastPathComponent) }
            let data = alpha ? try encode(image, type: .png, quality: 1) : try jpegData(image, quality: quality)
            if data.count <= maxBytes {
                try data.write(to: out)
                return out
            }
            edge = Int(Double(edge) * 0.8)
            quality = max(0.6, quality - 0.1)
        }
        throw ConvertError.unreadable(url.lastPathComponent)
    }

    static func thumbnail(_ src: CGImageSource, maxEdge: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        try encode(image, type: .jpeg, quality: quality)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ConvertError.unreadable("image")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.unreadable("image") }
        return data as Data
    }

    /// Converts raw image data of any format into JPEG data.
    static func jpegData(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let longest: Int = {
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
            else { return Settings.maxImageEdge }
            return max(w, h)
        }()
        guard let image = thumbnail(src, maxEdge: min(Settings.maxImageEdge, longest)) else { return nil }
        return try? jpegData(image, quality: Settings.jpegQuality)
    }
}

// MARK: - Video

enum VideoConverter {
    static func convert(_ url: URL, outDir: URL, transcribe: Bool = true) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConvertError.noVideoTrack }

        let output = Settings.videoOutput
        let count = Settings.frameCount
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let tolerance = CMTime(seconds: max(0.05, duration / Double(count * 4)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [(time: Double, image: CGImage)] = []
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        for i in 0..<count {
            let t = safeDuration * (Double(i) + 0.5) / Double(count)
            if let (image, actual) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                frames.append((actual.seconds.isFinite ? actual.seconds : t, image))
            }
            if safeDuration == 0 { break }
        }
        guard !frames.isEmpty else { throw ConvertError.noFrames }

        var results: [URL] = []
        let base = url.baseName
        if output != .frames, let sheet = ContactSheet.render(
            frames: frames, title: "\(url.lastPathComponent) · \(formatTime(duration)) · \(frames.count) frames")
        {
            let out = WorkDir.unique(in: outDir, base: "\(base) contact sheet", ext: "jpg")
            try sheet.write(to: out)
            results.append(out)
        }
        if output != .sheet {
            for (i, f) in frames.enumerated() {
                let out = WorkDir.unique(
                    in: outDir,
                    base: String(format: "%@ frame %02d (%@)", base, i + 1, formatTime(f.time, precise: duration < 20).replacingOccurrences(of: ":", with: "m") + "s"),
                    ext: "jpg")
                try ImageConverter.jpegData(f.image, quality: Settings.jpegQuality).write(to: out)
                results.append(out)
            }
        }
        if transcribe, let transcript = await Transcriber.transcribe(asset: asset, sourceName: url.lastPathComponent,
                                                         duration: duration, outDir: outDir) {
            results.append(transcript)
        }
        return results
    }
}

// MARK: - Contact sheet

enum ContactSheet {
    static func render(frames: [(time: Double, image: CGImage)], title: String) -> Data? {
        guard let first = frames.first?.image else { return nil }
        let n = frames.count
        // Short clips: show tenths so neighbouring frames don't share a label.
        let precise = (frames.last?.time ?? 0) < 20
        let aspect = Double(first.height) / Double(max(1, first.width))
        let cols = max(1, min(n, Int(ceil(sqrt(Double(n) / aspect)))))
        let rows = Int(ceil(Double(n) / Double(cols)))

        var width = 2400.0
        let pad = 12.0, header = 64.0
        func height(_ w: Double) -> Double {
            let tileW = (w - pad * Double(cols + 1)) / Double(cols)
            return header + pad * Double(rows + 1) + tileW * aspect * Double(rows)
        }
        // Keep the sheet's long edge around 3000px so Claude's downscaling doesn't crush the tiles.
        while height(width) > 3000 && width > 900 { width -= 100 }
        let tileW = (width - pad * Double(cols + 1)) / Double(cols)
        let tileH = tileW * aspect
        let sheetH = height(width)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(sheetH),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: sheetH).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        (title as NSString).draw(at: NSPoint(x: pad + 4, y: sheetH - header + 16), withAttributes: titleAttrs)

        let labelSize = min(40, max(18, tileW * 0.07))
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: labelSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        for (i, f) in frames.enumerated() {
            let r = i / cols, c = i % cols
            let x = pad + Double(c) * (tileW + pad)
            let y = sheetH - header - pad - Double(r + 1) * tileH - Double(r) * pad
            let rect = NSRect(x: x, y: y, width: tileW, height: tileH)
            ctx.cgContext.draw(f.image, in: rect)

            let label = "\(i + 1)  \(formatTime(f.time, precise: precise))" as NSString
            let size = label.size(withAttributes: labelAttrs)
            let bg = NSRect(x: x + 8, y: y + 8, width: size.width + 16, height: size.height + 6)
            NSColor(calibratedWhite: 0, alpha: 0.65).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
            label.draw(at: NSPoint(x: bg.minX + 8, y: bg.minY + 3), withAttributes: labelAttrs)
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
