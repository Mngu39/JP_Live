import SwiftUI
import UIKit
import CoreText

struct RubyText: UIViewRepresentable {
    var text: String
    var tokens: [WordToken]
    var ruby: Bool
    var size: CGFloat = 20
    var tap: (WordToken) -> Void
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> RubyCanvas { RubyCanvas() }
    func updateUIView(_ view: RubyCanvas, context: Context) {
        view.onTap = tap; view.tokens = tokens
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size),
            .foregroundColor: scheme == .dark ? UIColor.white : UIColor.label
        ])
        if ruby {
            for token in tokens where !token.reading.isEmpty && LocalTokenizer.hasKanji(token.surface) {
                guard token.start >= 0, token.end <= attr.length, token.end > token.start else { continue }
                let annotation = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before,
                    token.reading as CFString, [kCTRubyAnnotationSizeFactorAttributeName as String: 0.5] as CFDictionary)
                attr.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: annotation,
                                  range: NSRange(location: token.start, length: token.end-token.start))
            }
        }
        view.content = attr
        view.accessibilityLabel = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RubyCanvas, context: Context) -> CGSize? {
        uiView.measure(width: max(1, proposal.width ?? 300))
    }
}

final class RubyCanvas: UIView {
    var content = NSAttributedString(string: "") { didSet { invalidateIntrinsicContentSize(); setNeedsDisplay() } }
    var tokens: [WordToken] = []
    var onTap: ((WordToken) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(touched(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func measure(width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(content)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(width-2, 1), height: .greatestFiniteMagnitude), nil)
        return CGSize(width: width, height: ceil(size.height) + 8)
    }
    private func textFrame() -> CTFrame {
        let setter = CTFramesetterCreateWithAttributedString(content)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
            CGPath(rect: bounds.insetBy(dx: 1, dy: 4), transform: nil), nil)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        CTFrameDraw(textFrame(), context)
    }
    @objc private func touched(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        let point = CGPoint(x: p.x, y: bounds.height-p.y)
        let frame = textFrame()
        let pathOrigin = CTFrameGetPath(frame).boundingBoxOfPath.origin
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, relativeOrigin) in zip(lines, origins) {
            let origin = CGPoint(x: relativeOrigin.x+pathOrigin.x, y: relativeOrigin.y+pathOrigin.y)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let region = CGRect(x: origin.x, y: origin.y-descent, width: width, height: ascent+descent)
            guard region.contains(point) else { continue }
            let index = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x-origin.x, y: point.y-origin.y))
            if let token = tokens.first(where: { $0.start <= index && index < $0.end }),
               !token.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onTap?(token) }
            return
        }
    }
}
