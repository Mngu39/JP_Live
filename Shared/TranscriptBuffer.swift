import Foundation

// Keeps rolling recognizer state separate from UI geometry and the asynchronous recognizer.
// SpeechTranscriber final fragments are NOT treated as sentence boundaries. They accumulate
// until NaturalLanguage identifies a completed sentence; only long silence/duration are fallbacks.
struct TranscriptBuffer {
    var rows: [Caption] = []
    private var captureID = UUID()
    private var language: SourceLanguage = .japanese
    private var draftID: UUID?
    var draftRowID: UUID? { draftID }
    private var pending = ""
    private var pendingStart: Double = 0
    private var pendingEnd: Double = 0
    private var pendingSpeaker: Int?
    private var lastResultAt: Double = 0
    private var volatileUpdatedAt: Double = 0
    private var volatile = ""
    private var volatileStart: Double = 0
    private var volatileEnd: Double = 0
    private var volatileSpeaker: Int?

    mutating func begin(captureID: UUID, language: SourceLanguage) {
        self.captureID = captureID; self.language = language
        resetChunkState()
    }

    // UI clear is intentionally independent from capture lifetime. The recognizer keeps
    // running; subsequent results start a fresh visible sentence in the same capture.
    mutating func clearDisplay() {
        rows.removeAll(keepingCapacity: true)
        resetChunkState()
    }

    private mutating func resetChunkState() {
        draftID = nil; pending = ""; volatile = ""
        pendingStart = 0; pendingEnd = 0; volatileStart = 0; volatileEnd = 0
        pendingSpeaker = nil; volatileSpeaker = nil
        lastResultAt = 0; volatileUpdatedAt = 0
    }

    mutating func receive(_ text: String, final: Bool, start: Double, end: Double,
                          speaker: Int?, now: Double) -> [UUID] {
        guard start.isFinite, end.isFinite, end >= start, now.isFinite else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty volatile/final results may revoke the current tentative hypothesis.
            let sameStart = abs(start-volatileStart) < 1.0/24000
            let overlaps = start < volatileEnd && end > volatileStart
            if !volatile.isEmpty && (sameStart || overlaps) {
                volatile = ""; volatileSpeaker = nil; lastResultAt = now
                refreshDraft()
            }
            return []
        }

        // Punctuation-only noise must never become its own row. A final sentence mark may
        // decorate the stable rolling prefix and can then let NLTokenizer close it.
        if SentenceBoundary.isPunctuationOnly(trimmed) {
            lastResultAt = now
            guard final, !pending.isEmpty, trimmed.contains(where: { "。！？.!?…".contains($0) }) else { return [] }
            if let last = trimmed.last, pending.last != last { pending.append(last) }
            pendingEnd = max(pendingEnd, end)
            let ready = commitCompletedSentences()
            if !pending.isEmpty || !volatile.isEmpty { refreshDraft() }
            return ready
        }

        lastResultAt = now
        if final {
            // Final replaces the tentative hypothesis for that recognizer phrase, but does
            // not itself mean "sentence complete".
            let sameStart = abs(start-volatileStart) < 1.0/24000
            let overlaps = start < volatileEnd && end > volatileStart
            if !volatile.isEmpty && (sameStart || overlaps) {
                volatile = ""; volatileSpeaker = nil
            }
            if pending.isEmpty {
                pendingStart = start; pendingSpeaker = speaker
            } else if pendingSpeaker != speaker, speaker != nil {
                // Mixed/uncertain speaker attribution does not split a sentence.
                pendingSpeaker = nil
            }
            pending = join(pending, trimmed)
            pendingEnd = max(pendingEnd, end)
            let ready = commitCompletedSentences()
            if !pending.isEmpty || !volatile.isEmpty { refreshDraft() }
            return ready
        }

