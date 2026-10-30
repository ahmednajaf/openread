import SwiftUI
import UIKit

/// Spoken-word colour belongs to the renderer, not the selectable document.
/// Keeping TextKit 2 avoids the legacy Arabic layout/selection crash path.
final class NarrationTextView: UITextView {
    private(set) var narrationHighlight: NSRange?
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            self?.renderHighlight(manager, within: fragment.rangeInElement)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    convenience init() { self.init(usingTextLayoutManager: true) }

    func replaceText(_ text: NSAttributedString) {
        setNarrationHighlight(nil)
        selectedTextRange = nil
        attributedText = text
    }
    func setNarrationHighlight(_ range: NSRange?) {
        let valid = range.flatMap { range -> NSRange? in
            let count = text.utf16.count
            guard range.location >= 0, range.length > 0, range.location <= count,
                  range.length <= count - range.location else { return nil }
            return range
        }
        guard valid != narrationHighlight else { return }
        if let manager = textLayoutManager, let previous = narrationHighlight.flatMap(textRange) {
            manager.removeRenderingAttribute(.backgroundColor, for: previous)
        }
        narrationHighlight = valid
        if let manager = textLayoutManager, let document = manager.textContentManager?.documentRange {
            renderHighlight(manager, within: document)
        }
    }
    private func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
    private func renderHighlight(_ manager: NSTextLayoutManager, within fragment: NSTextRange) {
        guard let range = narrationHighlight.flatMap(textRange),
              let intersection = range.intersection(fragment), !intersection.isEmpty else { return }
        manager.setRenderingAttributes([.backgroundColor: UIColor.systemOrange.withAlphaComponent(0.25)], for: intersection)
    }
}

struct ReadingTextView: UIViewRepresentable {
    let text: String
    let highlighted: NSRange?
    let follow: Bool
    func makeUIView(context: Context) -> NarrationTextView {
        let view = NarrationTextView(); view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 24, bottom: 32, right: 24)
        view.accessibilityLabel = "Reading text"
        return view
    }
    func updateUIView(_ view: NarrationTextView, context: Context) {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Georgia", size: 21) ?? .preferredFont(forTextStyle: .body))
        if view.text != text || context.coordinator.fontSize != font.pointSize {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10; paragraph.paragraphSpacing = 18
            view.replaceText(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]))
            context.coordinator.fontSize = font.pointSize
        }
        let moved = view.narrationHighlight != highlighted
        view.setNarrationHighlight(highlighted)
        if moved, follow, let range = view.narrationHighlight,
           let a = view.position(from: view.beginningOfDocument, offset: range.location),
           let b = view.position(from: a, offset: range.length), let target = view.textRange(from: a, to: b) {
            let rect = view.firstRect(for: target)
            let visible = CGRect(origin: view.contentOffset, size: view.bounds.size).insetBy(dx: 0, dy: 90)
            if !visible.contains(rect) { view.scrollRangeToVisible(range) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var fontSize: CGFloat = 0 }
}

extension View {
    @ViewBuilder func readerGlass() -> some View {
        if #available(iOS 26, *) { self.glassEffect(.regular, in: .rect(cornerRadius: 28)) }
        else { self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28)) }
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    let finish: (Data?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController(); camera.sourceType = .camera; camera.delegate = context.coordinator; return camera
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(finish) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (Data?) -> Void
        init(_ finish: @escaping (Data?) -> Void) { self.finish = finish }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { finish(nil); return }
            let scale = min(1, 2_500 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let normalized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            finish(normalized.jpegData(compressionQuality: 0.9))
        }
    }
}

struct ShareFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
