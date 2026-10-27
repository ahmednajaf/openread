import Foundation
import PDFKit
import Vision

#if os(iOS)
import UIKit
#else
import AppKit
#endif
import SwiftSoup
import ZIPFoundation

struct ImportFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

actor DocumentImporter {
    func file(_ url: URL) async throws -> Reading {
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(240))
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf": text = try pdf(url)
        case "epub": return try epub(url)
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
        guard result.utf16.count <= 20_000_000 else { throw ReadingError.fileTooLarge }
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
        guard let document = PDFDocument(url: url), document.pageCount <= 2000 else { throw ImportFailure(message: "Choose a PDF with at most 2,000 pages.") }
        var pages: [String] = []; var scanned = 0; var characters = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let before = pages.count
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pages.append(text) }
            else {
                scanned += 1; guard scanned <= 20 else { throw ImportFailure(message: "Split scanned PDFs into sections of at most 20 pages.") }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2, 2_000 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                #if os(iOS)
                if let data = image.pngData() { pages.append(try recognize(data)) }
                #else
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) { pages.append(try recognize(data)) }
                #endif
            }
            if pages.count > before { characters += (pages.last?.utf16.count ?? 0) + 2 }
            guard characters <= 20_000_000 else { throw ReadingError.fileTooLarge }
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
    private func epub(_ url: URL) throws -> Reading {
        let archive = try Archive(url: url, accessMode: .read)
        var expanded: UInt64 = 0; var members = 0
        for entry in archive { guard entry.uncompressedSize <= 200 * 1024 * 1024 - expanded, members < 10_000 else { throw ReadingError.fileTooLarge }; expanded += entry.uncompressedSize; members += 1 }
        let container = try xml(archiveData(archive, "META-INF/container.xml"))
        guard let package = container.package else { throw ReadingError.unsupportedFile }
        let opf = try xml(archiveData(archive, package))
        func target(_ base: String, _ href: String) throws -> (String, String) {
            guard let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil, !href.contains("\\"), let relative = parts.percentEncodedPath.removingPercentEncoding else { throw ReadingError.unsupportedFile }
            let path = relative.isEmpty ? base : ((((base as NSString).deletingLastPathComponent.isEmpty ? "" : (base as NSString).deletingLastPathComponent + "/") + relative) as NSString).standardizingPath
            guard !path.hasPrefix("/"), !path.hasPrefix("../"), path != "..", !path.contains("\0") else { throw ReadingError.unsupportedFile }
            return (path, parts.percentEncodedFragment?.removingPercentEncoding ?? "")
        }
        var labels: [String: [(String, String)]] = [:]
        let navigation = opf.items.keys.filter { opf.properties[$0]?.split(separator: " ").contains("nav") == true }
        let navs = navigation.isEmpty ? opf.items.keys.filter { opf.mediaTypes[$0] == "application/x-dtbncx+xml" } : navigation
        for id in navs {
            guard let href = opf.items[id] else { continue }; let (file, _) = try target(package, href)
            let document = try SwiftSoup.parse(String(decoding: archiveData(archive, file), as: UTF8.self))
            if opf.mediaTypes[id] == "application/x-dtbncx+xml" {
                for point in try document.select("navpoint") {
                    guard let content = try point.select("content").first(), let label = try point.select("navlabel text").first() else { continue }
                    guard let (member, fragment) = try? target(file, content.attr("src")) else { continue }; labels[member, default: []].append((fragment, String(try label.text().prefix(240))))
                }
            } else {
                for nav in try document.select("nav") {
                    let type = try nav.attr("epub:type"); let role = try nav.attr("role")
                    guard type.split(separator: " ").contains("toc") || role == "doc-toc" else { continue }
                    for link in try nav.select("a[href]") { guard let (member, fragment) = try? target(file, link.attr("href")) else { continue }; labels[member, default: []].append((fragment, String(try link.text().prefix(240)))) }
                }
            }
        }
        var sections: [String] = []; var chapters: [ReadingChapter] = []; var offset = 0
        guard opf.spine.count <= 5_000 else { throw ReadingError.fileTooLarge }
        for id in opf.spine {
            try Task.checkCancellation()
            guard let href = opf.items[id] else { throw ReadingError.unsupportedFile }
            let (member, _) = try target(package, href)
            let document = try SwiftSoup.parse(String(decoding: archiveData(archive, member), as: UTF8.self))
            try document.select("script,style,noscript,head,nav,aside,footer,form,button,[hidden],[aria-hidden=true]").remove()
            let links = labels[member] ?? []
            var markers: [String: String] = [:]
            for (fragment, _) in links where !fragment.isEmpty {
                if let element = try document.getElementById(fragment) {
                    let marker = "OPENREAD_" + UUID().uuidString; markers[marker] = fragment
                    try element.before("<p>" + marker + "</p>")
                }
            }
            let heading = try document.select("h1,h2,h3").first()?.text() ?? "Chapter \(chapters.count + 1)"
            guard let body = document.body() else { continue }
            try body.select("br").append("\n"); try body.select("p,div,h1,h2,h3,h4,h5,h6,li,blockquote,section,tr").append("\n\n")
            let raw = try body.text(trimAndNormaliseWhitespace: false)
            let expression = try NSRegularExpression(pattern: "\\n\\s*\\n")
            let source = raw as NSString; var lower = 0; var parts: [String] = []; var localOffset = 0; var anchors: [String: Int] = [:]
            let boundaries = expression.matches(in: raw, range: NSRange(location: 0, length: source.length)).map(\.range) + [NSRange(location: source.length, length: 0)]
            for boundary in boundaries {
                let part = source.substring(with: NSRange(location: lower, length: boundary.location - lower)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let fragment = markers[part] { anchors[fragment] = localOffset }
                else if !part.isEmpty { parts.append(part); localOffset += part.utf16.count + 2 }
                lower = NSMaxRange(boundary)
            }
            let text = parts.joined(separator: "\n\n"); if text.isEmpty { continue }
            var starts: [Int: String] = [0: String(heading.prefix(240))]
            for (fragment, title) in links where !title.isEmpty {
                if fragment.isEmpty { starts[0] = title } else if let start = anchors[fragment], start < text.utf16.count { starts[start] = title }
            }
            if !sections.isEmpty { offset += 2 }
            for start in starts.keys.sorted() { chapters.append(.init(id: "chapter-\(chapters.count + 1)", title: starts[start]!, offset: offset + start)) }
            sections.append(text); offset += text.utf16.count
            guard offset <= 20_000_000 else { throw ReadingError.fileTooLarge }
        }
        let text = try checked(sections.joined(separator: "\n\n"))
        return try Reading(title: opf.title.isEmpty ? String(url.deletingPathExtension().lastPathComponent.prefix(240)) : String(opf.title.prefix(240)), text: text, author: opf.author.isEmpty ? nil : String(opf.author.prefix(240)), chapters: chapters).validated
    }
    private func docx(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        return try xml(archiveData(archive, "word/document.xml")).text
    }
}

private final class XMLReading: NSObject, XMLParserDelegate {
    var package: String?; var items: [String: String] = [:]; var spine: [String] = []; var text = ""
    var properties: [String: String] = [:]; var mediaTypes: [String: String] = [:]; var title = ""; var author = ""
    private var meta: String?
    private var inText = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = name.components(separatedBy: ":").last!
        if name == "rootfile" { package = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] { items[id] = href; properties[id] = attributes["properties"]; mediaTypes[id] = attributes["media-type"] }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
        if name == "title" || name == "creator" { meta = name }
        if name == "t" { inText = true }
        if name == "br" { text += "\n" }; if name == "tab" { text += "\t" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string }; if meta == "title" { title += string }; if meta == "creator" { author += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let name = name.components(separatedBy: ":").last!
        if name == meta { meta = nil }; if name == "t" { inText = false }; if name == "p" { text += "\n\n" }
    }
}
