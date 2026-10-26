import SwiftUI
import UIKit

struct ReadingTextView: UIViewRepresentable {
    let text: String
    let highlighted: NSRange?
    let follow: Bool
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 24, bottom: 160, right: 24)
        view.accessibilityLabel = "Reading text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Georgia", size: 21) ?? .preferredFont(forTextStyle: .body))
        if view.text != text || context.coordinator.fontSize != font.pointSize {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10; paragraph.paragraphSpacing = 18
            view.attributedText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
            context.coordinator.fontSize = font.pointSize; context.coordinator.previous = nil
        }
        if let previous = context.coordinator.previous, NSMaxRange(previous) <= view.textStorage.length { view.textStorage.removeAttribute(.backgroundColor, range: previous) }
        if let range = highlighted, range.location >= 0, NSMaxRange(range) <= view.textStorage.length {
            view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemPurple.withAlphaComponent(0.2), range: range)
            if follow, let a = view.position(from: view.beginningOfDocument, offset: range.location), let b = view.position(from: a, offset: range.length), let target = view.textRange(from: a, to: b) {
                let rect = view.firstRect(for: target)
                let visible = CGRect(origin: view.contentOffset, size: view.bounds.size).insetBy(dx: 0, dy: 90)
                if !visible.contains(rect) { view.scrollRangeToVisible(range) }
            }
        }
        context.coordinator.previous = highlighted
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var previous: NSRange?; var fontSize: CGFloat = 0 }
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
