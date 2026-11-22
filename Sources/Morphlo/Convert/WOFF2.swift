// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import Compression
import Foundation

/// WOFF2: a font's tables in one Brotli stream, with the glyph outlines repacked first so they
/// compress better. The smallest web font format; every current browser reads it.
///
/// Repacking is lossless for what a glyph is (its points, contours, instructions and bounding box)
/// but not for its bytes: a font unwrapped from WOFF2 draws the same and may differ byte for byte.
enum WOFF2 {
    static let signature = FontTag("wOF2").value

    /// Table names the format writes as one number instead of four letters. The order is the format's.
    static let knownTags: [FontTag] = [
        "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep",
        "CFF ", "VORG", "EBDT", "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE",
        "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt",
        "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar", "gvar", "hsty", "just", "lcar",
        "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
    ]

    // MARK: - Reading

    /// The font inside a .woff2 file.
    static func decode(_ bytes: [UInt8]) throws -> SFNT {
        var r = try ByteReader(bytes)
        guard try r.u32() == Int(signature) else { throw FontError.notAFont }
        let flavor = UInt32(try r.u32())
        guard flavor != SFNT.collection else {
            throw FormatError("WOFF2 files that hold several fonts aren't supported")
        }
        guard SFNT.flavors.contains(flavor) else { throw FontError.damaged }
        try r.skip(4)  // length
        let count = try r.u16()
        guard count > 0, count <= SFNT.maxTables else { throw FontError.damaged }
        try r.skip(6)  // reserved, totalSfntSize
        let compressedSize = try r.u32()
        try r.skip(24)  // version, metadata and private data

        struct Entry {
            let tag: FontTag
            let version: Int
            let transformed: Bool
            let length: Int
            let stored: Int
        }
        var entries: [Entry] = []
        var seen = Set<FontTag>()
        var total = 0
        for _ in 0..<count {
            let flags = try r.u8()
            let tag = flags & 0x3F == 0x3F ? FontTag(UInt32(try r.u32())) : knownTags[flags & 0x3F]
            let version = flags >> 6
            // Versions 1 and 2 of the glyph tables are reserved: data this code can't know how to read.
            guard !(tag == "glyf" || tag == "loca") || version == 0 || version == 3 else { throw FontError.damaged }
            let length = try base128(&r)
            // Glyph tables are repacked unless marked otherwise (3); every other table only when marked.
            let transformed = tag == "glyf" || tag == "loca" ? version == 0 : version != 0
            let stored = transformed ? try base128(&r) : length
            total += stored
            guard total <= WOFF.maxFontSize, length <= WOFF.maxFontSize, seen.insert(tag).inserted else {
                throw FontError.damaged
            }
            entries.append(Entry(tag: tag, version: version, transformed: transformed, length: length, stored: stored))
        }

        let stream = try Brotli.decode(try r.take(compressedSize), to: total)
        var stored: [FontTag: [UInt8]] = [:]
        var offset = 0
        for e in entries {
            stored[e.tag] = Array(stream[offset..<offset + e.stored])
            offset += e.stored
        }
        func isRepacked(_ tag: FontTag) -> Bool { entries.contains { $0.tag == tag && $0.transformed } }

        var glyphs: Glyphs?
        if isRepacked("glyf") {
            guard isRepacked("loca"), stored["loca"]?.isEmpty == true else { throw FontError.damaged }
            glyphs = try unpackGlyphs(stored["glyf"] ?? [])
            // The format requires the size `loca` is given to be the one the glyphs make.
            guard entries.first(where: { $0.tag == "loca" })?.length == glyphs?.loca.count else {
                throw FontError.damaged
            }
        } else if isRepacked("loca") {
            throw FontError.damaged
        }

        var tables: [SFNT.Table] = []
        for e in entries {
            var data = stored[e.tag] ?? []
            if e.transformed {
                switch e.tag {
                case "glyf": data = glyphs?.glyf ?? []
                case "loca": data = glyphs?.loca ?? []
                case "hmtx" where e.version == 1:
                    guard let hhea = stored["hhea"], hhea.count >= 36, let glyphs else { throw FontError.damaged }
                    data = try unpackMetrics(
                        data, widths: Int(hhea[34]) << 8 | Int(hhea[35]), leftEdges: glyphs.leftEdges)
                default: throw FontError.damaged  // a repacking newer than this code
                }
            }
            tables.append(SFNT.Table(tag: e.tag, data: data))
        }
        return SFNT(flavor: flavor, tables: tables)
    }

