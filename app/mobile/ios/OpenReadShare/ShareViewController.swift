import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let preview = UILabel()
    private let saveButton = UIButton(type: .system)
    private var reading: Reading?
    private var file: URL?
    private var webURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "Read with OpenRead"; title.font = .preferredFont(forTextStyle: .title2)
        preview.numberOfLines = 12; preview.text = "Opening shared content…"; preview.font = .preferredFont(forTextStyle: .body)
        saveButton.setTitle("Save to OpenRead", for: .normal); saveButton.configuration = .filled(); saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel", for: .normal); cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let note = UILabel(); note.text = "Saved only on your device. Open OpenRead to listen."; note.numberOfLines = 0; note.font = .preferredFont(forTextStyle: .footnote); note.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [title, preview, note, saveButton, cancel]); stack.axis = .vertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        Task { await load() }
    }
    private func load() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        do {
            for provider in providers where provider.hasItemConformingToTypeIdentifier("com.apple.property-list") {
                if let item = try await value(provider, type: "com.apple.property-list") as? [String: Any], let results = item[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any], let text = results["text"] as? String, !text.isEmpty {
                    reading = try Reading(title: (results["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Shared reading", text: text, source: results["url"] as? String).validated
                    ready(); return
                }
            }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let text = try await value(provider, type: UTType.plainText.identifier) as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed), url.scheme == "https", !trimmed.contains("\n") { webURL = url }
                    else { reading = try Reading(title: "Shared reading", text: trimmed).validated }
                    ready(); return
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try await value(provider, type: UTType.url.identifier) as? URL, !url.isFileURL {
                    guard url.scheme == "https" else { throw ReadingError.unsupportedFile }; webURL = url; ready(); return
                }
                for identifier in provider.registeredTypeIdentifiers {
                    guard let type = UTType(identifier), type.conforms(to: .pdf) || type.conforms(to: .image) || ["epub", "docx", "txt", "html"].contains(type.preferredFilenameExtension ?? "") else { continue }
                    file = try await copyFile(provider, type: identifier, suffix: type.preferredFilenameExtension ?? "txt"); ready(); return
                }
            }
            throw ReadingError.unsupportedFile
        } catch { preview.text = error.localizedDescription }
    }
    private func ready() { preview.text = reading.map { String($0.text.prefix(450)) } ?? file?.lastPathComponent ?? webURL?.absoluteString; saveButton.isEnabled = true }
    private func value(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in provider.loadItem(forTypeIdentifier: type) { item, error in if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: item) } } }
    }
    private func copyFile(_ provider: NSItemProvider, type: String, suffix: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }; guard let url else { throw ReadingError.unsupportedFile }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                    try FileManager.default.copyItem(at: url, to: destination); continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @objc private func save() {
        do {
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "OpenReadAppGroup") as? String ?? "group.dev.openread.mobile") else { throw ReadingError.sharingUnavailable }
            let inbox = group.appendingPathComponent("Inbox"); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let name = UUID().uuidString
            if let reading { try JSONEncoder().encode(reading).write(to: inbox.appendingPathComponent(name + ".json"), options: .atomic) }
            else if let file { try FileManager.default.copyItem(at: file, to: inbox.appendingPathComponent(name).appendingPathExtension(file.pathExtension)) }
            else if let webURL { try webURL.absoluteString.write(to: inbox.appendingPathComponent(name + ".url"), atomically: true, encoding: .utf8) }
            else { throw ReadingError.noText }
            close()
        } catch { preview.text = error.localizedDescription }
    }
    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
