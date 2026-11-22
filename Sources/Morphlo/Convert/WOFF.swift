// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Foundation
import zlib

/// WOFF 1.0: a font's tables, each compressed on its own with zlib. Every browser reads it.
enum WOFF {
    static let signature = FontTag("wOFF").value
    /// No font comes near this; a file that claims more is damaged (or built to use up memory).
    static let maxFontSize = 1 << 30

    /// The font inside a .woff file. Its metadata and private data blocks, if any, have no place
    /// in a .ttf or .otf and are left behind.
    static func decode(_ bytes: [UInt8]) throws -> SFNT {
        var r = try ByteReader(bytes)
        guard try r.u32() == Int(signature) else { throw FontError.notAFont }
        let flavor = UInt32(try r.u32())
        guard SFNT.flavors.contains(flavor) else { throw FontError.damaged }
        try r.skip(4)  // length
        let count = try r.u16()
        guard count > 0, count <= SFNT.maxTables else { throw FontError.damaged }
        try r.skip(30)  // reserved, totalSfntSize, version, metadata and private data
        var found: [(offset: Int, stored: Int, table: SFNT.Table)] = []
        var seen = Set<FontTag>()
        var total = 0
        for _ in 0..<count {
            let tag = FontTag(UInt32(try r.u32()))
            let offset = try r.u32()
            let stored = try r.u32()
            let length = try r.u32()
            try r.skip(4)  // checksum: recomputed when the font is written
            total += length
            // zlib can't shrink anything more than about 1032 times, so a table claiming more is
            // damaged, and isn't given the memory it asks for.
            guard stored <= length, length <= stored * 1100 + 1024, total <= maxFontSize, seen.insert(tag).inserted
            else { throw FontError.damaged }
            var block = try ByteReader(bytes, from: offset, count: stored)
            let data = try block.take(stored)
            // A table that compression didn't make smaller is stored as it is.
            let table = SFNT.Table(tag: tag, data: stored == length ? Array(data) : try inflate(data, to: length))
            found.append((offset, stored, table))
        }
        let tables = found.enumerated().sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
            .map(\.element)
        // Tables never share data; one block unpacked over and over would be a way to use up memory.
        var end = 0
        for t in tables where t.stored > 0 {
            guard t.offset >= end else { throw FontError.damaged }
            end = t.offset + t.stored
        }
        return SFNT(flavor: flavor, tables: tables.map(\.table))
    }

    /// The font as a .woff file. Tables keep their order, so unwrapping it gives back the same font.
    static func encode(_ font: SFNT) -> [UInt8] {
        let count = font.tables.count
        var blocks: [[UInt8]] = []
        var records: [(tag: FontTag, offset: Int, stored: Int, length: Int, checksum: UInt32)] = []
        var offset = 44 + 20 * count
        var sfntSize = 12 + 16 * count
        for table in font.tables {
            // Stored as the font has it; only the checksum leaves out the whole-file checksum in `head`.
            let data = table.data
            let block = deflate(data).flatMap { $0.count < data.count ? $0 : nil } ?? data
            records.append((table.tag, offset, block.count, data.count, SFNT.checksum(SFNT.stored(table))))
            blocks.append(block)
            offset += (block.count + 3) & ~3
            sfntSize += (data.count + 3) & ~3
        }
        // The WOFF version is the font's own revision number, as other tools write it.
        let revision = font["head"].flatMap { $0.count >= 8 ? Array($0[4..<8]) : nil } ?? [0, 0, 0, 0]

        var out: [UInt8] = []
        out.put32(Int(signature))
        out.put32(Int(font.flavor))
        out.put32(offset)
        out.put16(count)
        out.put16(0)
        out.put32(sfntSize)
        out.append(contentsOf: revision)
        for _ in 0..<5 { out.put32(0) }  // no metadata, no private data
        for r in records.sorted(by: { $0.tag < $1.tag }) {
            out.put32(Int(r.tag.value))
            out.put32(r.offset)
            out.put32(r.stored)
            out.put32(r.length)
            out.put32(Int(r.checksum))
        }
        for block in blocks {
            out.append(contentsOf: block)
            out.pad4()
        }
        return out
    }

    // MARK: zlib

    static func deflate(_ data: [UInt8]) -> [UInt8]? {
        var length = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        guard compress2(&out, &length, data, uLong(data.count), Z_BEST_COMPRESSION) == Z_OK else { return nil }
        out.removeLast(out.count - Int(length))
        return out
    }

    static func inflate(_ data: ArraySlice<UInt8>, to size: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        var length = uLong(size)
        let status = data.withUnsafeBufferPointer { uncompress(&out, &length, $0.baseAddress, uLong($0.count)) }
        guard status == Z_OK, Int(length) == size else { throw FontError.damaged }
        return out
    }
}
