import TideCore
import UIKit

/// VS Code's minimap: every character drawn as a tiny block in its token
/// color, with a slider for the visible region. Tap or drag to scroll.
/// When the document is taller than the minimap, the minimap scrolls
/// proportionally with the editor, as in VS Code.
final class MinimapView: UIView {
    static let lineHeight: CGFloat = 2
    static let characterWidth: CGFloat = 0.7
    static let maxColumns = 120

    weak var textView: UITextView?
    var sliderColor = UIColor.white.withAlphaComponent(0.12)
    var background = UIColor.black
    var onScrollToFraction: ((CGFloat) -> Void)?

    private var rendered: CGImage?
    private var renderedLineCount = 0
    private var renderTask: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dragged(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-renders the overview image, coalescing rapid edits.
    func scheduleRender(document: TextDocument, theme: Theme, delay: TimeInterval = 0.25) {
        renderTask?.cancel()
        let task = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            self.render(document: document, theme: theme)
        }
        renderTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func render(document: TextDocument, theme: Theme) {
        let index = document.lineIndex
        let text = document.storage.mutableString as NSString
        let cache = document.highlighter.cache
        let lineCount = index.lineCount
        let scale: CGFloat = 2
        let width = Int(CGFloat(Self.maxColumns) * Self.characterWidth * scale)
        let height = max(1, min(Int(CGFloat(lineCount) * Self.lineHeight * scale), 16_384))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let foreground = theme.uiColor("editor.foreground").withAlphaComponent(0.45).cgColor
        var colorCache: [TokenKind: CGColor] = [:]
        let maxLines = Int(CGFloat(height) / scale / Self.lineHeight)
        for line in 0..<min(lineCount, maxLines) {
            let range = index.contentRange(ofLine: line, in: text)
            guard range.length > 0 else { continue }
            let y = CGFloat(line) * Self.lineHeight
            let tokens = cache.tokens(forLine: line)
            var tokenIndex = 0
            var runStart = -1
            var runColor: CGColor?
            var column = 0
            let limit = min(range.length, Self.maxColumns * 2)
            func flush(_ end: Int) {
                if runStart >= 0, let runColor {
                    context.setFillColor(runColor)
                    context.fill(CGRect(x: CGFloat(runStart) * Self.characterWidth, y: y, width: CGFloat(end - runStart) * Self.characterWidth, height: Self.lineHeight - 0.5))
                }
                runStart = -1
            }
            for offset in 0..<limit {
                let unit = text.character(at: range.location + offset)
                while tokenIndex < tokens.count, tokens[tokenIndex].end <= offset { tokenIndex += 1 }
                let kind: TokenKind? = tokenIndex < tokens.count && tokens[tokenIndex].start <= offset ? tokens[tokenIndex].kind : nil
                if unit == 0x20 || unit == 0x09 {
                    flush(column)
                    column += unit == 0x09 ? 4 - column % 4 : 1
                    continue
                }
                let color: CGColor
                if let kind {
                    if let cached = colorCache[kind] {
                        color = cached
                    } else {
                        color = theme.tokenColor(kind).withAlphaComponent(0.75).cgColor
                        colorCache[kind] = color
                    }
                } else {
                    color = foreground
                }
                if runStart < 0 || runColor !== color {
                    flush(column)
                    runStart = column
                    runColor = color
                }
                column += 1
                if column >= Self.maxColumns { break }
            }
            flush(column)
        }
        rendered = context.makeImage()
        renderedLineCount = min(lineCount, maxLines)
        setNeedsDisplay()
    }

    /// Height of the whole document in minimap points.
    private var documentHeight: CGFloat { CGFloat(renderedLineCount) * Self.lineHeight }

    /// How far the minimap itself is scrolled, proportional to the editor.
    private func minimapOffset(scrollFraction: CGFloat) -> CGFloat {
        max(0, documentHeight - bounds.height) * scrollFraction
    }

    private var scrollFraction: CGFloat {
        guard let textView else { return 0 }
        let maxOffset = max(1, textView.contentSize.height - textView.bounds.height)
        return min(1, max(0, textView.contentOffset.y / maxOffset))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        guard let textView else { return }
        let offset = minimapOffset(scrollFraction: scrollFraction)
        if let rendered {
            let imageHeight = CGFloat(rendered.height) / 2
            let imageWidth = CGFloat(rendered.width) / 2
            context.saveGState()
            context.translateBy(x: 0, y: imageHeight - offset)
            context.scaleBy(x: 1, y: -1)
            context.draw(rendered, in: CGRect(x: 4, y: 0, width: imageWidth, height: imageHeight))
            context.restoreGState()
        }
        // Slider for the visible lines.
        let contentHeight = max(1, textView.contentSize.height)
        let visibleTop = textView.contentOffset.y / contentHeight * documentHeight
        let visibleHeight = max(8, textView.bounds.height / contentHeight * documentHeight)
        context.setFillColor(sliderColor.cgColor)
        context.fill(CGRect(x: 0, y: visibleTop - offset, width: bounds.width, height: visibleHeight))
        context.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height))
    }

    @objc private func dragged(_ gesture: UIGestureRecognizer) {
        guard documentHeight > 0 else { return }
        let y = gesture.location(in: self).y
        let offset = minimapOffset(scrollFraction: scrollFraction)
        let fraction = min(1, max(0, (y + offset) / documentHeight))
        onScrollToFraction?(fraction)
    }
}
