// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Foundation

/// Reads the big-endian numbers font files are made of. Reading past the end throws instead of
/// crashing, so a damaged or cut-off font becomes an error message.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var pos: Int
    let end: Int

    /// Reads `count` bytes of `bytes` starting at `from` (everything after `from` when nil).
    init(_ bytes: [UInt8], from: Int = 0, count: Int? = nil) throws {
        let end = from + (count ?? bytes.count - from)
        guard from >= 0, end >= from, end <= bytes.count else { throw FontError.damaged }
        self.bytes = bytes
        self.pos = from
        self.end = end
    }

    var remaining: Int { end - pos }

    mutating func u8() throws -> Int {
        guard pos < end else { throw FontError.damaged }
        defer { pos += 1 }
        return Int(bytes[pos])
    }

    mutating func u16() throws -> Int {
        guard pos + 2 <= end else { throw FontError.damaged }
        defer { pos += 2 }
        return Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
    }

    mutating func i16() throws -> Int { Int(Int16(truncatingIfNeeded: try u16())) }

    mutating func u32() throws -> Int {
        guard pos + 4 <= end else { throw FontError.damaged }
        defer { pos += 4 }
        return Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, pos + count <= end else { throw FontError.damaged }
        defer { pos += count }
        return bytes[pos..<pos + count]
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }
}

extension [UInt8] {
    mutating func put16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func put32(_ value: Int) {
        put16(value >> 16)
        put16(value)
    }

    /// Font tables start on 4-byte boundaries; the gap is filled with zeros.
    mutating func pad4() {
        while count % 4 != 0 { append(0) }
    }
}

enum FontError {
    static let damaged = FormatError("This font file is damaged or incomplete")
    static let notAFont = FormatError("This isn't a TrueType, OpenType, WOFF or WOFF2 font")
}

/// A four-letter table name, such as `glyf` or `head`.
struct FontTag: Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    let value: UInt32

    init(_ value: UInt32) { self.value = value }

    init(stringLiteral text: String) {
        let b = Array(text.utf8)
        precondition(b.count == 4, "a font tag has four letters")
        value = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    static func < (a: FontTag, b: FontTag) -> Bool { a.value < b.value }

    var description: String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
    }
}

/// A TrueType or OpenType font as a list of tables: the format inside .ttf and .otf files, and what
/// WOFF and WOFF2 wrap. Convert moves tables between these containers; it never redraws a glyph.
struct SFNT {
    struct Table {
        let tag: FontTag
        var data: [UInt8]
    }

    /// The first four bytes: 0x00010000 or `true` for TrueType outlines, `OTTO` for CFF outlines.
    var flavor: UInt32
    /// In the order their data is stored in the file (the directory is sorted by name when written).
    var tables: [Table]

    static let trueType: UInt32 = 0x0001_0000
    static let appleTrueType = FontTag("true").value
    static let openType = FontTag("OTTO").value
    static let collection = FontTag("ttcf").value
    /// The kinds of single font there are. A web font claiming anything else can't become a .ttf or .otf.
    static let flavors = [trueType, appleTrueType, openType]
    /// Nothing sensible has more tables; a larger count means the file isn't a font.
    static let maxTables = 1024

    subscript(tag: FontTag) -> [UInt8]? { tables.first { $0.tag == tag }?.data }

    /// CFF outlines are what .otf files hold; fonts with TrueType outlines are .ttf.
    var fileExtension: String { self["CFF "] != nil || self["CFF2"] != nil ? "otf" : "ttf" }

    // MARK: Reading

    /// The fonts in a .ttf or .otf file (one), or in a .ttc or .otc collection (several).
    static func fonts(in bytes: [UInt8]) throws -> [SFNT] {
        var r = try ByteReader(bytes)
        guard r.remaining >= 12 else { throw FontError.notAFont }
        guard try r.u32() == Int(collection) else { return [try SFNT(bytes, at: 0)] }
        try r.skip(4)  // version
        let count = try r.u32()
        guard count > 0, count <= 4096 else { throw FontError.damaged }
        // The fonts in a collection share tables, and each gets its own copy. Real collections come
        // to under ten times the file; a small file listing the same tables thousands of times would
        // otherwise use up all memory.
        var fonts: [SFNT] = []
        var total = 0
        for _ in 0..<count {
            let font = try SFNT(bytes, at: try r.u32())
            total += font.tables.reduce(0) { $0 + $1.data.count }
            guard total <= 32 * bytes.count else { throw FontError.damaged }
            fonts.append(font)
        }
        return fonts
    }

    init(flavor: UInt32, tables: [Table]) {
        self.flavor = flavor
        self.tables = tables
    }

