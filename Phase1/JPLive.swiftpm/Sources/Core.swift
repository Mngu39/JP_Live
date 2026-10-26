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



struct TimedTextSpan: Codable, Hashable, Sendable {
    // UTF-16 offsets are relative to the owning transcript string, end exclusive.
    var utf16Start: Int
    var utf16End: Int
    var start: Double
    var end: Double

    var duration: Double { max(0, end-start) }
    var isValid: Bool {
        utf16Start >= 0 && utf16End > utf16Start &&
        start.isFinite && end.isFinite && end > start
    }

    func shiftedUTF16(by delta: Int) -> TimedTextSpan {
        TimedTextSpan(utf16Start: utf16Start+delta, utf16End: utf16End+delta,
                      start: start, end: end)
    }
}

// Device Validation must accumulate the validity of EVERY semantic STT callback.
// It may retain only a bounded sample of raw text for privacy/memory, but must
// not lose earlier failures when the sample rolls over.
enum DeviceValidationInvariants {
    static func hasRecognizedContent(_ text: String) -> Bool {
        // Punctuation-only finals can be legitimate STT callbacks, but they do
        // not establish that actual spoken words were recognized in a session.
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    static func validTimedSpeech(text: String, spans: [TimedTextSpan]) -> Bool {
        let length = text.utf16.count
        guard length > 0, !spans.isEmpty else { return false }
        var coveredThrough = 0
        var previousUTF16Start = -1
        var previousAudioStart = -Double.infinity
        var previousAudioEnd = -Double.infinity
        for span in spans {
            guard span.isValid, span.utf16Start >= previousUTF16Start,
                  span.utf16Start <= coveredThrough, span.utf16End <= length,
                  span.start >= previousAudioStart - 0.001,
                  span.end >= previousAudioEnd - 0.001 else { return false }
            previousUTF16Start = span.utf16Start
            previousAudioStart = span.start
            previousAudioEnd = span.end
            coveredThrough = max(coveredThrough, span.utf16End)
        }
        return coveredThrough == length
    }

    static func explicitStopRestart(firstStopped: Bool, secondStopped: Bool,
                                    firstEnd: Date, secondStart: Date) -> Bool {
        firstStopped && secondStopped && secondStart >= firstEnd
    }
}

// Monotone whole-session STT evidence; the JSON text trace can remain bounded
// to 48 callbacks without ever evicting an earlier integrity failure.
struct DeviceValidationSpeechAudit: Sendable {
    private(set) var callbackCount = 0
    private(set) var finalCount = 0
    private(set) var recognizedCount = 0
    private(set) var invalidTimedCount = 0
    private(set) var invalidExamples: [String] = []

    mutating func record(text: String, final: Bool, timedSpans: [TimedTextSpan]) {
        callbackCount += 1
        if final { finalCount += 1 }
        guard DeviceValidationInvariants.hasRecognizedContent(text) else { return }
        recognizedCount += 1
        if !DeviceValidationInvariants.validTimedSpeech(text: text, spans: timedSpans) {
            invalidTimedCount += 1
            if invalidExamples.count < 5 {
                // Keep callback index only: never embed recognized words in a failure detail.
                invalidExamples.append("callback #\(callbackCount): UTF-16/timing invalid")
            }
        }
    }

    var timedIntegrityPassed: Bool { recognizedCount > 0 && invalidTimedCount == 0 }
}

struct SpeakerSpan: Codable, Hashable, Sendable {
    // Text offsets remain sentence-relative even when one NLTokenizer row spans speakers.
    var utf16Start: Int
    var utf16End: Int
    var start: Double
    var end: Double
    // nil means overlap/conflict/unknown rather than inventing a persistent identity.
    var speaker: Int?
    var confidentSpeech: Double
    var overlap: Bool
    // An identical numeric slot in a different diarizer epoch is NOT the same person.
    // Optional for old diagnostics and separator rows without authoritative epoch evidence.
    var identityEpoch: Int? = nil