        volatile = trimmed; volatileStart = start; volatileEnd = end
        volatileSpeaker = speaker; volatileUpdatedAt = now
        refreshDraft()
        return []
    }

    mutating func tick(now: Double, activity: AudioActivity? = nil) -> [UUID] {
        guard !pending.isEmpty, now.isFinite else { return [] }

        // Normal sentence detection is text-based. These are only escape hatches for
        // punctuation-free speech or recognizer behavior that never yields an internal boundary.
        let span = max(pendingEnd, volatile.isEmpty ? pendingEnd : volatileEnd)-pendingStart
        if span >= SentenceBoundary.fallbackDuration ||
            pending.utf16.count >= SentenceBoundary.fallbackCharacterLimit(language) {
            return commitAllPending()
        }

        guard now-lastResultAt >= 0.20 else { return [] }
        let matched = activity.flatMap { $0.through >= pendingEnd ? $0 : nil }
        if matched?.speaking == true { return [] }

        if !volatile.isEmpty {
            guard now-volatileUpdatedAt >= SentenceBoundary.fallbackSilence,
                  let matched, !matched.speaking,
                  matched.through >= volatileEnd,
                  matched.silence >= SentenceBoundary.fallbackSilence else { return [] }
            return commitAllPending()
        }

        if let matched, !matched.speaking, matched.silence >= SentenceBoundary.fallbackSilence {
            return commitAllPending()
        }
        if matched == nil && now-lastResultAt >= SentenceBoundary.fallbackRecognizerIdle {
            return commitAllPending()
        }
        return []
    }

    mutating func finish() -> [UUID] {
        let ready = commitAllPending()
        if !volatile.isEmpty { refreshDraft() }
        if let id = draftID, let index = rows.firstIndex(where: { $0.id == id && !$0.isFinal }) {
            rows[index].translationError = "인식 종료 · 미확정 원문"
        }
        volatile = ""; volatileSpeaker = nil
        return ready
    }

    // Diarization is allowed to arrive after STT. It annotates already-visible text and
    // never determines a sentence boundary.
    mutating func applySpeakerTimeline(_ timeline: SpeechTimeline) -> [UUID] {
        var changed: [UUID] = []
        if !pending.isEmpty, timeline.decision(start: pendingStart, end: pendingEnd) != nil {
            pendingSpeaker = timeline.speaker(start: pendingStart, end: pendingEnd)
        }
        if !volatile.isEmpty, timeline.decision(start: volatileStart, end: volatileEnd) != nil {
            volatileSpeaker = timeline.speaker(start: volatileStart, end: volatileEnd)
        }
        for index in rows.indices {
            guard timeline.decision(start: rows[index].start, end: rows[index].end) != nil else { continue }
            let slot = timeline.speaker(start: rows[index].start, end: rows[index].end)
            guard rows[index].speaker != slot else { continue }
            rows[index].speaker = slot; rows[index].revision += 1; changed.append(rows[index].id)
        }
        if draftID != nil { refreshDraft() }
        return changed
    }

    // A delayed, quality-pass SpeechTranscriber produces its own sentence rows. Match by
    // source-audio time and update/merge the already-visible row in place. This preserves
    // low-latency display while letting the better second pass correct it later.
    mutating func applyRevision(_ revised: Caption) -> TranscriptRevisionEffect? {
        guard revised.isFinal, revised.captureID == captureID, revised.language == language,
              revised.end > revised.start, SentenceBoundary.hasSemanticContent(revised.source) else { return nil }
        let candidates = rows.indices.filter { index in
            let row = rows[index]
            guard row.isFinal, row.captureID == captureID, row.language == language else { return false }
            return min(row.end, revised.end) - max(row.start, revised.start) > 0.02
        }
        guard let first = candidates.first, let last = candidates.last else { return nil }
        let overlap = candidates.reduce(0.0) { value, index in
            value + max(0, min(rows[index].end, revised.end)-max(rows[index].start, revised.start))
        }
        let revisedDuration = max(0.001, revised.end-revised.start)
        let existingStart = rows[first].start
        let existingEnd = rows[last].end
        let existingDuration = max(0.001, existingEnd-existingStart)
        guard overlap / min(revisedDuration, existingDuration) >= 0.55 else { return nil }

        let existingSource = candidates.map { rows[$0].source }.reduce("") { join($0, $1) }
        guard existingSource != revised.source || candidates.count > 1 else { return nil }

        let keptID = rows[first].id
        let removed = candidates.dropFirst().map { rows[$0].id }
        let old = rows[first]
        let sameSpeaker = candidates.allSatisfy { rows[$0].speaker == old.speaker }
        var replacement = Caption(
            id: keptID, captureID: captureID, language: language,
            source: revised.source, translation: "", tokens: [],
            start: min(existingStart, revised.start), end: max(existingEnd, revised.end),
            isFinal: true, revision: old.revision + 1,
            speaker: revised.speaker ?? (sameSpeaker ? old.speaker : nil),
            gutterHint: old.gutterHint
        )
        replacement.translationError = nil
        for index in candidates.reversed() { rows.remove(at: index) }
        rows.insert(replacement, at: first)
        return TranscriptRevisionEffect(updatedID: keptID, removedIDs: removed)
    }

    private func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty, !second.isEmpty else { return first + second }
        let needsSpace = language == .english && first.last?.isWhitespace == false && second.first?.isWhitespace == false
        return first + (needsSpace ? " " : "") + second
    }

    private mutating func refreshDraft() {
        let text = join(pending, volatile)
        guard !text.isEmpty else {
            if let id = draftID { rows.removeAll { $0.id == id && !$0.isFinal } }
            draftID = nil
            return
        }
        let id = draftID ?? UUID(); draftID = id
        let previous = rows.firstIndex { $0.id == id }
        let old = previous.map { rows[$0] }
        var row = Caption(id: id, captureID: captureID, language: language, source: text,
            tokens: [],
            start: pending.isEmpty ? volatileStart : pendingStart,
            end: volatile.isEmpty ? pendingEnd : volatileEnd, isFinal: false,
            speaker: pending.isEmpty ? volatileSpeaker : (volatile.isEmpty || volatileSpeaker == pendingSpeaker ? pendingSpeaker : nil))
        row.revision = old.map { $0.revision + 1 } ?? 0
        if let old {
            row.translation = old.translation
            row.translationError = old.translationError
            row.gutterHint = old.gutterHint
            if old.source == text { row.tokens = old.tokens }
        }
        if let previous { rows[previous] = row } else { rows.append(row) }
    }

    private mutating func commitCompletedSentences() -> [UUID] {
        var ready: [UUID] = []
        while let length = SentenceBoundary.firstCompletedSentencePrefixUTF16Length(in: pending, language: language),
              length > 0, length <= pending.utf16.count {
            ready += commitPrefix(length)
            if pending.isEmpty { break }
        }
        return ready
    }

    private mutating func commitAllPending() -> [UUID] {
        guard !pending.isEmpty else { return [] }
        return commitPrefix(pending.utf16.count)
    }

    private mutating func commitPrefix(_ utf16Count: Int) -> [UUID] {
        guard utf16Count > 0, utf16Count <= pending.utf16.count else { return [] }
        let original = pending
        let total = max(1, original.utf16.count)
        let ns = original as NSString
        let piece = ns.substring(to: utf16Count).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = ns.substring(from: utf16Count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard SentenceBoundary.hasSemanticContent(piece) else {
            pending = remainder
            return []
        }

        let ratio = min(1, max(0, Double(utf16Count) / Double(total)))
        let commitEnd = utf16Count == total ? pendingEnd : pendingStart + (pendingEnd-pendingStart)*ratio
        let existingID = draftID
        let oldDraft = rows.first(where: { $0.id == existingID && !$0.isFinal })
        let id = existingID ?? UUID()
        if let existingID { rows.removeAll { $0.id == existingID && !$0.isFinal } }
        draftID = nil

        var row = Caption(id: id, captureID: captureID, language: language, source: piece,
            tokens: [], start: pendingStart, end: commitEnd, isFinal: true,
            revision: (oldDraft?.revision ?? 0)+1, speaker: pendingSpeaker)
        if let oldDraft {
            row.gutterHint = oldDraft.gutterHint
            // A draft translation for a longer rolling sentence is not valid for a prefix.
            if oldDraft.source == piece {
                row.translation = oldDraft.translation
                row.tokens = oldDraft.tokens
            }
        }
        rows.append(row)

        pending = remainder
        if pending.isEmpty {
            pendingStart = 0; pendingEnd = 0; pendingSpeaker = nil
        } else {
            pendingStart = commitEnd
            // The original speaker attribution remains valid only if it was unambiguous.
        }
        if !pending.isEmpty || !volatile.isEmpty { refreshDraft() }
        return [id]
    }
}