    /// Reads the font whose table directory starts at `offset`.
    init(_ bytes: [UInt8], at offset: Int) throws {
        var r = try ByteReader(bytes, from: offset)
        let flavor = UInt32(try r.u32())
        guard SFNT.flavors.contains(flavor) else { throw FontError.notAFont }
        let count = try r.u16()
        guard count > 0, count <= SFNT.maxTables else { throw FontError.damaged }
        try r.skip(6)  // searchRange, entrySelector, rangeShift
        var found: [(offset: Int, table: Table)] = []
        var seen = Set<FontTag>()
        var total = 0
        for _ in 0..<count {
            let tag = FontTag(UInt32(try r.u32()))
            try r.skip(4)  // checksum: recomputed when the font is written
            let start = try r.u32()
            let length = try r.u32()
            // Tables don't overlap, so together they fit in the file (twice over, for the odd old
            // font whose tables share data); more is a directory built to make copies without end.
            total += length
            guard start + length <= bytes.count, total <= 2 * bytes.count, seen.insert(tag).inserted else {
                throw FontError.damaged
            }
            found.append((start, Table(tag: tag, data: Array(bytes[start..<start + length]))))
        }
        // Stable, so tables that share an offset (empty ones) keep their directory order.
        self.flavor = flavor
        self.tables = found.enumerated().sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
            .map(\.element.table)
    }

    // MARK: Writing

    /// The sum of a table's bytes as big-endian 32-bit numbers, the way fonts checksum their tables.
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        data.withUnsafeBufferPointer { p in
            var i = 0
            while i + 4 <= p.count {
                sum &+= UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
                i += 4
            }
            var last: UInt32 = 0
            for k in 0..<4 { last = last << 8 | (i + k < p.count ? UInt32(p[i + k]) : 0) }
            sum &+= last
        }
        return sum
    }

    /// A table as it's checksummed and stored: `head` has its whole-file checksum field cleared,
    /// since that one is filled in last.
    static func stored(_ table: Table) -> [UInt8] {
        var data = table.data
        if table.tag == "head", data.count >= 12 { data.replaceSubrange(8..<12, with: [0, 0, 0, 0]) }
        return data
    }

    /// The font as a .ttf or .otf file. A well-formed font read with `init(_:at:)` comes out
    /// byte for byte as it went in.
    func data() -> [UInt8] {
        let count = tables.count
        var power = 1
        var exponent = 0
        while power * 2 <= count {
            power *= 2
            exponent += 1
        }
        var out: [UInt8] = []
        out.put32(Int(flavor))
        out.put16(count)
        out.put16(power * 16)
        out.put16(exponent)
        out.put16(count * 16 - power * 16)

        var offset = 12 + 16 * count
        var headOffset: Int?
        var records: [(tag: FontTag, checksum: UInt32, offset: Int, length: Int)] = []
        let stored = tables.map(SFNT.stored)
        for (table, data) in zip(tables, stored) {
            if table.tag == "head", data.count >= 12 { headOffset = offset }
            records.append((table.tag, SFNT.checksum(data), offset, data.count))
            offset += (data.count + 3) & ~3
        }
        for r in records.sorted(by: { $0.tag < $1.tag }) {
            out.put32(Int(r.tag.value))
            out.put32(Int(r.checksum))
            out.put32(r.offset)
            out.put32(r.length)
        }
        for data in stored {
            out.append(contentsOf: data)
            out.pad4()
        }
        if let headOffset {
            let adjustment = Int(0xB1B0_AFBA &- SFNT.checksum(out))
            out.replaceSubrange(
                headOffset + 8..<headOffset + 12,
                with: (0..<4).map { UInt8(truncatingIfNeeded: adjustment >> (24 - 8 * $0)) })
        }
        return out
    }

    // MARK: Names

    /// The font's PostScript name ("Helvetica-Bold"), or its full name: what the fonts taken out of
    /// a collection are called. Nil when the font doesn't say.
    var name: String? { nameRecord(6) ?? nameRecord(4) }

    private func nameRecord(_ id: Int) -> String? {
        guard let table = self["name"], var r = try? ByteReader(table),
            (try? r.u16()) != nil, let count = try? r.u16(), let strings = try? r.u16()
        else { return nil }
        var best: (rank: Int, text: String)?
        for _ in 0..<count {
            guard let platform = try? r.u16(), let encoding = try? r.u16(), let language = try? r.u16(),
                let nameID = try? r.u16(), let length = try? r.u16(), let offset = try? r.u16()
            else { return best?.text }
            guard nameID == id, strings + offset + length <= table.count else { continue }
            let raw = table[strings + offset..<strings + offset + length]
            // Windows English first, then any Unicode name, then the old Mac Roman one.
            let rank: Int
            let text: String?
            switch (platform, encoding) {
            case (3, 1), (3, 10):
                rank = language == 0x409 ? 0 : 1
                text = String(bytes: raw, encoding: .utf16BigEndian)
            case (0, _):
                rank = 2
                text = String(bytes: raw, encoding: .utf16BigEndian)
            case (1, 0):
                rank = 3
                text = String(bytes: raw, encoding: .macOSRoman)
            default: continue
            }
            if let text, !text.isEmpty, best.map({ rank < $0.rank }) ?? true { best = (rank, text) }
        }
        return best?.text
    }
}
