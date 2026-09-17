import Foundation

enum SourceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case japanese = "ja-JP", english = "en-US"
    var id: String { rawValue }
    var title: String { self == .japanese ? "일본어" : "영어" }
    var code: String { self == .japanese ? "JA" : "EN" }
}

struct WordToken: Codable, Hashable, Identifiable, Sendable {
    var surface: String
    var lemma: String
    var reading: String = ""
    // UTF-16, end exclusive: same convention as the existing JavaScript backend.
    var start: Int
    var end: Int
    var meaning: String? = nil
    var note: String? = nil
    var kind: String? = nil
    var id: String { "\(start):\(end)" }
}

struct Caption: Identifiable, Codable {
    var id = UUID()
    var captureID: UUID
    var language: SourceLanguage
    var source: String
    var translation = ""
    var tokens: [WordToken] = []
    var start: Double
    var end: Double
    var isFinal: Bool
    var revision = 0
    var translationError: String? = nil
    // Analysis-local ID for chunk boundaries; never a UI identity/color index.
    var speaker: Int? = nil
    var gutterHint: SpeakerGutterHint = .neutral
    var contextGroup: String { "stt:\(captureID.uuidString):\(id.uuidString)" }
}

struct LearningSession: Codable, Identifiable, Hashable {
    var id: String
    var title: String?
    var raw_url: String?
    var session_key: String?
    var displayTitle: String { title ?? session_key ?? id }
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Punctuation and connecting endings are boundary hints, never a grammar parser.
// Live broadcast speech is dense, so a short breath must not close a chunk while a
// strong punctuation hint should still settle quickly.
struct ChunkBoundary {
    static let hardDuration: Double = 8
    static let strongPause: Double = 0.30
    static let ordinaryPause: Double = 0.78
    static let continuationPause: Double = 1.05

    static func hasSemanticContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
    static func isPunctuationOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !hasSemanticContent(t)
    }
    static func hasStrongEnding(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        return "。！？.!?".contains(last)
    }
    static func isJapaneseContinuation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "けど", "けども", "けれど", "けれども", "から", "って", "ので",
            "のに", "なら", "たり", "とか", "というか", "それで", "て", "し", "が"
        ].contains(where: t.hasSuffix)
    }
    static func shouldCommit(_ text: String, pause: Double, duration: Double,
                             language: SourceLanguage) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSemanticContent(t) else { return false }
        if duration >= hardDuration || t.utf16.count >= (language == .japanese ? 110 : 240) { return true }
        if language == .japanese && isJapaneseContinuation(t) { return pause >= continuationPause }
        if hasStrongEnding(t) { return pause >= strongPause }
        return pause >= ordinaryPause
    }
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        let chars = Array(text)
        let lower = max(1, limit / 2)
        let upper = min(chars.count - 1, limit)
        let cut = (lower...upper).reversed().first { "、，,。！？.!? \n".contains(chars[$0 - 1]) } ?? upper
        return [String(chars[..<cut])] + split(String(chars[cut...]), limit: limit)
    }
}


enum JapaneseText {
    static func hiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }
}

enum SavePayload {
    static func make(caption: Caption, session: LearningSession, token: WordToken?,
                     tokens: [WordToken], translation: String, screenshot: [String: Any]? = nil) throws -> [String: Any] {
        guard caption.language == .japanese else { throw AppFailure.message("단어장 저장은 일본어만 지원합니다.") }
        let json = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        var body: [String: Any] = [
            "session_id": session.id, "source_text": caption.source,
            "item_type": token == nil ? "sentence_box" : "kanji_box",
            "context_group_id": caption.contextGroup, "ui_translation": translation,
            "source_furigana_json": json,
            "created_tz_offset_min": -TimeZone.current.secondsFromGMT() / 60
        ]
        if let screenshot { body["screenshot"] = screenshot }
        if let t = token {
            guard t.start >= 0, t.end <= caption.source.utf16.count, t.end > t.start,
                  (caption.source as NSString).substring(with: NSRange(location: t.start, length: t.end-t.start)) == t.surface
            else { throw AppFailure.message("선택한 단어의 원문 위치가 일치하지 않습니다.") }
            body["target_word"] = t.lemma
            body["target_surface"] = t.surface
            body["target_word_lemma"] = t.lemma
            body["target_word_reading"] = t.reading
            body["target_start_index"] = t.start
            body["target_end_index"] = t.end
        }
        return body
    }
}
