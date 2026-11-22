// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Foundation

/// Looks at a file's first bytes to tell what it really is, for when the name can't be trusted:
/// `.ts` is both TypeScript and MPEG transport stream, and files get renamed to the wrong extension.
///
/// It only speaks up when it's sure. Anything it doesn't recognise is left to the converters, as before.
enum Sniff {
    struct Format: Equatable {
        /// Reads after "its contents are …": "WAV audio", "a JPEG image".
        let name: String
        /// The extension such a file usually has, when there's an obvious one to suggest.
        let ext: String?
        /// The kinds of file this can be converted as. MP4, for one, can hold just audio.
        let kinds: Set<MediaKind>
    }

    static let headerLength = 4096

    /// The first bytes of a file, or nil if it can't be read (missing, a folder, no permission).
    static func header(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headerLength)
    }

    // MARK: Checks

    /// Throws when the contents clearly belong to a different kind of file than the name says,
    /// e.g. audio renamed to `.jpg`, so the user gets told that instead of a vague decode error.
    static func verify(_ url: URL, as kind: MediaKind) throws {
        guard let head = header(of: url), let actual = format(head), !actual.kinds.contains(kind) else { return }
        // Text may start with anything, including another format's magic letters.
        if kind == .document, looksLikeText(head) { return }
        var message = "This isn't really a .\(url.pathExtension.lowercased()) file: its contents are \(actual.name)."
        if let ext = actual.ext { message += " Rename it to .\(ext) and convert it again." }
        throw FormatError(message)
    }

    /// MPEG transport stream: a sync byte (0x47) at the start of every packet.
    /// Packets are 188 bytes; M2TS adds a 4-byte prefix (192), some broadcasts 16 bytes of error correction (204).
    static func isTransportStream(_ d: Data) -> Bool {
        let b = [UInt8](d)
        for (first, size) in [(0, 188), (4, 192), (0, 204)] {
            let syncs = Array(stride(from: first, to: b.count, by: size).prefix(4))
            if syncs.count >= 2, syncs.allSatisfy({ b[$0] == 0x47 }) { return true }
        }
        return false
    }

    /// Text has no control bytes apart from whitespace (and escape, for coloured logs). UTF-16 is told by its mark.
    static func looksLikeText(_ d: Data) -> Bool {
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return true }
        return !d.contains { $0 < 0x09 || (0x0E...0x1A).contains($0) || (0x1C...0x1F).contains($0) }
    }

    // MARK: Formats

    /// The format these first bytes belong to, or nil when they aren't one of the well-known ones below.
    static func format(_ d: Data) -> Format? {
        let b = [UInt8](d.prefix(64))
        func at(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        func at(_ offset: Int, _ text: String) -> Bool { at(offset, Array(text.utf8)) }
        let av: Set<MediaKind> = [.audio, .video]

        // Images
        if at(0, [0xFF, 0xD8, 0xFF]) { return Format(name: "a JPEG image", ext: "jpg", kinds: [.image]) }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Format(name: "a PNG image", ext: "png", kinds: [.image])
        }
        if at(0, "GIF87a") || at(0, "GIF89a") { return Format(name: "a GIF image", ext: "gif", kinds: [.image]) }
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A]) {
            return Format(name: "a TIFF image", ext: "tiff", kinds: [.image])  // also most camera raw files
        }
        if at(0, "BM"), b.count >= 18, b[6...9].allSatisfy({ $0 == 0 }), [12, 40, 52, 56, 108, 124].contains(b[14]),
            b[15...17].allSatisfy({ $0 == 0 })
        {
            return Format(name: "a BMP image", ext: "bmp", kinds: [.image])
        }

        // RIFF and IFF containers
        if at(0, "RIFF") || at(0, "RF64") {
            if at(8, "WAVE") { return Format(name: "WAV audio", ext: "wav", kinds: [.audio]) }
            if at(8, "AVI ") { return Format(name: "an AVI video", ext: "avi", kinds: [.video]) }
            if at(8, "WEBP") { return Format(name: "a WebP image", ext: "webp", kinds: [.image]) }
        }
        if at(0, "FORM"), at(8, "AIFF") || at(8, "AIFC") {
            return Format(name: "AIFF audio", ext: "aiff", kinds: [.audio])
        }

        // MP4 family: the brand says what's inside. Unknown brands (camera raw, …) are left alone.
        if at(4, "ftyp"), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            let imageBrands = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"]
            if imageBrands.contains(brand) { return Format(name: "a HEIC image", ext: "heic", kinds: [.image]) }
            if brand == "avif" || brand == "avis" {
                return Format(name: "an AVIF image", ext: "avif", kinds: [.image])
            }
            if brand == "qt  " { return Format(name: "a QuickTime movie", ext: "mov", kinds: av) }
            if brand.hasPrefix("M4A") || brand.hasPrefix("M4B") {
                return Format(name: "M4A audio", ext: "m4a", kinds: av)
            }
            let movieBrands = ["isom", "mp41", "mp42", "avc1", "M4V ", "f4v ", "dash", "mmp4", "MSNV", "av01"]
            if movieBrands.contains(brand) || ["iso", "3gp", "3g2"].contains(where: brand.hasPrefix) {
                return Format(name: "an MP4 video", ext: "mp4", kinds: av)
            }
            return nil
        }
        if at(4, "moov") || at(4, "mdat") || at(4, "wide") {
            return Format(name: "a QuickTime movie", ext: "mov", kinds: av)
        }

        // Audio
        if at(0, "fLaC") { return Format(name: "FLAC audio", ext: "flac", kinds: [.audio]) }
        if at(0, "ID3"), b.count >= 4, (2...4).contains(b[3]) {
            return Format(name: "MP3 audio", ext: "mp3", kinds: [.audio])
        }
        if at(0, "wvpk") { return Format(name: "WavPack audio", ext: "wv", kinds: [.audio]) }
        // An MPEG audio frame (MP3, or AAC in ADTS): 11 sync bits, then a valid bitrate and sample rate.
        if b.count >= 3, b[0] == 0xFF, b[1] & 0xE0 == 0xE0, b[1] < 0xFE, b[2] & 0xF0 != 0xF0, b[2] & 0x0C != 0x0C {
            return Format(name: "MPEG audio (MP3 or AAC)", ext: nil, kinds: [.audio])
        }

        // Audio or video
        if at(0, "OggS") { return Format(name: "an Ogg file", ext: "ogg", kinds: av) }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) { return Format(name: "a Matroska or WebM file", ext: "mkv", kinds: av) }
        if at(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return Format(name: "a Windows Media file", ext: "wmv", kinds: av)
        }
        if at(0, [0x46, 0x4C, 0x56, 0x01]) { return Format(name: "a Flash video", ext: "flv", kinds: [.video]) }
        if at(0, [0x00, 0x00, 0x01, 0xBA]) || at(0, [0x00, 0x00, 0x01, 0xB3]) {
            return Format(name: "an MPEG video", ext: "mpg", kinds: [.video])
        }
        if isTransportStream(d) { return Format(name: "an MPEG transport stream", ext: "ts", kinds: [.video]) }

        // Fonts. A plain TrueType file starts with a version number, so its table count has to add up too.
        if at(0, "wOF2") { return Format(name: "a WOFF2 font", ext: "woff2", kinds: [.font]) }
        if at(0, "wOFF") { return Format(name: "a WOFF font", ext: "woff", kinds: [.font]) }
        if at(0, "OTTO") { return Format(name: "an OpenType font", ext: "otf", kinds: [.font]) }
        if at(0, "ttcf") { return Format(name: "a font collection", ext: "ttc", kinds: [.font]) }
        if at(0, [0x00, 0x01, 0x00, 0x00]) || at(0, "true"), b.count >= 12 {
            let tables = Int(b[4]) << 8 | Int(b[5])
            let searchRange = Int(b[6]) << 8 | Int(b[7])
            if tables > 0, tables < 256, searchRange == 16 << (Int.bitWidth - 1 - tables.leadingZeroBitCount) {
                return Format(name: "a TrueType font", ext: "ttf", kinds: [.font])
            }
        }

        // Documents. A PDF can also be behind an image type (Illustrator files), so it passes for both.
        if at(0, "%PDF-") { return Format(name: "a PDF", ext: "pdf", kinds: [.pdf, .image]) }
        if at(0, "{\\rtf") { return Format(name: "a Rich Text document", ext: "rtf", kinds: [.document]) }
        if at(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return Format(name: "an old Microsoft Office document", ext: nil, kinds: [.document, .image])
        }
        if at(0, [0x50, 0x4B, 0x03, 0x04]) {
            return Format(name: "a ZIP archive or Office document", ext: nil, kinds: [.document])
        }
        if at(0, "bplist00") { return Format(name: "a property list or web archive", ext: nil, kinds: [.document]) }
        return nil
    }
}
