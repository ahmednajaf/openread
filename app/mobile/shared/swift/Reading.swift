import Foundation

struct ReadingBookmark: Codable, Equatable, Identifiable, Sendable {
    var offset: Int
    var label: String
    var id: Int { offset }
}

struct ReadingChapter: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var offset: Int
}

struct Reading: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var text: String
    var source: String? = nil
    var author: String? = nil
    var position: Int = 0 // UTF-16 source offset, shared by both native apps.
    var bookmarks: [ReadingBookmark] = []
    var createdAt: Double = Date().timeIntervalSince1970
    var chapters: [ReadingChapter]? = nil
    var cachedWordCount: Int? = nil
    var cachedTextLength: Int? = nil
    var chapterList: [ReadingChapter] { chapters ?? [] }
    var textLength: Int { cachedTextLength ?? text.utf16.count }

    var wordCount: Int { cachedWordCount ?? ReadingText.words(in: text).count }
    var validated: Reading {
        get throws {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 20_000_000,
                  !id.isEmpty, id.count <= 80, (source?.count ?? 0) <= 1_000,
                  position >= 0, position <= text.utf16.count, bookmarks.count <= 200,
                  bookmarks.allSatisfy({ $0.offset >= 0 && $0.offset <= text.utf16.count && $0.label.count <= 160 })
            else { throw ReadingError.invalidReading }
            guard cachedTextLength == nil || cachedTextLength == text.utf16.count, cachedWordCount == nil || (0...text.utf16.count).contains(cachedWordCount!), Set(chapterList.map(\.id)).count == chapterList.count else { throw ReadingError.invalidReading }
            guard chapterList.count <= 5_000 else { throw ReadingError.invalidReading }
            var previous = -1
            for chapter in chapterList {
                guard !chapter.id.isEmpty, chapter.id.count <= 80, !chapter.title.isEmpty, chapter.title.count <= 240, chapter.offset > previous, chapter.offset < text.utf16.count else { throw ReadingError.invalidReading }; previous = chapter.offset
            }
            guard chapterList.isEmpty || chapterList.first?.offset == 0 else { throw ReadingError.invalidReading }
            return self
        }
    }
}

struct ReadingBackup: Codable {
    let format: String
    let documents: [Reading]
    init(documents: [Reading]) { self.format = "openread-mobile-library-v1"; self.documents = documents }
    static func decode(_ data: Data) throws -> ReadingBackup {
        guard data.count <= 25 * 1_024 * 1_024 else { throw ReadingError.fileTooLarge }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.format == "openread-mobile-library-v1", backup.documents.count <= 200,
              Set(backup.documents.map(\.id)).count == backup.documents.count else { throw ReadingError.invalidReading }
        for reading in backup.documents { _ = try reading.validated }
        return backup
    }
}

enum ReadingError: LocalizedError {
    case invalidReading, fileTooLarge, unsupportedFile, noText, downloadFailed, checksumFailed, missingModels, sharingUnavailable, speechTooComplex
    var errorDescription: String? {
        switch self {
        case .speechTooComplex: "This passage contains an unusually long word. Try a shorter excerpt."
        case .invalidReading: "This reading or backup is invalid. Nothing was imported."
        case .fileTooLarge: "This document exceeds the import limit: 100 MB per file or 20 million text characters."
        case .unsupportedFile: "Choose a PDF, EPUB, Word document, text, HTML or image."
        case .noText: "No readable text was found. Try scanning the page instead."
        case .downloadFailed: "The voice download could not finish. Check your connection and retry."
        case .checksumFailed: "The voice download did not pass its integrity check. Please retry."
        case .missingModels: "Download the natural voices in Settings first."
        case .sharingUnavailable: "OpenRead’s App Group is not configured. Enable it on both targets in Xcode before installing."
        }
    }
}

struct ReadingPassage: Sendable {
    let text: String
    let range: NSRange
}

enum ReadingText {
    static func passages(_ reading: Reading, limit: Int = 420) -> [ReadingPassage] {
        guard !reading.chapterList.isEmpty else { return passages(reading.text, limit: limit) }
        let source = reading.text as NSString
        return reading.chapterList.enumerated().flatMap { index, chapter in
            let end = index + 1 < reading.chapterList.count ? reading.chapterList[index + 1].offset : source.length
            let section = source.substring(with: NSRange(location: chapter.offset, length: end - chapter.offset))
            return passages(section, limit: limit).map { ReadingPassage(text: $0.text, range: NSRange(location: chapter.offset + $0.range.location, length: $0.range.length)) }
        }
    }
    static func windows(_ reading: Reading, passages: [ReadingPassage], limit: Int = 64_000) -> [NSRange] {
        let source = reading.text as NSString
        let mandatory = Set(reading.chapterList.map(\.offset) + [source.length])
        let boundaries = Set(passages.map { $0.range.location } + Array(mandatory)).sorted()
        var result: [NSRange] = []; var lower = 0; var previous = 0
        func append(_ end: Int) { if end > lower { result.append(NSRange(location: lower, length: end - lower)); lower = end } }
        for boundary in boundaries {
            if boundary - lower > limit, previous > lower { append(previous) }
            while boundary - lower > limit {
                var end = lower + limit
                if (0xD800...0xDBFF).contains(source.character(at: end - 1)) { end -= 1 }
                append(end)
            }
            if mandatory.contains(boundary) { append(boundary) }
            previous = boundary
        }
        return result
    }
    static func words(in text: String) -> [NSRange] {
        let expression = try! NSRegularExpression(pattern: "\\S+")
        return expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)
    }

    // Pack short headings with the following text. Every range remains an exact
    // UTF-16 slice, including repeated phrases, emoji and original whitespace.
    static func passages(_ text: String, limit: Int = 420) -> [ReadingPassage] {
        let source = text as NSString
        let boundaries = try! NSRegularExpression(pattern: "(?<=[.!?])\\s+|\\n\\s*\\n")
        let ends = boundaries.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { NSMaxRange($0.range) } + [source.length]
        var result: [ReadingPassage] = []
        var start = 0
        var pendingEnd = 0
        func whitespace(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        func append(_ lower: Int, _ upper: Int) {
            var a = lower; var b = upper
            while a < b, whitespace(source.character(at: a)) { a += 1 }
            while b > a, whitespace(source.character(at: b - 1)) { b -= 1 }
            if b > a { let range = NSRange(location: a, length: b - a); result.append(.init(text: source.substring(with: range), range: range)) }
        }
        for end in ends {
            if end - start > limit, pendingEnd > start { append(start, pendingEnd); start = pendingEnd }
            while end - start > limit {
                let window = NSRange(location: start, length: limit)
                let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
                var cut = space.location != NSNotFound && space.location > start + limit / 3 ? space.location : start + limit
                if cut < source.length, (0xD800...0xDBFF).contains(source.character(at: cut - 1)) { cut -= 1 }
                append(start, cut); start = cut
            }
            pendingEnd = end
        }
        append(start, pendingEnd)
        return result
    }

    static func estimatedWords(_ text: String, duration: Double) -> [(range: NSRange, start: Double, end: Double)] {
        let ranges = words(in: text); let weights = ranges.map { max(1, $0.length) }
        let total = max(1, weights.reduce(0, +)); var elapsed = 0
        return zip(ranges, weights).map { range, weight in
            let start = duration * Double(elapsed) / Double(total); elapsed += weight
            return (range, start, duration * Double(elapsed) / Double(total))
        }
    }
}
