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

// Punctuation and connecting endings are only boundary hints, never a grammar parser.
struct ChunkBoundary {
    static func shouldCommit(_ text: String, pause: Double, duration: Double,
                             language: SourceLanguage) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if "。！？.!?".contains(t.last!) { return true }
        if duration >= 9 || t.utf16.count >= (language == .japanese ? 110 : 240) { return true }
        if language == .japanese && ["けど", "から", "って", "ので", "て", "し"].contains(where: t.hasSuffix) {
            return pause >= 1.2
        }
        return pause >= 0.65
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

enum SavePayload {
    static func make(caption: Caption, session: LearningSession, token: WordToken?,
                     tokens: [WordToken], translation: String) throws -> [String: Any] {
        guard caption.language == .japanese else { throw AppFailure.message("단어장 저장은 일본어만 지원합니다.") }
        guard caption.isFinal else { throw AppFailure.message("인식 중인 자막은 확정된 후 저장할 수 있습니다.") }
        let json = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        var body: [String: Any] = [
            "session_id": session.id, "source_text": caption.source,
            "item_type": token == nil ? "sentence_box" : "kanji_box",
            "context_group_id": caption.contextGroup, "ui_translation": translation,
            "source_furigana_json": json,
            "created_tz_offset_min": -TimeZone.current.secondsFromGMT() / 60
        ]
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