    // MARK: - Writing

    /// A font ready to be written as WOFF2, short of compressing `stream`: that step can take a
    /// while and may use an external tool, so the caller does it (see `Brotli`).
    struct Prepared {
        let flavor: UInt32
        let revision: [UInt8]
        let sfntSize: Int
        /// `stored` is the size in the stream, for repacked tables only.
        var entries: [(tag: FontTag, version: Int, length: Int, stored: Int?)] = []
        var stream: [UInt8] = []
    }

    static func prepare(_ font: SFNT) -> Prepared {
        // A digital signature can't survive repacking, so the format has it removed, and has the
        // font marked as having been through a lossless transform (bit 11 of the head flags).
        var tables = font.tables.filter { $0.tag != "DSIG" }.sorted { $0.tag < $1.tag }
        // The format wants `loca` straight after `glyf`, so decoders can rebuild it from the glyphs.
        if let loca = tables.firstIndex(where: { $0.tag == "loca" }),
            let glyf = tables.firstIndex(where: { $0.tag == "glyf" }), glyf < loca
        {
            tables.insert(tables.remove(at: loca), at: glyf + 1)
        }
        if let head = tables.firstIndex(where: { $0.tag == "head" }), tables[head].data.count >= 18 {
            tables[head].data[16] |= 0x08
        }
        var p = Prepared(
            flavor: font.flavor,
            revision: font["head"].flatMap { $0.count >= 8 ? Array($0[4..<8]) : nil } ?? [0, 0, 0, 0],
            sfntSize: tables.reduce(12 + 16 * tables.count) { $0 + (($1.data.count + 3) & ~3) })
        // Glyphs that can't be repacked safely (an unusual or damaged glyph table) go in as they are.
        let packed = try? packGlyphs(font)
        for table in tables {
            switch table.tag {
            case "glyf" where packed != nil:
                p.entries.append((table.tag, 0, table.data.count, packed?.count))
                p.stream += packed ?? []
            case "loca" where packed != nil:
                p.entries.append((table.tag, 0, table.data.count, 0))
            case "glyf", "loca":
                p.entries.append((table.tag, 3, table.data.count, nil))
                p.stream += table.data
            default:
                p.entries.append((table.tag, 0, table.data.count, nil))
                p.stream += table.data
            }
        }
        return p
    }

    /// The .woff2 file, given `p.stream` compressed with Brotli.
    static func assemble(_ p: Prepared, compressed: [UInt8]) -> [UInt8] {
        var directory: [UInt8] = []
        for e in p.entries {
            let known = knownTags.firstIndex(of: e.tag)
            directory.append(UInt8((known ?? 0x3F) | e.version << 6))
            if known == nil { directory.put32(Int(e.tag.value)) }
            putBase128(&directory, e.length)
            if let stored = e.stored { putBase128(&directory, stored) }
        }
        var out: [UInt8] = []
        out.put32(Int(signature))
        out.put32(Int(p.flavor))
        out.put32((48 + directory.count + compressed.count + 3) & ~3)
        out.put16(p.entries.count)
        out.put16(0)
        // Browsers reject a font that claims to unpack smaller than the file (possible for a tiny font).
        out.put32(max(p.sfntSize, (48 + directory.count + compressed.count + 3) & ~3))
        out.put32(compressed.count)
        out.append(contentsOf: p.revision)
        for _ in 0..<5 { out.put32(0) }  // no metadata, no private data
        out.append(contentsOf: directory)
        out.append(contentsOf: compressed)
        out.pad4()
        return out
    }

    // MARK: - Numbers of variable length

