// Adapted from Convert by eliasdesena — https://github.com/newtonstudios/convert (commit fd49eaf)
// Copyright (c) 2026 eliasdesena. MIT License — see THIRD_PARTY_NOTICES.md.

import AppKit
import PDFKit

/// A PDF page's text as paragraphs, for PDF → Word, OpenDocument and Rich Text.
///
/// A PDF only knows where each line of text sits on the page, not which lines form a paragraph.
/// So lines are joined back into paragraphs unless something marks a break: a gap clearly larger
/// than the page's usual line spacing, a change of text size (headings), a line ending early
/// although the next line's first word would have fit, a first-line indent, or a list marker.
///
/// The words, fonts and colours come from the page's own text (what Plain Text exports); PDFKit's
/// lines only add where things are. So a line PDFKit reports twice, or a letter it leaves out of
/// every line, can't double or lose a word.
enum PDFText {
    /// One line of text: where it is in the page's text, and where it sits on the page.
    struct Line {
        var range: NSRange
        var box: CGRect
        var size: CGFloat = 0
        var text = ""
        /// Spread far wider than its text: an entry in a table of contents, a row of a table.
        var spread = false
    }

    /// The page's paragraphs, each ending in a line break. Empty for a page without text.
    static func paragraphs(on page: PDFPage) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let plain = page.string else { return out }
        // PDFKit's styled text can drop letters (seen in mixed right-to-left text). Then the plain
        // text is used, without fonts: plainer, but with every word.
        let text = page.attributedString.flatMap { $0.string == plain ? $0 : nil } ?? NSAttributedString(string: plain)
        let frame = page.bounds(for: .cropBox).applying(page.transform(for: .cropBox))
        let layout = Layout(lines: lines(on: page, in: text), page: frame)
        var start = 0
        for i in layout.lines.indices.dropFirst() where layout.startsParagraph(i, after: start) {
            out.append(paragraph(layout.lines[start..<i], from: text, layout))
            start = i
        }
        if !layout.lines.isEmpty { out.append(paragraph(layout.lines[start...], from: text, layout)) }
        return out
    }

    // MARK: Lines

    /// The page's lines in reading order. Pieces PDFKit reports side by side (a word, a run of
    /// dots, a footnote mark) become one line; text no line covered goes with the next line.
    static func lines(on page: PDFPage, in text: NSAttributedString) -> [Line] {
        let chars = Array(text.string.utf16)
        let toPage = page.transform(for: .cropBox)  // Rotated pages: lines run left to right again.
        let pieces = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
        var lines: [Line] = []
        var cursor = 0
        for piece in pieces {
            guard let s = piece.string, let found = find(s, in: chars, from: cursor) else { continue }
            let box = piece.bounds(for: page).applying(toPage)
            let range = NSRange(location: cursor, length: found.upperBound - cursor)
            cursor = found.upperBound
            if let last = lines.last, sameRow(last.box, box) {
                lines[lines.count - 1].range = NSUnionRange(last.range, range)
                lines[lines.count - 1].box = last.box.union(box)
                lines[lines.count - 1].spread = last.spread || box.minX - last.box.maxX > 1.5 * box.height
            } else {
                lines.append(Line(range: range, box: box))
            }
        }
        if let last = lines.last {
            // Text after the last line PDFKit placed goes with that line.
            lines[lines.count - 1].range.length = chars.count - last.range.location
        } else {
            // Text without any line PDFKit can place: keep it as one paragraph.
            lines = [Line(range: NSRange(location: 0, length: chars.count), box: page.bounds(for: .cropBox))]
        }
        return lines.compactMap { described(trimmed($0, chars), in: text) }
    }

    /// Where `piece` first appears in the page's text at or after `start`, ignoring differences in
    /// spaces and line breaks (PDFKit's lines and the page's text don't always space alike).
    static func find(_ piece: String, in chars: [UInt16], from start: Int) -> Range<Int>? {
        let wanted = piece.utf16.filter { !isSpace($0) }
        guard let first = wanted.first else { return nil }
        func match(at i: Int) -> Int? {
            var j = 0
            var k = i
            while j < wanted.count, k < chars.count {
                if isSpace(chars[k]) {
                    k += 1
                } else if chars[k] == wanted[j] {
                    j += 1
                    k += 1
                } else {
                    return nil
                }
            }
            return j == wanted.count ? k : nil
        }
        for i in start..<chars.count where chars[i] == first {
            if let end = match(at: i) { return i..<end }
        }
        return nil
    }

    /// Two pieces of the same printed line: they overlap vertically and the second is to the right.
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * min(a.height, b.height) && b.minX > a.minX
    }

    static func isSpace(_ c: UInt16) -> Bool {
        Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    private static func trimmed(_ line: Line, _ chars: [UInt16]) -> Line {
        var lo = line.range.location
        var hi = line.range.upperBound
        while lo < hi, isSpace(chars[lo]) { lo += 1 }
        while hi > lo, isSpace(chars[hi - 1]) { hi -= 1 }
        var out = line
        out.range = NSRange(location: lo, length: hi - lo)
        return out
    }

    /// Fills in the line's text and its main text size. Nil for a line of only spaces.
    private static func described(_ line: Line, in text: NSAttributedString) -> Line? {
        guard line.range.length > 0 else { return nil }
        var out = line
        out.text = (text.string as NSString).substring(with: line.range)
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: line.range) { value, range, _ in
            if let font = value as? NSFont { counts[font.pointSize, default: 0] += range.length }
        }
        out.size = counts.max { $0.value < $1.value }?.key ?? 12
        out.spread = out.spread || line.box.width > 1.5 * out.size * CGFloat(out.text.count)
        return out
    }

    // MARK: Paragraph breaks

    /// A page's lines with what's needed to judge them: line spacing and where the text is.
    struct Layout {
        let lines: [Line]
        /// The usual distance from one line to the next, per text size.
        let pitch: [Int: CGFloat]
        /// Where the page's text runs from and to, or the page's edges when there's little text.
        let left: CGFloat
        let right: CGFloat
        /// Per line, where lines like it end: the right edge of its column, or of its box of text.
        private var ends: [CGFloat] = []

        init(lines: [Line], page: CGRect) {
            self.lines = lines
            let textLeft = lines.map(\.box.minX).min() ?? page.minX
            let textRight = lines.map(\.box.maxX).max() ?? page.maxX
            let wide = textRight - textLeft > 0.5 * page.width
            left = wide ? textLeft : page.minX
            right = wide ? textRight : page.maxX
            // The lower quartile, so pages with many short paragraphs still measure the distance
            // between lines rather than the gaps between paragraphs.
            var drops: [Int: [CGFloat]] = [:]
            for (p, c) in zip(lines, lines.dropFirst()) where key(p.size) == key(c.size) {
                let drop = p.box.minY - c.box.minY
                if drop > 0, drop < 3 * c.size { drops[key(c.size), default: []].append(drop) }
            }
            pitch = drops.mapValues { $0.sorted()[$0.count / 4] }

            // Lines following one another at the usual spacing form a block. Where they fill it,
            // the block's right edge is where its lines end (in a narrow box beside a picture, say).
            // Where most stop well short (code, verse, short paragraphs), the page's other text of
            // that size shows where the column ends.
            var start = 0
            for i in lines.indices where i + 1 == lines.count || !follows(lines[i], lines[i + 1]) {
                let block = lines[start...i]
                let blockEnd = reach(block.map(\.box.maxX))
                let from = block.map(\.box.minX).min() ?? blockEnd
                let middle = block.map(\.box.maxX).sorted()[block.count / 2]
                let filled = middle > from + 0.8 * (blockEnd - from)
                ends += block.map { filled ? blockEnd : pageEnd(of: $0) }
                start = i + 1
            }
        }

        /// Where the page's lines of this size that start no further left mostly end.
        private func pageEnd(of line: Line) -> CGFloat {
            reach(
                lines.filter {
                    key($0.size) == key(line.size) && $0.box.minX > line.box.minX - 0.15 * line.size
                        && $0.box.minX < line.box.maxX
                }.map(\.box.maxX))
        }

        /// How far these lines reach, leaving out the furthest tenth: a line running into the
        /// margin, or across two columns, doesn't count.
        private func reach(_ ends: [CGFloat]) -> CGFloat {
            let sorted = ends.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count - 1 - sorted.count / 10]
        }

        /// The line `c` comes right below `p`, in the same text size and at the usual distance.
        private func follows(_ p: Line, _ c: Line) -> Bool {
            let drop = p.box.minY - c.box.minY
            return key(p.size) == key(c.size) && drop > 0
                && drop <= (pitch[key(c.size)] ?? 1.2 * c.size) + 0.25 * c.size
        }

        /// Whether line `i` begins a new paragraph; the current one began at line `start`.
        func startsParagraph(_ i: Int, after start: Int) -> Bool {
            let p = lines[i - 1]
            let c = lines[i]
            let size = max(p.size, c.size)
            if abs(p.size - c.size) >= max(1, 0.1 * size) || p.spread || c.spread { return true }
            if isCentred(i - 1), isCentred(i) { return true }  // Lines of a title.

            // Further down than usual, or back up the page: a new paragraph. Except at the top of
            // the next column, where a paragraph can go on.
            let nextColumn = p.box.minY <= c.box.minY && c.box.minX > p.box.maxX - size
            if !follows(p, c), !nextColumn { return true }

            if PDFText.isBulleted(c.text) { return true }
            if PDFText.isNumbered(c.text), PDFText.isListItem(lines[start].text) || hangs(i) { return true }

            if nextColumn {
                // Indented compared with the column's next line.
                if i + 1 < lines.count, c.box.minX > lines[i + 1].box.minX + 0.6 * size { return true }
            } else {
                // Indented: a new paragraph. Unless it's a hanging indent: the second line of a list
                // item, or of a term and its explanation (were that first line short, the last check
                // still ends the paragraph).
                let hanging = i - 1 == start || PDFText.isListItem(lines[start].text)
                if c.box.minX > p.box.minX + 0.6 * size, !hanging { return true }
                // Back to the left after the second line: the end of a list item or an indented block.
                if c.box.minX < p.box.minX - 0.6 * size, i - 1 > start { return true }
            }

            // The previous line ended early although this line's first word would have fit after it.
            return p.box.maxX + firstWordWidth(c) < ends[i - 1] - 0.5 * size
        }

        /// The line after `i` is indented, as list items' following lines are ("31. Dezember" in
        /// the middle of a sentence isn't a list).
        private func hangs(_ i: Int) -> Bool {
            i + 1 < lines.count && lines[i + 1].box.minX > lines[i].box.minX + 0.6 * lines[i].size
        }

        /// A short line in the middle of the page's text, starting neither at its left edge nor
        /// where the lines around it start (those would be a narrow column that happens to be centred).
        func isCentred(_ i: Int) -> Bool {
            let line = lines[i]
            let box = line.box
            let aligned = [i - 1, i + 1].contains {
                lines.indices.contains($0) && abs(lines[$0].box.minX - box.minX) < 0.15 * line.size
            }
            return !aligned && box.minX > left + line.size && box.width < 0.7 * (right - left)
                && abs(box.midX - (left + right) / 2) < max(3, 0.5 * line.size)
        }

        /// Roughly how wide the line's first word is, plus a space before it.
        private func firstWordWidth(_ line: Line) -> CGFloat {
            let word = line.text.first.map(isCJK) == true ? 1 : line.text.prefix { !$0.isWhitespace }.count
            return line.box.width * CGFloat(word + 1) / CGFloat(max(line.text.count, 1))
        }
    }

    /// Text sizes that differ by less than half a point count as the same.
    private static func key(_ size: CGFloat) -> Int { Int((size * 2).rounded()) }

    static func isListItem(_ text: String) -> Bool { isBulleted(text) || isNumbered(text) }

    /// Starts with a bullet, or a dash or star followed by text.
    static func isBulleted(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•◦▪▫‣⁃●○■□►▶✓✔·".contains(first) { return true }
        return ["- ", "– ", "— ", "* "].contains { text.hasPrefix($0) }
    }

    /// Starts with a number or letter like "1." "2)" "a)" "(iv)" "3.1", followed by text.
    static func isNumbered(_ text: String) -> Bool {
        let token = text.prefix { !$0.isWhitespace }
        guard token.count < text.count else { return false }
        let numbered =
            #"^(\(?([0-9]{1,3}|[A-Za-z]|[ivxIVX]{2,4})[.)]|\([0-9A-Za-z]{1,4}\)|[0-9]{1,3}(\.[0-9]{1,3})+\.?)$"#
        return token.range(of: numbered, options: .regularExpression) != nil
    }

    // MARK: Writing a paragraph

    /// The lines as one paragraph, joined with spaces, ending in a line break.
    private static func paragraph(
        _ lines: ArraySlice<Line>, from text: NSAttributedString, _ layout: Layout
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var previous: Line?
        for line in lines {
            if let p = previous {
                let space = joiner(p, line)
                if !space.isEmpty { out.append(NSAttributedString(string: space, attributes: lastAttributes(of: out))) }
            }
            // A break inside a line becomes a space; other control characters can't go in a document.
            let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: line.range))
            for (pattern, replacement) in [(#"[\r\n\x{2028}\x{2029}]+"#, " "), (#"[\x00-\x08\x0B-\x1F]"#, "")] {
                piece.mutableString.replaceOccurrences(
                    of: pattern, with: replacement, options: .regularExpression,
                    range: NSRange(location: 0, length: piece.length))
            }
            out.append(piece)
            previous = line
        }
        out.append(NSAttributedString(string: "\n", attributes: lastAttributes(of: out)))

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = (lines.first?.size ?? 12) * 0.5
        if lines.count == 1, layout.isCentred(lines.startIndex) { style.alignment = .center }
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, range, _ in
            var kept: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .foregroundColor: readable(attrs)]
            kept[.font] = attrs[.font]
            out.setAttributes(kept, range: range)
        }
        return out
    }

    /// What goes between two lines of a paragraph: usually a space. Nothing after a hyphen (it
    /// stays), between Chinese or Japanese characters, or where the page's text has no space.
    private static func joiner(_ p: Line, _ c: Line) -> String {
        if c.range.location == p.range.upperBound { return "" }
        guard let last = p.text.last, let first = c.text.first else { return " " }
        if "-‐\u{00AD}".contains(last), p.text.dropLast().last?.isLetter == true { return "" }
        if isCJK(last), isCJK(first) { return "" }
        return " "
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// The text's own colour in a form documents store. Black when it has none (rather than
    /// following dark mode), and for near-white text, which was on a background that's gone now.
    private static func readable(_ attrs: [NSAttributedString.Key: Any]) -> NSColor {
        guard let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
            0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.9
        else { return .black }
        return c
    }

    private static func lastAttributes(of s: NSAttributedString) -> [NSAttributedString.Key: Any] {
        s.length > 0 ? s.attributes(at: s.length - 1, effectiveRange: nil) : [:]
    }
}
