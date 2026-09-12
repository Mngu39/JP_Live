import Foundation
import CoreFoundation
import NaturalLanguage
#if canImport(SudachiBridge)
import SudachiBridge
#endif

enum LocalTokenizer {
    static var engineName: String {
        #if canImport(SudachiBridge)
        return "Sudachi / Apple NaturalLanguage"
        #else
        return "Apple 형태소 분석 (Sudachi 미연결)"
        #endif
    }
    static func tokens(_ source: String, language: SourceLanguage) -> [WordToken] {
        #if canImport(SudachiBridge)
        if language == .japanese, let result = SudachiRuntime.analyze(source) { return result }
        #endif
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = source
        tagger.setLanguage(language == .japanese ? .japanese : .english, range: source.startIndex..<source.endIndex)
        var result: [WordToken] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        tokenizer.setLanguage(language == .japanese ? .japanese : .english)
        var cursor = 0
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let ns = NSRange(range, in: source)
            if ns.location > cursor {
                let surface = (source as NSString).substring(with: NSRange(location: cursor, length: ns.location-cursor))
                result.append(.init(surface: surface, lemma: surface, start: cursor, end: ns.location))
            }
            let surface = String(source[range])
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? surface
            result.append(.init(surface: surface, lemma: lemma,
                reading: language == .japanese ? reading(surface) : "", start: ns.location, end: ns.location+ns.length))
            cursor = ns.location + ns.length
            return true
        }
        if cursor < source.utf16.count {
            let surface = (source as NSString).substring(from: cursor)
            result.append(.init(surface: surface, lemma: surface, start: cursor, end: source.utf16.count))
        }
        return result
    }
    // Apple dictionary transliteration is a fallback, not a claim of Sudachi-equivalent readings.
    static func reading(_ word: String) -> String {
        guard let identifier = CFLocaleCreateCanonicalLocaleIdentifierFromString(kCFAllocatorDefault, "ja" as CFString),
              let locale = CFLocaleCreate(kCFAllocatorDefault, identifier),
              let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, word as CFString,
            CFRange(location: 0, length: word.utf16.count), kCFStringTokenizerUnitWord,
            locale) else { return "" }
        var output = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                output += latin.applyingTransform(StringTransform.latinToHiragana, reverse: false) ?? ""
            }
        }
        return output
    }
    static func hasKanji(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }
    }
}

// Serialize dictionary work away from MainActor. Pending volatile work is cancellable
// before analysis starts; the UI applies only a matching source/request afterwards.
actor MorphologyWorker {
    private struct Key: Hashable { var source: String; var language: SourceLanguage }
    private var cache: [Key: [WordToken]] = [:]
    private var order: [Key] = []
    func tokens(_ source: String, language: SourceLanguage) throws -> [WordToken] {
        try Task.checkCancellation()
        let key = Key(source: source, language: language)
        if let hit = cache[key] { return hit }
        let value = LocalTokenizer.tokens(source, language: language)
        try Task.checkCancellation()
        // Avoid caching an unbounded long transcript or dictionary results forever.
        if source.utf16.count <= 1000 {
            cache[key] = value; order.append(key)
            if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return value
    }
}

enum LearningData {
    private struct LoadedJSON {
        var entries: [String: [String: String]] = [:]
        var problem: String? = nil
    }
    private static let kanjiJSON = load("kanji_ko_attr_irreg.min")
    private static let deckJSON = load("deck-index")
    static var kanji: [String: [String: String]] { kanjiJSON.entries }
    static var deck: [String: [String: String]] { deckJSON.entries }
    // These messages use the SAME decoded data as the popup, not a file-exists probe.
    static var resourceStatus: [String] {
        [status("한자 사전", value: kanjiJSON), status("단어장 인덱스", value: deckJSON)]
    }
    private static func status(_ title: String, value: LoadedJSON) -> String {
        if let problem = value.problem { return title + ": " + problem }
        return "\(title): \(value.entries.count)개 로드됨"
    }
    private static func resourceURL(_ name: String) -> URL? {
        // Both deliverables are applications. App Playgrounds may omit the
        // generated module accessor; Phase 2 already copies JSON into the app.
        let main = Bundle.main
        if let url = main.url(forResource: name, withExtension: "json")
            ?? main.url(forResource: name, withExtension: "json", subdirectory: "Resources") { return url }
        // Some hosts retain a SwiftPM resource bundle inside the application.
        // Discover only app-owned immediate child bundles, without hardcoding a
        // generated bundle name or requiring a generated Swift accessor.
        guard let root = main.resourceURL,
              let children = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for child in children.filter({ $0.pathExtension == "bundle" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let bundle = Bundle(url: child) else { continue }
            if let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources") { return url }
        }
        return nil
    }
    private static func load(_ name: String) -> LoadedJSON {
        guard let url = resourceURL(name) else { return LoadedJSON(problem: "파일 없음 (\(name).json)") }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { return LoadedJSON(problem: "파일 읽기 실패 (\(name).json)") }
        do {
            let entries = try JSONDecoder().decode([String: [String: String]].self, from: data)
            return LoadedJSON(entries: entries, problem: entries.isEmpty ? "데이터 없음 (\(name).json)" : nil)
        } catch { return LoadedJSON(problem: "JSON 형식 오류 (\(name).json)") }
    }
}