    /// A length in 1 to 5 bytes, seven bits each, the highest first.
    static func base128(_ r: inout ByteReader) throws -> Int {
        var value = 0
        for i in 0..<5 {
            let byte = try r.u8()
            // No leading zeros, and no more than 32 bits.
            guard !(i == 0 && byte == 0x80), value & 0xFE00_0000 == 0 else { throw FontError.damaged }
            value = value << 7 | (byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw FontError.damaged
    }

    static func putBase128(_ out: inout [UInt8], _ value: Int) {
        var shift = 28
        while shift > 0, value >> shift == 0 { shift -= 7 }
        while shift > 0 {
            out.append(UInt8(0x80 | (value >> shift) & 0x7F))
            shift -= 7
        }
        out.append(UInt8(value & 0x7F))
    }

    /// A 16-bit number in 1 to 3 bytes; small values, the common case, take one.
    static func short255(_ r: inout ByteReader) throws -> Int {
        let code = try r.u8()
        switch code {
        case 253: return try r.u16()
        case 254: return try r.u8() + 506
        case 255: return try r.u8() + 253
        default: return code
        }
    }

    static func putShort255(_ out: inout [UInt8], _ value: Int) {
        if value < 253 {
            out.append(UInt8(value))
        } else if value < 506 {
            out += [255, UInt8(value - 253)]
        } else if value < 762 {
            out += [254, UInt8(value - 506)]
        } else {
            out.append(253)
            out.put16(value)
        }
    }

    // MARK: - Glyphs

    /// The glyph tables as a .ttf holds them, plus each glyph's left edge (the metrics need it).
    struct Glyphs {
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        var leftEdges: [Int] = []
    }

    private static let onCurve = 0x01
    private static let xShort = 0x02
    private static let yShort = 0x04
    private static let repeats = 0x08
    private static let xSameOrPositive = 0x10
    private static let ySameOrPositive = 0x20
    private static let overlapSimple = 0x40
    /// Far more points than any real font has (the largest have a few million). Without a limit a
    /// small file could describe billions of points, through glyphs whose points take no bytes.
    static let maxPoints = 1 << 24

    /// How far a composite glyph's component record goes on after its flags and glyph number.
    private static func componentSize(_ flags: Int) -> Int {
        var size = flags & 0x0001 != 0 ? 4 : 2  // the two arguments, as words or bytes
        if flags & 0x0008 != 0 {  // one scale
            size += 2
        } else if flags & 0x0040 != 0 {  // x and y scale
            size += 4
        } else if flags & 0x0080 != 0 {  // 2×2 transform
            size += 8
        }
        return size
    }

    /// Repacks the `glyf` table the WOFF2 way: the same kind of data from all glyphs goes together
    /// (contour counts, point counts, point flags, coordinates, …), which Brotli compresses far
    /// better than glyph after glyph. `loca` isn't stored at all; it's rebuilt from the glyphs.
    ///
    /// Returns nil for a font without TrueType outlines. Throws when the glyph table can't be
    /// repacked with certainty: the result is unpacked again and must repack to the same bytes.
    static func packGlyphs(_ font: SFNT) throws -> [UInt8]? {
        guard let glyf = font["glyf"], let loca = font["loca"], let head = font["head"], let maxp = font["maxp"],
            head.count >= 54, maxp.count >= 6
        else { return nil }
        let longOffsets = Int(head[50]) << 8 | Int(head[51])
        let count = Int(maxp[4]) << 8 | Int(maxp[5])
        guard longOffsets <= 1, loca.count == (count + 1) * (longOffsets == 0 ? 2 : 4) else { throw FontError.damaged }
        let packed = try packGlyphs(glyf: glyf, loca: loca, count: count, longOffsets: longOffsets)
        let back = try unpackGlyphs(packed)
        guard back.loca.count == loca.count,
            try packGlyphs(glyf: back.glyf, loca: back.loca, count: count, longOffsets: longOffsets) == packed
        else { throw FontError.damaged }
        return packed
    }

    static func packGlyphs(glyf: [UInt8], loca: [UInt8], count: Int, longOffsets: Int) throws -> [UInt8] {
        var offsets = try ByteReader(loca)
        var end = longOffsets == 0 ? try offsets.u16() * 2 : try offsets.u32()

        var contourCounts: [UInt8] = []
        var pointCounts: [UInt8] = []
        var flags: [UInt8] = []
        var coordinates: [UInt8] = []
        var composites: [UInt8] = []
        var boxes: [UInt8] = []
        var instructions: [UInt8] = []
        var hasBox = [UInt8](repeating: 0, count: ((count + 31) >> 5) << 2)
        var overlaps = [UInt8](repeating: 0, count: (count + 7) >> 3)
        var anyOverlap = false
        var totalPoints = 0
        // Real glyphs take a few bytes a point. Ones that take next to none (repeated flags, no
        // steps) are only made to cost time; they can go in untransformed, which loses nothing.
        let pointLimit = min(maxPoints, 4 * glyf.count)

        for g in 0..<count {
            let start = end
            end = longOffsets == 0 ? try offsets.u16() * 2 : try offsets.u32()
            guard start <= end else { throw FontError.damaged }
            if start == end {
                contourCounts.put16(0)
                continue
            }
            var r = try ByteReader(glyf, from: start, count: end - start)
            let contours = try r.i16()
            let box = try r.take(8)
            if contours == 0 {
                contourCounts.put16(0)
                continue
            }

            if contours < 0 {
                // A composite: its component records go in as they are, the box is always kept.
                contourCounts.put16(-1)
                hasBox[g >> 3] |= 0x80 >> (g & 7)
                boxes += box
                let first = r.pos
                var hasInstructions = false
                while true {
                    let component = try r.u16()
                    try r.skip(2 + componentSize(component))
                    if component & 0x0100 != 0 { hasInstructions = true }
                    if component & 0x0020 == 0 { break }
                }
                composites += glyf[first..<r.pos]
                if hasInstructions {
                    let length = try r.u16()
                    putShort255(&coordinates, length)
                    instructions += try r.take(length)
                }
                continue
            }

            contourCounts.put16(contours)
            var last = -1
            for _ in 0..<contours {
                let endPoint = try r.u16()
                guard endPoint >= last else { throw FontError.damaged }
                putShort255(&pointCounts, endPoint - last)
                last = endPoint
            }
            let points = last + 1
            totalPoints += points
            guard totalPoints <= pointLimit else { throw FontError.damaged }
            let codeLength = try r.u16()
            let code = try r.take(codeLength)

            var pointFlags: [Int] = []
            pointFlags.reserveCapacity(points)
            while pointFlags.count < points {
                let flag = try r.u8()
                pointFlags.append(flag)
                if flag & repeats != 0 {
                    let times = try r.u8()
                    guard pointFlags.count + times <= points else { throw FontError.damaged }
                    for _ in 0..<times { pointFlags.append(flag) }
                }
            }
            var dx = [Int](repeating: 0, count: points)
            var dy = [Int](repeating: 0, count: points)
            for (i, flag) in pointFlags.enumerated() {
                if flag & xShort != 0 {
                    let byte = try r.u8()
                    dx[i] = flag & xSameOrPositive != 0 ? byte : -byte
                } else if flag & xSameOrPositive == 0 {
                    dx[i] = try r.i16()
                }
            }
            for (i, flag) in pointFlags.enumerated() {
                if flag & yShort != 0 {
                    let byte = try r.u8()
                    dy[i] = flag & ySameOrPositive != 0 ? byte : -byte
                } else if flag & ySameOrPositive == 0 {
                    dy[i] = try r.i16()
                }
            }

            var x = 0
            var y = 0
            var bounds = (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
            for i in 0..<points {
                x += dx[i]
                y += dy[i]
                bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
                putPoint(
                    onCurve: pointFlags[i] & onCurve != 0, dx: dx[i], dy: dy[i], flags: &flags, bytes: &coordinates)
            }
            putShort255(&coordinates, codeLength)
            instructions += code
            if pointFlags[0] & overlapSimple != 0 {
                overlaps[g >> 3] |= 0x80 >> (g & 7)
                anyOverlap = true
            }
            // The box is left out when it's what the points say, which is nearly always.
            var computed: [UInt8] = []
            for value in [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY] { computed.put16(value) }
            if Array(box) != computed {
                hasBox[g >> 3] |= 0x80 >> (g & 7)
                boxes += box
            }
        }

        var out: [UInt8] = []
        out.put16(0)
        out.put16(anyOverlap ? 1 : 0)
        out.put16(count)
        out.put16(longOffsets)
        let streams = [contourCounts, pointCounts, flags, coordinates, composites, hasBox + boxes, instructions]
        for stream in streams { out.put32(stream.count) }
        for stream in streams { out += stream }
        if anyOverlap { out += overlaps }
        return out
    }

    /// The reverse of `packGlyphs`: `glyf` and `loca` as a .ttf holds them.
    static func unpackGlyphs(_ packed: [UInt8]) throws -> Glyphs {
        var header = try ByteReader(packed)
        try header.skip(2)
        let options = try header.u16()
        let count = try header.u16()
        let longOffsets = try header.u16()
        guard longOffsets <= 1 else { throw FontError.damaged }
        var next = header.pos + 28
        func stream(_ size: Int) throws -> ByteReader {
            defer { next += size }
            return try ByteReader(packed, from: next, count: size)
        }
        var contourCounts = try stream(try header.u32())
        var pointCounts = try stream(try header.u32())
        var flags = try stream(try header.u32())
        var coordinates = try stream(try header.u32())
        var composites = try stream(try header.u32())
        var boxes = try stream(try header.u32())
        var instructions = try stream(try header.u32())
        let hasBox = Array(try boxes.take(((count + 31) >> 5) << 2))
        var overlapStream = try stream(options & 1 != 0 ? (count + 7) >> 3 : 0)
        let overlaps = Array(try overlapStream.take(overlapStream.remaining))

        var out = Glyphs()
        var offsets: [Int] = []
        offsets.reserveCapacity(count + 1)
        out.leftEdges.reserveCapacity(count)
        var totalPoints = 0
        for g in 0..<count {
            offsets.append(out.glyf.count)
            let contours = try contourCounts.i16()
            let explicitBox = hasBox[g >> 3] & (0x80 >> (g & 7)) != 0
            if contours == 0 {
                guard !explicitBox else { throw FontError.damaged }
                out.leftEdges.append(0)
                continue
            }

            if contours == -1 {
                guard explicitBox else { throw FontError.damaged }
                let box = try boxes.take(8)
                out.leftEdges.append(
                    Int(Int16(truncatingIfNeeded: Int(box[box.startIndex]) << 8 | Int(box[box.startIndex + 1]))))
                out.glyf.put16(-1)
                out.glyf += box
                let first = composites.pos
                var hasInstructions = false
                while true {
                    let component = try composites.u16()
                    try composites.skip(2 + componentSize(component))
                    if component & 0x0100 != 0 { hasInstructions = true }
                    if component & 0x0020 == 0 { break }
                }
                out.glyf += packed[first..<composites.pos]
                if hasInstructions {
                    let length = try short255(&coordinates)
                    out.glyf.put16(length)
                    out.glyf += try instructions.take(length)
                }
                out.glyf.pad4()
                continue
            }
            guard contours > 0 else { throw FontError.damaged }

            var endPoints: [Int] = []
            endPoints.reserveCapacity(contours)
            var points = 0
            for _ in 0..<contours {
                points += try short255(&pointCounts)
                guard points > 0, points <= 0x10000 else { throw FontError.damaged }
                endPoints.append(points - 1)
            }
            totalPoints += points
            guard totalPoints <= maxPoints else { throw FontError.damaged }
            let pointFlags = try flags.take(points)
            var xs = [Int](repeating: 0, count: points)
            var ys = [Int](repeating: 0, count: points)
            var x = 0
            var y = 0
            var bounds = (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
            for i in 0..<points {
                let (dx, dy) = try point(Int(pointFlags[pointFlags.startIndex + i]) & 0x7F, &coordinates)
                x += dx
                y += dy
                xs[i] = x
                ys[i] = y
                bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
            }
            let codeLength = try short255(&coordinates)
            let code = try instructions.take(codeLength)

            out.glyf.put16(contours)
            if explicitBox {
                let box = try boxes.take(8)
                out.leftEdges.append(
                    Int(Int16(truncatingIfNeeded: Int(box[box.startIndex]) << 8 | Int(box[box.startIndex + 1]))))
                out.glyf += box
            } else {
                out.leftEdges.append(bounds.minX)
                for value in [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY] { out.glyf.put16(value) }
            }
            for endPoint in endPoints { out.glyf.put16(endPoint) }
            out.glyf.put16(codeLength)
            out.glyf += code

            // Points the way TrueType stores them: a flag byte each (runs of the same flag are
            // written once, with a count), then the x steps, then the y steps, in as few bytes as fit.
            var flagBytes: [UInt8] = []
            var xBytes: [UInt8] = []
            var yBytes: [UInt8] = []
            var lastFlag = -1
            var run = 0
            var lastX = 0
            var lastY = 0
            for i in 0..<points {
                var flag = pointFlags[pointFlags.startIndex + i] & 0x80 == 0 ? onCurve : 0
                if i == 0, g >> 3 < overlaps.count, overlaps[g >> 3] & (0x80 >> (g & 7)) != 0 { flag |= overlapSimple }
                let dx = xs[i] - lastX
                let dy = ys[i] - lastY
                if dx == 0 {
                    flag |= xSameOrPositive
                } else if dx > -256, dx < 256 {
                    flag |= xShort | (dx > 0 ? xSameOrPositive : 0)
                    xBytes.append(UInt8(abs(dx)))
                } else {
                    xBytes.put16(dx)
                }
                if dy == 0 {
                    flag |= ySameOrPositive
                } else if dy > -256, dy < 256 {
                    flag |= yShort | (dy > 0 ? ySameOrPositive : 0)
                    yBytes.append(UInt8(abs(dy)))
                } else {
                    yBytes.put16(dy)
                }
                if flag == lastFlag, run != 255 {
                    flagBytes[flagBytes.count - 1] |= UInt8(repeats)
                    run += 1
                } else {
                    if run != 0 { flagBytes.append(UInt8(run)) }
                    flagBytes.append(UInt8(flag))
                    run = 0
                }
                lastFlag = flag
                lastX = xs[i]
                lastY = ys[i]
            }
            if run != 0 { flagBytes.append(UInt8(run)) }
            out.glyf += flagBytes
            out.glyf += xBytes
            out.glyf += yBytes
            out.glyf.pad4()
        }
        offsets.append(out.glyf.count)

        // Short offsets count in pairs of bytes and stop at 16 bits.
        guard longOffsets == 1 || out.glyf.count <= 0x1FFFE else { throw FontError.damaged }
        for offset in offsets {
            if longOffsets == 0 { out.loca.put16(offset >> 1) } else { out.loca.put32(offset) }
        }
        return out
    }

    /// One point's step from the previous point, in the format's own 1- to 4-byte encoding:
    /// the flag's low seven bits say how many bytes follow and how the step is spread over them
    /// (short steps, the common case, take the fewest).
    private static func point(_ flag: Int, _ r: inout ByteReader) throws -> (dx: Int, dy: Int) {
        func signed(_ signs: Int, _ value: Int) -> Int { signs & 1 != 0 ? value : -value }
        if flag < 10 {
            return (0, signed(flag, ((flag & 14) << 7) + (try r.u8())))
        } else if flag < 20 {
            return (signed(flag, (((flag - 10) & 14) << 7) + (try r.u8())), 0)
        } else if flag < 84 {
            let high = flag - 20
            let low = try r.u8()
            return (
                signed(flag, 1 + (high & 0x30) + (low >> 4)), signed(flag >> 1, 1 + ((high & 0x0C) << 2) + (low & 0x0F))
            )
        } else if flag < 120 {
            let high = flag - 84
            let x = try r.u8()
            let y = try r.u8()
            return (signed(flag, 1 + ((high / 12) << 8) + x), signed(flag >> 1, 1 + (((high % 12) >> 2) << 8) + y))
        } else if flag < 124 {
            let a = try r.u8()
            let b = try r.u8()
            let c = try r.u8()
            return (signed(flag, (a << 4) + (b >> 4)), signed(flag >> 1, ((b & 0x0F) << 8) + c))
        } else {
            let x = try r.u16()
            let y = try r.u16()
            return (signed(flag, x), signed(flag >> 1, y))
        }
    }

    private static func putPoint(onCurve: Bool, dx: Int, dy: Int, flags: inout [UInt8], bytes: inout [UInt8]) {
        let x = abs(dx)
        let y = abs(dy)
        let curve = onCurve ? 0 : 128
        let xSign = dx < 0 ? 0 : 1
        let ySign = dy < 0 ? 0 : 1
        let signs = xSign + 2 * ySign
        if dx == 0, y < 1280 {
            flags.append(UInt8(curve + ((y & 0xF00) >> 7) + ySign))
            bytes.append(UInt8(y & 0xFF))
        } else if dy == 0, x < 1280 {
            flags.append(UInt8(curve + 10 + ((x & 0xF00) >> 7) + xSign))
            bytes.append(UInt8(x & 0xFF))
        } else if x < 65, y < 65 {
            flags.append(UInt8(curve + 20 + ((x - 1) & 0x30) + (((y - 1) & 0x30) >> 2) + signs))
            bytes.append(UInt8((((x - 1) & 0x0F) << 4) | ((y - 1) & 0x0F)))
        } else if x < 769, y < 769 {
            flags.append(UInt8(curve + 84 + 12 * (((x - 1) & 0x300) >> 8) + (((y - 1) & 0x300) >> 6) + signs))
            bytes.append(UInt8((x - 1) & 0xFF))
            bytes.append(UInt8((y - 1) & 0xFF))
        } else if x < 4096, y < 4096 {
            flags.append(UInt8(curve + 120 + signs))
            bytes.append(UInt8(x >> 4))
            bytes.append(UInt8(((x & 0x0F) << 4) | (y >> 8)))
            bytes.append(UInt8(y & 0xFF))
        } else {
            flags.append(UInt8(curve + 124 + signs))
            bytes.put16(x)
            bytes.put16(y)
        }
    }

    // MARK: - Metrics

    /// `hmtx` with its left side bearings put back. An encoder may leave them out when they equal
    /// each glyph's left edge, which they nearly always do.
    static func unpackMetrics(_ packed: [UInt8], widths: Int, leftEdges: [Int]) throws -> [UInt8] {
        var r = try ByteReader(packed)
        let flags = try r.u8()
        let storedWithWidths = flags & 1 == 0
        let storedAlone = flags & 2 == 0
        guard flags & 0xFC == 0, !(storedWithWidths && storedAlone), widths >= 1, widths <= leftEdges.count else {
            throw FontError.damaged
        }
        let advances = try (0..<widths).map { _ in try r.u16() }
        var bearings = leftEdges
        if storedWithWidths {
            for i in 0..<widths { bearings[i] = try r.i16() }
        }
        if storedAlone {
            for i in widths..<leftEdges.count { bearings[i] = try r.i16() }
        }
        var out: [UInt8] = []
        for i in 0..<leftEdges.count {
            if i < widths { out.put16(advances[i]) }
            out.put16(bearings[i])
        }
        return out
    }
}

/// Brotli, the compression inside WOFF2.
enum Brotli {
    /// Unpacks a stream that must come to exactly `size` bytes. Memory grows with what actually
    /// comes out, not with `size`, which a damaged file can set to anything.
    static func decode(_ data: ArraySlice<UInt8>, to size: Int) throws -> [UInt8] {
        guard !data.isEmpty, size > 0 else { throw FontError.damaged }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK
        else { throw FontError.damaged }
        defer { compression_stream_destroy(stream) }

        var out: [UInt8] = []
        let chunk = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        try data.withUnsafeBufferPointer { input in
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let before = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                // More than the directory adds up to, a broken stream, or one cut short.
                guard out.count <= size, status != COMPRESSION_STATUS_ERROR else { throw FontError.damaged }
                if status == COMPRESSION_STATUS_END { break }
                guard produced > 0 || stream.pointee.src_size < before else { throw FontError.damaged }
            }
        }
        guard out.count == size else { throw FontError.damaged }
        return out
    }

    /// macOS's own encoder. It only has a fast, light setting, so the result is valid but larger
    /// than it could be; `best` is preferred where available.
    static func encode(_ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + data.count / 8 + 1024)
        let written = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_BROTLI)
        guard written > 0 else { throw FormatError("Couldn't compress this font") }
        out.removeLast(out.count - written)
        return out
    }

    /// The smallest stream this Mac can make: the `brotli` tool at its highest setting when it's
    /// installed (it comes along with ffmpeg from Homebrew), macOS's encoder otherwise.
    /// Stop ends the tool.
    static func best(_ data: [UInt8], runner: Runner) async throws -> [UInt8] {
        try runner.checkCancelled()
        if let tool = Tools.brotli, let small = try await run(tool, data, runner: runner) { return small }
        return try encode(data)
    }

    /// Nil when the tool fails or its output doesn't unpack to the input again.
    private static func run(_ tool: String, _ data: [UInt8], runner: Runner) async throws -> [UInt8]? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Convert-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("tables")
        let output = folder.appendingPathComponent("tables.br")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(data).write(to: input)
            try await runner.run(tool, ["--quality=11", "--output=\(output.path)", "--", input.path], duration: 0) {
                _ in
            }
            let small = [UInt8](try Data(contentsOf: output))
            return try decode(small[...], to: data.count) == data ? small : nil
        } catch is StoppedError {
            throw StoppedError()
        } catch {
            return nil
        }
    }
}
