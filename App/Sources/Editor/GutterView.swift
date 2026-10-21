import TideCore
import UIKit

/// The line-number gutter beside the text view. It stays fixed while the text
/// scrolls and redraws the visible numbers from the layout manager's line
/// fragments (only a line's first fragment gets a number when wrapping).
final class GutterView: UIView {
    enum ChangeKind { case added, modified, deleted }

    weak var textView: UITextView?
    var lineIndex: () -> LineIndex = { LineIndex("") }
    var font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    var numberColor = UIColor.gray
    var activeNumberColor = UIColor.white
    var background = UIColor.black
    var activeLine = 0
    /// "on", "off" or "relative" (`editor.lineNumbers`).
    var mode = "on"
    var changes: [Int: ChangeKind] = [:]
    var changeColors: [ChangeKind: UIColor] = [:]
    var diagnosticLines: [Int: UIColor] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width that fits the largest line number with padding for change bars.
    func preferredWidth(lineCount: Int) -> CGFloat {
        guard mode != "off" else { return 14 }
        let digits = max(3, String(lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * digitWidth) + 26
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(background.cgColor)
        context.fill(rect)
        guard let textView, let layoutManager = textView.textContainer.layoutManager else { return }
        let container = textView.textContainer
        let index = lineIndex()
        let offsetY = textView.contentOffset.y - textView.textContainerInset.top
        let visible = CGRect(x: 0, y: offsetY, width: container.size.width, height: bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let numberRight = bounds.width - 12

        func drawLine(_ line: Int, fragment: CGRect) {
            let y = fragment.minY - offsetY
            if let kind = changes[line], let color = changeColors[kind] {
                context.setFillColor(color.cgColor)
                if kind == .deleted {
                    context.fill(CGRect(x: bounds.width - 6, y: y + fragment.height - 3, width: 6, height: 3))
                } else {
                    context.fill(CGRect(x: bounds.width - 5, y: y, width: 3, height: fragment.height))
                }
            }
            if let color = diagnosticLines[line] {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: 4, y: y + fragment.height / 2 - 2.5, width: 5, height: 5))
            }
            guard mode != "off" else { return }
            let isActive = line == activeLine
            let number = mode == "relative" && !isActive ? abs(line - activeLine) : line + 1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isActive ? activeNumberColor : numberColor, .paragraphStyle: paragraph,
            ]
            let textHeight = font.lineHeight
            ("\(number)" as NSString).draw(
                in: CGRect(x: 0, y: y + (fragment.height - textHeight) / 2, width: numberRight, height: textHeight),
                withAttributes: attributes
            )
        }

        if glyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, fragmentGlyphs, _ in
                let character = layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location)
                let line = index.line(containing: character)
                guard index.lineStarts[line] == character else { return }
                drawLine(line, fragment: fragment)
            }
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            let extra = layoutManager.extraLineFragmentRect
            if extra.maxY >= offsetY, extra.minY <= offsetY + bounds.height {
                drawLine(index.lineCount - 1, fragment: extra)
            }
        }
    }

    var onTapLine: ((Int) -> Void)?

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let textView, let layoutManager = textView.textContainer.layoutManager else { return }
        let y = gesture.location(in: self).y + textView.contentOffset.y - textView.textContainerInset.top
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 1, y: y), in: textView.textContainer)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        onTapLine?(lineIndex().line(containing: character))
    }
}
