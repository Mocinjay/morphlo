// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Foundation

/// Fonts: between desktop fonts (.ttf, .otf, and .ttc/.otc collections) and web fonts (WOFF, WOFF2).
///
/// These are all the same font tables in different wrappers, so converting is lossless and needs
/// no external tool. What it doesn't do is turn TrueType outlines into CFF ones or back: a font
/// that comes out of a web font is a .ttf or an .otf depending on which it was made from.
enum FontConv {
    /// The fonts a file holds, whatever its name says: one, or several for a collection.
    static func read(_ bytes: [UInt8]) throws -> [SFNT] {
        guard bytes.count >= 4 else { throw FontError.notAFont }
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        switch magic {
        case WOFF.signature: return [try WOFF.decode(bytes)]
        case WOFF2.signature: return [try WOFF2.decode(bytes)]
        default: return try SFNT.fonts(in: bytes)
        }
    }

    /// One font in the target's format, and the extension that goes with it.
    static func write(_ font: SFNT, as t: Target, runner: Runner) async throws -> (bytes: [UInt8], ext: String) {
        switch t.id {
        case "font-woff2":
            let prepared = WOFF2.prepare(font)
            return (
                WOFF2.assemble(prepared, compressed: try await Brotli.best(prepared.stream, runner: runner)), "woff2"
            )
        case "font-woff": return (WOFF.encode(font), "woff")
        default: return (font.data(), font.fileExtension)
        }
    }

    /// Converts a font file. A collection becomes a folder with one file per font, named after the fonts.
    /// A font already in the target format is written again (recompressed, or a clean copy), like
    /// every other kind of file.
    static func convert(_ input: URL, _ t: Target, runner: Runner) async throws -> [URL] {
        try runner.checkCancelled()
        guard let data = try? Data(contentsOf: input) else { throw FormatError("Couldn't open this font") }
        let fonts = try read([UInt8](data))

        var written: [(bytes: [UInt8], ext: String)] = []
        for font in fonts {
            try runner.checkCancelled()
            written.append(try await write(font, as: t, runner: runner))
        }
        try runner.checkCancelled()

        guard fonts.count > 1 else {
            let out = try uniqueOutput(for: input, ext: written[0].ext)
            try Data(written[0].bytes).write(to: out, options: .atomic)
            return [out]
        }
        let folder = try uniqueFolder(for: input, suffix: " fonts")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var used = Set<String>()
            for (i, font) in fonts.enumerated() {
                let base = fileName(font.name) ?? "\(input.deletingPathExtension().lastPathComponent) \(i + 1)"
                // Two fonts can share a name (or one can be called what another was renamed to).
                var name = base
                var n = 2
                while !used.insert(name.lowercased()).inserted {
                    name = "\(base) \(n)"
                    n += 1
                }
                let out = folder.appendingPathComponent(name).appendingPathExtension(written[i].ext)
                try Data(written[i].bytes).write(to: out, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return [folder]
    }

    /// A font's name as a file name: nothing a file name can't have, nil when nothing is left.
    static func fileName(_ name: String?) -> String? {
        guard let name else { return nil }
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let safe = name.components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return safe.isEmpty ? nil : String(safe.prefix(100))
    }
}
