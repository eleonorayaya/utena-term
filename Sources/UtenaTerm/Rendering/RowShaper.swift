import CoreText
import CoreGraphics

final class RowShaper {
    let font: CTFont
    private var scratchGlyphs: [CGGlyph] = []
    private var scratchAdvances: [CGSize] = []
    private var scratchIndices: [CFIndex] = []
    private var charToCol: [Int: Int] = [:]
    private var colToScalar: [Int: UInt32] = [:]
    private var result: [Int: GlyphAtlas.RowGlyph] = [:]

    init(font: CTFont) {
        self.font = font
    }

    /// Layout a terminal row using CoreText. Text contains one Unicode scalar per cell
    /// (spaces for empty cells); the shaper handles ligatures and font fallback through
    /// CTLine, then maps each shaped glyph back to its originating column.
    func layout(text: String, cellWidth: CGFloat, atlas: GlyphAtlas) -> [Int: GlyphAtlas.RowGlyph] {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        charToCol.removeAll(keepingCapacity: true)
        colToScalar.removeAll(keepingCapacity: true)
        result.removeAll(keepingCapacity: true)
        var utf16Offset = 0
        var col = 0
        for scalar in text.unicodeScalars {
            let utf16len = scalar.utf16.count
            charToCol[utf16Offset] = col
            colToScalar[col] = scalar.value
            if utf16len == 2 {
                charToCol[utf16Offset + 1] = col
            }
            utf16Offset += utf16len
            col += 1
        }

        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            if scratchGlyphs.count < count { scratchGlyphs = [CGGlyph](repeating: 0, count: count) }
            if scratchAdvances.count < count { scratchAdvances = [CGSize](repeating: .zero, count: count) }
            if scratchIndices.count < count { scratchIndices = [CFIndex](repeating: 0, count: count) }
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &scratchGlyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &scratchAdvances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &scratchIndices)

            let runFont: CTFont
            if let attrs = CTRunGetAttributes(run) as? [CFString: Any],
               let rf = attrs[kCTFontAttributeName] {
                runFont = (rf as! CTFont)
            } else {
                runFont = font
            }

            for i in 0..<count {
                let glyph = scratchGlyphs[i]
                guard glyph != 0 else { continue }
                let strIdx = Int(scratchIndices[i])
                guard let glyphCol = charToCol[strIdx] else { continue }

                let isIcon = colToScalar[glyphCol].map(isIconScalar) ?? false
                guard let (entry, isColor) = atlas.entry(forGlyph: glyph, font: runFont, isIcon: isIcon) else { continue }

                let advW = scratchAdvances[i].width
                let colSpan = max(1, Int(round(advW / cellWidth)))

                result[glyphCol] = GlyphAtlas.RowGlyph(
                    glyphIndex: glyph, isColor: isColor, entry: entry,
                    colSpan: colSpan, xOffset: 0, yOffset: 0
                )
            }
        }

        return result
    }
}
