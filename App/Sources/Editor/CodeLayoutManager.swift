import UIKit

/// TextKit 1 layout manager that draws the editor decorations VS Code draws
/// around text: current line highlight, indent guides, find matches, bracket
/// match boxes, diagnostic squiggles and rendered whitespace.
///
/// TextKit 1 on iOS has no temporary attributes, so decorations are drawn
/// here instead of being stored as text attributes; that keeps highlighting
/// and decorations independent and avoids re-attributing text on every caret move.
nonisolated final class CodeLayoutManager: NSLayoutManager {
    struct Decorations {
        var currentLine: NSRange?
        var lineHighlight: UIColor?
        var lineHighlightBorder: UIColor?
        var findMatches: [NSRange] = []
        var currentFindMatch: NSRange?
        var findMatchColor = UIColor.clear
        var currentFindMatchColor = UIColor.clear
        var bracketMatches: [NSRange] = []
        var bracketMatchFill = UIColor.clear
        var bracketMatchBorder = UIColor.clear
        var squiggles: [(range: NSRange, color: UIColor)] = []
        var indentGuides = true
        var indentGuideColor = UIColor.clear
        var activeIndentGuideColor = UIColor.clear
        var tabSize = 4
        var spaceWidth: CGFloat = 8
        /// "none", "selection" or "all" (`editor.renderWhitespace`).
        var renderWhitespace = "selection"
        var whitespaceColor = UIColor.clear
        var selection = NSRange(location: 0, length: 0)
    }

    var decorations = Decorations()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let context = UIGraphicsGetCurrentContext(), let container = textContainers.first, let storage = textStorage else { return }
        let text = storage.mutableString as NSString

        // Current line: every fragment of the caret's line, edge to edge.
        if let line = decorations.currentLine, decorations.selection.length == 0 {
            let glyphs = glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            var rect = CGRect.null
            if glyphs.length > 0 {
                enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
            } else if extraLineFragmentTextContainer != nil, line.location >= text.length {
                rect = extraLineFragmentRect
            } else {
                rect = lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, numberOfGlyphs - 1)), effectiveRange: nil)
            }
            if !rect.isNull {
                let full = CGRect(x: 0, y: rect.minY + origin.y, width: container.size.width + origin.x * 2, height: rect.height)
                if let fill = decorations.lineHighlight {
                    context.setFillColor(fill.cgColor)
                    context.fill(full)
                } else if let border = decorations.lineHighlightBorder {
                    context.setStrokeColor(border.cgColor)
                    context.setLineWidth(1)
                    context.stroke(full.insetBy(dx: 0.5, dy: 0.5))
                }
            }
        }

        fill(ranges: decorations.findMatches, color: decorations.findMatchColor, in: glyphsToShow, origin: origin, context: context)
        if let current = decorations.currentFindMatch {
            fill(ranges: [current], color: decorations.currentFindMatchColor, in: glyphsToShow, origin: origin, context: context)
        }
        for range in decorations.bracketMatches {
            forEachRect(of: range, in: glyphsToShow) { rect in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -0.5, dy: 0)
                context.setFillColor(decorations.bracketMatchFill.cgColor)
                context.fill(box)
                context.setStrokeColor(decorations.bracketMatchBorder.cgColor)
                context.setLineWidth(1)
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        if decorations.indentGuides {
            drawIndentGuides(glyphsToShow: glyphsToShow, origin: origin, text: text, container: container, context: context)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let context = UIGraphicsGetCurrentContext(), let storage = textStorage else { return }
        for squiggle in decorations.squiggles {
            forEachRect(of: squiggle.range, in: glyphsToShow) { rect in
                drawSquiggle(under: rect.offsetBy(dx: origin.x, dy: origin.y), color: squiggle.color, context: context)
            }
        }
        if decorations.renderWhitespace != "none" {
            drawWhitespace(glyphsToShow: glyphsToShow, origin: origin, text: storage.mutableString as NSString, context: context)
        }
    }

    // MARK: - Helpers

    private func forEachRect(of characterRange: NSRange, in glyphsToShow: NSRange, _ body: (CGRect) -> Void) {
        guard let container = textContainers.first, let storage = textStorage, NSMaxRange(characterRange) <= storage.length else { return }
        let glyphs = glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 || (glyphs.length == 0 && NSLocationInRange(glyphs.location, glyphsToShow)) else { return }
        // The block is imported as escaping but runs synchronously.
        withoutActuallyEscaping(body) { body in
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                body(rect)
            }
        }
    }

    private func fill(ranges: [NSRange], color: UIColor, in glyphsToShow: NSRange, origin: CGPoint, context: CGContext) {
        guard !ranges.isEmpty else { return }
        context.setFillColor(color.cgColor)
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // Matches are sorted; skip straight to the visible window.
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) < visible.location { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < ranges.count, ranges[index].location <= NSMaxRange(visible) {
            forEachRect(of: ranges[index], in: glyphsToShow) { rect in
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            index += 1
        }
    }

    private func drawSquiggle(under rect: CGRect, color: UIColor, context: CGContext) {
        let path = UIBezierPath()
        let amplitude: CGFloat = 1.5
        let wavelength: CGFloat = 4
        let baseline = rect.maxY - 2
        var x = rect.minX
        path.move(to: CGPoint(x: x, y: baseline))
        var up = true
        while x < rect.maxX {
            let next = min(x + wavelength / 2, rect.maxX)
            path.addQuadCurve(to: CGPoint(x: next, y: baseline), controlPoint: CGPoint(x: (x + next) / 2, y: baseline + (up ? -amplitude : amplitude) * 2))
            x = next
            up.toggle()
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()
        context.restoreGState()
    }

    private func drawIndentGuides(glyphsToShow: NSRange, origin: CGPoint, text: NSString, container: NSTextContainer, context: CGContext) {
        let step = CGFloat(decorations.tabSize) * decorations.spaceWidth
        guard step > 0 else { return }
        let padding = container.lineFragmentPadding
        var activeLevel = -1
        if let current = decorations.currentLine {
            activeLevel = indentLevel(of: current.location, in: text) - 1
        }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { [self] fragment, _, _, glyphRange, _ in
            let characterIndex = characterIndexForGlyph(at: glyphRange.location)
            let paragraph = text.paragraphRange(for: NSRange(location: characterIndex, length: 0))
            var levels = indentLevel(of: paragraph.location, in: text)
            if levels == 0, isBlank(paragraph, in: text) {
                // Blank lines borrow the next non-blank line's indentation, as in VS Code.
                levels = indentLevelOfNextNonBlankLine(after: paragraph, in: text)
            }
            guard levels > 0 else { return }
            for level in 0..<levels {
                let x = origin.x + padding + CGFloat(level) * step + 0.5
                let color = level == activeLevel ? decorations.activeIndentGuideColor : decorations.indentGuideColor
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: fragment.minY + origin.y, width: 1, height: fragment.height))
            }
        }
    }

    private func indentLevel(of lineStart: Int, in text: NSString) -> Int {
        var columns = 0
        var index = lineStart
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 0x20 {
                columns += 1
            } else if unit == 0x09 {
                columns = (columns / decorations.tabSize + 1) * decorations.tabSize
            } else {
                break
            }
            index += 1
        }
        if index >= text.length || text.character(at: index) == 0x0A || text.character(at: index) == 0x0D { return 0 }
        return columns / max(1, decorations.tabSize)
    }

    private func isBlank(_ paragraph: NSRange, in text: NSString) -> Bool {
        text.substring(with: paragraph).allSatisfy { $0.isWhitespace }
    }

    private func indentLevelOfNextNonBlankLine(after paragraph: NSRange, in text: NSString) -> Int {
        var location = NSMaxRange(paragraph)
        var steps = 0
        while location < text.length, steps < 200 {
            let next = text.paragraphRange(for: NSRange(location: location, length: 0))
            if !isBlank(next, in: text) { return indentLevel(of: next.location, in: text) }
            location = NSMaxRange(next)
            steps += 1
        }
        return 0
    }

    private func drawWhitespace(glyphsToShow: NSRange, origin: CGPoint, text: NSString, context: CGContext) {
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let range = decorations.renderWhitespace == "all" ? visible : NSIntersectionRange(visible, decorations.selection)
        guard range.length > 0, range.length < 20_000 else { return }
        context.setFillColor(decorations.whitespaceColor.cgColor)
        for index in range.location..<NSMaxRange(range) {
            let unit = text.character(at: index)
            guard unit == 0x20 || unit == 0x09 else { continue }
            let glyph = glyphIndexForCharacter(at: index)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = self.location(forGlyphAt: glyph)
            let y = fragment.midY + origin.y
            let x = fragment.minX + location.x + origin.x
            if unit == 0x20 {
                context.fillEllipse(in: CGRect(x: x + decorations.spaceWidth / 2 - 1, y: y - 1, width: 2, height: 2))
            } else {
                context.fill(CGRect(x: x + 2, y: y - 0.5, width: max(4, decorations.spaceWidth * 1.5), height: 1))
            }
        }
    }
}

/// Gives every line fragment the editor line height and centers the glyphs
/// vertically, like VS Code's line height setting.
nonisolated final class LineHeightLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    let lineHeight: CGFloat
    let ascender: CGFloat
    let fontLineHeight: CGFloat

    init(lineHeight: CGFloat, font: UIFont) {
        self.lineHeight = lineHeight
        ascender = font.ascender
        fontLineHeight = font.lineHeight
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = (lineHeight - fontLineHeight) / 2 + ascender
        return true
    }
}
