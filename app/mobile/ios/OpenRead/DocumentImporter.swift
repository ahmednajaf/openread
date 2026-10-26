import Foundation
import PDFKit
import Vision
import UIKit
import SwiftSoup
import ZIPFoundation

struct ImportFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

actor DocumentImporter {
    func file(_ url: URL) async throws -> Reading {
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(240))
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf": text = try pdf(url)
        case "epub": text = try epub(url)
        case "docx": text = try docx(url)
        case "html", "htm": text = try html(String(decoding: Data(contentsOf: url), as: UTF8.self)).text
        case "txt", "md", "csv": text = try String(contentsOf: url, encoding: .utf8)
        case "jpg", "jpeg", "png", "heic", "webp", "tiff": text = try recognize(Data(contentsOf: url))
        default: throw ReadingError.unsupportedFile
        }
        return try Reading(title: title.isEmpty ? "Your reading" : title, text: checked(text)).validated
    }
    func image(_ data: Data) throws -> Reading { try Reading(title: "Scanned page", text: checked(recognize(data))).validated }
    func web(_ url: URL) async throws -> Reading {
        guard url.scheme == "https", url.host != nil else { throw ImportFailure(message: "Share an HTTPS webpage or paste its text.") }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.expectedContentLength <= 5 * 1_024 * 1_024,
              (response.mimeType ?? "").contains("html") else { throw ImportFailure(message: "This page could not be imported. Try sharing selected text instead.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 5 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
            data.append(byte)
        }
        let article = try html(String(decoding: data, as: UTF8.self))
        return try Reading(title: String((article.title.isEmpty ? url.host! : article.title).prefix(240)), text: checked(article.text), source: String(url.absoluteString.prefix(1_000))).validated
    }
    func inbox() async -> [(URL, Result<Reading, Error>)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: AppFiles.inbox, includingPropertiesForKeys: nil)) ?? []
        var readings: [(URL, Result<Reading, Error>)] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let reading: Reading
                if item.pathExtension == "json" { reading = try JSONDecoder().decode(Reading.self, from: Data(contentsOf: item)).validated }
                else if item.pathExtension == "url" {
                    guard let link = URL(string: try String(contentsOf: item, encoding: .utf8)) else { throw ReadingError.noText }
                    reading = try await web(link)
                }
                else { reading = try await file(item) }
                readings.append((item, .success(reading)))
            } catch { readings.append((item, .failure(error))) }
        }
        return readings
    }
    private func checked(_ text: String) throws -> String {
        let result = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ReadingError.noText }
        guard result.utf16.count <= 250_000 else { throw ReadingError.fileTooLarge }
        return result
    }
    private func html(_ source: String) throws -> (title: String, text: String) {
        let document = try SwiftSoup.parse(source)
        try document.select("script,style,noscript,nav,aside,footer,form,button,[hidden],[aria-hidden=true],.byline,.reading-time").remove()
        let root = try document.select("article").first() ?? document.select("main").first() ?? document.body()
        guard let root else { throw ReadingError.noText }
        try root.select("br").append("\n")
        try root.select("p,h1,h2,h3,h4,li,blockquote,tr").append("\n\n")
        return (try document.title(), try root.text(trimAndNormaliseWhitespace: false).replacingOccurrences(of: "\n[ \t]*\n(?:[ \t]*\n)+", with: "\n\n", options: .regularExpression))
    }
    private func pdf(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount <= 200 else { throw ImportFailure(message: "Choose a PDF with at most 200 pages.") }
        var pages: [String] = []; var scanned = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pages.append(text) }
            else {
                scanned += 1; guard scanned <= 20 else { throw ImportFailure(message: "Split scanned PDFs into sections of at most 20 pages.") }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2, 2_000 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let data = image.pngData() { pages.append(try recognize(data)) }
            }
            guard pages.reduce(0, { $0 + $1.utf16.count }) <= 250_000 else { throw ReadingError.fileTooLarge }
        }
        return pages.joined(separator: "\n\n")
    }
    private func recognize(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private func archiveData(_ archive: Archive, _ path: String) throws -> Data {
        guard let entry = archive[path], entry.uncompressedSize <= 20 * 1_024 * 1_024 else { throw ReadingError.unsupportedFile }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 20 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
            data.append(chunk)
        }
        return data
    }
    private func xml(_ data: Data) throws -> XMLReading {
        guard let source = String(data: data, encoding: .utf8), !source.contains("\0"), !source.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw ReadingError.unsupportedFile }
        let reader = XMLReading(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { throw ReadingError.unsupportedFile }; return reader
    }
    private func epub(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let container = try xml(archiveData(archive, "META-INF/container.xml"))
        guard let package = container.package else { throw ReadingError.unsupportedFile }
        let opf = try xml(archiveData(archive, package))
        let base = (package as NSString).deletingLastPathComponent
        var text: [String] = []
        for id in opf.spine {
            guard let href = opf.items[id], !href.contains(":") else { continue }
            let path = (base + "/" + href).removingPercentEncoding ?? ""
            let clean = (path as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !clean.hasPrefix("..") else { throw ReadingError.unsupportedFile }
            text.append(try html(String(decoding: archiveData(archive, clean), as: UTF8.self)).text)
            guard text.reduce(0, { $0 + $1.utf16.count }) <= 250_000 else { throw ReadingError.fileTooLarge }
        }
        return text.joined(separator: "\n\n")
    }
    private func docx(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        return try xml(archiveData(archive, "word/document.xml")).text
    }
}

private final class XMLReading: NSObject, XMLParserDelegate {
    var package: String?; var items: [String: String] = [:]; var spine: [String] = []; var text = ""
    private var inText = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = name.components(separatedBy: ":").last!
        if name == "rootfile" { package = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] { items[id] = href }
        if name == "itemref", let id = attributes["idref"] { spine.append(id) }
        if name == "t" { inText = true }
        if name == "br" { text += "\n" }; if name == "tab" { text += "\t" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let name = name.components(separatedBy: ":").last!
        if name == "t" { inText = false }; if name == "p" { text += "\n\n" }
    }
}
