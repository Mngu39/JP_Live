import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

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
    // Local to a separated interval; these lane numbers are not persistent people.
    var separationGroup: UUID? = nil
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

// Sentence boundaries are language boundaries, not short-pause heuristics.
// Final SpeechTranscriber fragments accumulate in a rolling buffer; NaturalLanguage
// decides which prefix contains complete sentences. Short breaths never seal a row.
struct SentenceBoundary {
    // Fallbacks only. They are intentionally much longer than ordinary speech breaths.
    static let fallbackSilence: Double = 2.0
    static let fallbackRecognizerIdle: Double = 2.5
    static let fallbackDuration: Double = 20.0
    static func fallbackCharacterLimit(_ language: SourceLanguage) -> Int {
        language == .japanese ? 220 : 480
    }

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
        return "。！？.!?…".contains(last)
    }

    // UTF-16 lengths of the complete leading sentences. The final tokenizer token is
    // treated as provisional unless it has explicit sentence-ending punctuation: an
    // end-of-buffer boundary alone must not recreate the old eager chunking behavior.
    static func firstCompletedSentencePrefixUTF16Length(in text: String, language: SourceLanguage) -> Int? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = source
        tokenizer.setLanguage(language == .japanese ? .japanese : .english)
        let whole = source.startIndex..<source.endIndex
        let ranges = tokenizer.tokens(for: whole)
        guard let first = ranges.first else { return nil }
        let piece = String(source[first])
        // NLTokenizer necessarily treats end-of-buffer as an ending. Trust that last
        // boundary only when punctuation makes it explicit; otherwise wait for more text.
        if ranges.count == 1 && !hasStrongEnding(piece) { return nil }
        return String(source[..<first.upperBound]).utf16.count
        #else
        // Non-Apple test hosts do not ship NaturalLanguage. Keep only explicit sentence
        // punctuation as a deterministic fallback; Apple builds use NLTokenizer above.
        var count = 0
        for scalar in source.unicodeScalars {
            count += String(scalar).utf16.count
            if "。！？.!?…".unicodeScalars.contains(scalar) { return count }
        }
        return nil
        #endif
    }
}

struct TranscriptRevisionEffect: Sendable {
    var updatedID: UUID
    var removedIDs: [UUID]
}

enum TranscriptRevisionResolution {
    case pending
    case rejected
    case applied(TranscriptRevisionEffect)
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