    var isValid: Bool {
        utf16Start >= 0 && utf16End > utf16Start &&
        start.isFinite && end.isFinite && end > start &&
        confidentSpeech.isFinite && confidentSpeech >= 0
    }
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
    // Apple Speech per-run source timing survives sentence tokenization so later
    // diarization can attribute the actual words instead of a character-ratio estimate.
    var timedTextSpans: [TimedTextSpan] = []
    // A semantic sentence can contain multiple speakers; preserve that evidence instead
    // of forcing the whole row into one speaker identity.
    var speakerSpans: [SpeakerSpan] = []
    // Legacy row-level summary: set only when all confident spans agree on one speaker.
    var speaker: Int? = nil
    var gutterHint: SpeakerGutterHint = .neutral
    // Local separator lane (0/1) is NOT a persistent diarizer speaker identity.
    // Keep it separate so UI colors can only use a real live-diarizer slot mapping.
    var separationLane: Int? = nil
    var separationGroup: UUID? = nil
    // Separation may render one NLTokenizer sentence as several visual rows. Keep a
    // logical sentence identity/source so translation and sentence actions never treat
    // those visual fragments as independent utterances. Optional fields keep older
    // persisted diagnostics/source fixtures decode-compatible.
    var semanticSentenceID: UUID? = nil
    var semanticSentenceSource: String? = nil
    var semanticSentenceStart: Double? = nil
    var semanticSentenceEnd: Double? = nil
    var semanticSentenceAnchor: Bool? = nil
    var semanticID: UUID { semanticSentenceID ?? id }
    var semanticSource: String { semanticSentenceSource ?? source }
    var semanticStart: Double { semanticSentenceStart ?? start }
    var semanticEnd: Double { semanticSentenceEnd ?? end }
    var isSemanticSentenceAnchor: Bool { semanticSentenceAnchor ?? true }
    var contextGroup: String { "stt:\(captureID.uuidString):\(semanticID.uuidString)" }
}

// Stable popup analysis identity: speaker tint, translation, and metadata-only
// caption revisions do not change token UTF-16 offsets. Source/mode changes do.
enum PopupAnalysisIdentity {
    static func morphologyKey(mode: String, row: Caption) -> String {
        "\(mode):\(row.captureID.uuidString):\(row.semanticID.uuidString):\(row.source)"
    }
    static func meaningKey(mode: String, row: Caption, tokenID: String?,
                           useAI: Bool, generation: UUID) -> String {
        "\(tokenID ?? "sentence"):\(useAI):\(morphologyKey(mode: mode, row: row)):\(row.semanticSource):\(generation)"
    }
}

// One logical sentence may be rendered as several separator lanes/visual rows.
// This is the exact full-sentence object to be translated and saved by the popup.
enum PopupSemanticSentence {
    // TranscriptBuffer appends each capture chronologically and separation replaces one
    // row in place with adjacent fragments. A logical sentence is therefore a contiguous
    // run of the same (captureID, semanticID). The caller already knows the current row
    // index; do not scan every historical caption each time the popup updates.
    static func resolve(current: Caption, rows: [Caption], currentIndex: Int) -> Caption? {
        guard rows.indices.contains(currentIndex),
              rows[currentIndex].id == current.id,
              rows[currentIndex].captureID == current.captureID,
              rows[currentIndex].semanticID == current.semanticID else { return nil }
        let semanticID = current.semanticID
        let captureID = current.captureID
        func isSameSentence(_ row: Caption) -> Bool {
            row.captureID == captureID && row.semanticID == semanticID
        }
        var lower = currentIndex
        while lower > rows.startIndex && isSameSentence(rows[lower - 1]) { lower -= 1 }
        var upper = currentIndex
        while upper < rows.count - 1 && isSameSentence(rows[upper + 1]) { upper += 1 }
        let group = rows[lower...upper]
        let anchor = group.first(where: \.isSemanticSentenceAnchor) ?? rows[lower]
        var sentence = anchor
        sentence.id = semanticID
        sentence.source = anchor.semanticSource
        sentence.start = anchor.semanticStart
        sentence.end = anchor.semanticEnd
        sentence.tokens = []
        sentence.separationLane = nil
        sentence.separationGroup = nil
        sentence.semanticSentenceID = semanticID
        sentence.semanticSentenceSource = anchor.semanticSource
        sentence.semanticSentenceStart = anchor.semanticStart
        sentence.semanticSentenceEnd = anchor.semanticEnd
        sentence.semanticSentenceAnchor = true
        return sentence
    }
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
        // A recognizer can deliver closing punctuation/quotes in the same final callback
        // (`。」`, `！？`, ...). Keep that punctuation attached to the sentence instead of
        // leaving a punctuation-only remainder that can never become a semantic row.
        var upper = first.upperBound
        while upper < source.endIndex {
            let next = source[upper]
            if next.isWhitespace || next.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { break }
            upper = source.index(after: upper)
        }
        return String(source[..<upper]).utf16.count
        #else
        // Non-Apple test hosts do not ship NaturalLanguage. Keep only explicit sentence
        // punctuation as a deterministic fallback; Apple builds use NLTokenizer above.
        let scalars = Array(source.unicodeScalars)
        var count = 0
        for i in scalars.indices {
            let scalar = scalars[i]
            count += String(scalar).utf16.count
            if "。！？.!?…".unicodeScalars.contains(scalar) {
                var j = i + 1
                while j < scalars.count {
                    let next = scalars[j]
                    if CharacterSet.whitespacesAndNewlines.contains(next) || CharacterSet.alphanumerics.contains(next) { break }
                    count += String(next).utf16.count
                    j += 1
                }
                return count
            }
        }
        return nil
        #endif
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

// Prevent a historical transcript row from receiving an image captured during a
// different system-audio capture. Historical text itself remains savable.
enum ScreenshotCapturePolicy {
    static func matches(caption: UUID, current: UUID, running: Bool) -> Bool {
        running && caption == current
    }
}

// A picker selection does not create a new AppModel.captureID. The audio
// source, however, changes when a replacement SCStream starts delivering PCM.
// All STT/Caption times use that same capture-local source-time clock. Require
// the COMPLETE semantic sentence to start in the currently selected source.
// If the new stream has not delivered PCM, fail closed (text can still be saved).
enum ScreenshotSourcePolicy {
    static func matches(sentenceStart: Double, sentenceEnd: Double, currentSourceFirstAudioTime: Double?) -> Bool {
        guard let first = currentSourceFirstAudioTime,
              first.isFinite, sentenceStart.isFinite, sentenceEnd.isFinite,
              sentenceEnd > sentenceStart else { return false }
        return sentenceStart + 1.0 / 48000 >= first
    }
}
