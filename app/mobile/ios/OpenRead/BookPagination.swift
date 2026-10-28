import UIKit

/// Pagination is bounded to the current text window, never an entire large book.
struct BookPagination {
    let text: String
    let ranges: [NSRange]
    let font: UIFont
    let bodySize: CGSize

    static func font(for category: UIContentSizeCategory) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(descriptor: base, size: 21), compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    static func attributed(_ text: String, font: UIFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.28
        paragraph.paragraphSpacing = font.pointSize * 0.7
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.baseWritingDirection = .natural
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph
        ])
    }

    init(text: String, bodySize: CGSize, font: UIFont) {
        self.text = text; self.font = font
        self.bodySize = CGSize(width: max(40, bodySize.width), height: max(font.lineHeight * 2, bodySize.height))
        let storage = NSTextStorage(attributedString: Self.attributed(text, font: font))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var result: [NSRange] = []
        var end = 0
        while end < storage.length {
            let container = NSTextContainer(size: self.bodySize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard range.length > 0, NSMaxRange(range) > end else { break }
            result.append(NSRange(location: end, length: NSMaxRange(range) - end))
            end = NSMaxRange(range)
        }
        // An empty reading still has one sheet. Never silently drop a suffix
        // when the available area is too small to lay out a complete glyph.
        if end < storage.length { result.append(NSRange(location: end, length: storage.length - end)) }
        ranges = result.isEmpty ? [NSRange(location: 0, length: 0)] : result
    }

    func page(containing offset: Int) -> Int {
        ranges.lastIndex(where: { $0.location <= max(0, offset) }) ?? 0
    }

    static func isRightToLeft(_ text: String) -> Bool {
        let language = NSLinguisticTagger.dominantLanguage(for: String(text.prefix(2_000)))
        return NSParagraphStyle.defaultWritingDirection(forLanguage: language) == .rightToLeft
    }
}

enum BookLayoutKind { case single, spread, tabletop }

struct BookLayout {
    let kind: BookLayoutKind
    let book: CGRect
    let controls: CGRect
    let gutter: CGFloat
    var pages: Int { kind == .spread ? 2 : 1 }

    static func resolve(size: CGSize, division: CGRect? = nil, active: Bool = false) -> BookLayout {
        let bounds = CGRect(origin: .zero, size: size)
        let edge: CGFloat = size.width < 500 ? 12 : 20
        let dockHeight: CGFloat = 112
        if active, let division, division.width > division.height,
           division.midY > 120, division.midY < size.height - 110 {
            let book = CGRect(x: edge, y: 6, width: size.width - edge * 2,
                              height: max(100, division.minY - 16))
            let lower = CGRect(x: edge, y: division.maxY + 16, width: size.width - edge * 2,
                               height: max(100, size.height - division.maxY - 24))
            return BookLayout(kind: .tabletop, book: book, controls: lower, gutter: 0)
        }
        let vertical = division.flatMap { region -> CGRect? in
            guard region.height > region.width, region.midX > 200, region.midX < size.width - 200 else { return nil }
            return region
        }
        let spread = size.width >= 700 || vertical != nil
        let center = spread ? vertical?.midX ?? bounds.midX : bounds.midX
        let halfWidth = min(center, size.width - center) - edge
        let book = CGRect(x: center - halfWidth, y: 6, width: halfWidth * 2,
                          height: max(120, size.height - dockHeight - 22))
        let dockWidth = active && vertical != nil
            ? max(220, size.width - (vertical?.maxX ?? center) - edge * 2)
            : min(560, size.width - edge * 2)
        let dockX = active && vertical != nil ? size.width - edge - dockWidth : (size.width - dockWidth) / 2
        return BookLayout(kind: spread ? .spread : .single, book: book,
                          controls: CGRect(x: dockX, y: size.height - dockHeight - 6, width: dockWidth, height: dockHeight),
                          gutter: spread ? max(20, active ? (vertical?.width ?? 0) + 28 : 20) : 0)
    }
}
