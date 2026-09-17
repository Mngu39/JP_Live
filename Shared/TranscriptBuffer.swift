import Foundation

// Keeps phrase/chunk state separate from UI geometry and the asynchronous recognizer.
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
    private var pendingUpdatedAt: Double = 0
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
    // running; subsequent results start a fresh visible chunk in the same capture.
    mutating func clearDisplay() {
        rows.removeAll(keepingCapacity: true)
        resetChunkState()
    }

    private mutating func resetChunkState() {
        draftID = nil; pending = ""; volatile = ""
        pendingStart = 0; pendingEnd = 0; volatileStart = 0; volatileEnd = 0
        pendingSpeaker = nil; volatileSpeaker = nil
        pendingUpdatedAt = 0; lastResultAt = 0; volatileUpdatedAt = 0
    }

    mutating func receive(_ text: String, final: Bool, start: Double, end: Double,
                          speaker: Int?, now: Double) -> [UUID] {
        guard start.isFinite, end.isFinite, end >= start, now.isFinite else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // An empty result can revoke the current tentative phrase, including when
            // the recognizer finalizes that phrase as containing no speech. Never
            // erase a finalized prefix or an unrelated interval's tentative text.
            let sameStart = start == volatileStart
            let overlaps = start < volatileEnd && end > volatileStart
            if !volatile.isEmpty && (sameStart || overlaps) {
                volatile = ""; volatileSpeaker = nil; lastResultAt = now
                refreshDraft()
            }
            return []
        }

        // SpeechTranscriber can occasionally emit punctuation-only results for noise or
        // a revoked hypothesis. Never create a standalone caption such as ".". A final
        // punctuation-only result may decorate an already-open semantic prefix.
        if ChunkBoundary.isPunctuationOnly(trimmed) {
            lastResultAt = now
            if final, !pending.isEmpty, trimmed.contains(where: { "。！？.!?…".contains($0) }) {
                if let last = trimmed.last, pending.last != last { pending.append(last) }
                pendingEnd = max(pendingEnd, end); pendingUpdatedAt = now
                refreshDraft()
            }
            return []
        }

        lastResultAt = now
        var ready: [UUID] = []
        if final {
            volatile = ""
            let pause = pending.isEmpty ? 0 : max(0, start-pendingEnd)
            // A raw slot flip is not enough. Require a sustained new final phrase so a
            // short diarization wobble cannot fragment a broadcast into tiny rows.
            let sustainedSpeakerChange = pendingSpeaker != nil && speaker != nil && pendingSpeaker != speaker
                && start >= pendingEnd-0.02 && end-start >= 0.30
            let punctuationGrace = start >= pendingEnd-0.02 && ChunkBoundary.hasStrongEnding(pending)
                && now-pendingUpdatedAt >= ChunkBoundary.strongPause
            if !pending.isEmpty && (sustainedSpeakerChange || punctuationGrace || ChunkBoundary.shouldCommit(pending, pause: pause,
                duration: pendingEnd-pendingStart, language: language)) { ready += commit() }
            if pending.isEmpty { pendingStart = start; pendingSpeaker = speaker }
            else if pendingSpeaker != speaker, speaker != nil { pendingSpeaker = nil }
            pending = join(pending, text); pendingEnd = end; pendingUpdatedAt = now
            // Punctuation alone no longer seals a row. Hard duration/length caps still do.
            if ChunkBoundary.shouldCommit(pending, pause: 0, duration: end-pendingStart, language: language) {
                ready += commit()
            } else { refreshDraft() }
        } else {
            // If a new tentative phrase begins after a credible boundary, settle the
            // stable prefix first; otherwise keep it live as one growing broadcast row.
            let pause = pending.isEmpty ? 0 : max(0, start-pendingEnd)
            let punctuationGrace = start >= pendingEnd-0.02 && ChunkBoundary.hasStrongEnding(pending)
                && now-pendingUpdatedAt >= ChunkBoundary.strongPause
            if !pending.isEmpty && start >= pendingEnd-0.02 && (punctuationGrace || ChunkBoundary.shouldCommit(pending, pause: pause,
                duration: pendingEnd-pendingStart, language: language)) {
                ready += commit()
            }
            volatile = text; volatileStart = start; volatileEnd = end; volatileSpeaker = speaker; volatileUpdatedAt = now
            refreshDraft()
        }
        return ready
    }

    mutating func tick(now: Double, activity: AudioActivity? = nil) -> [UUID] {
        guard !pending.isEmpty, now.isFinite else { return [] }
        // Maximum length/duration is a deliberate latency cap, not detected silence.
        let span = max(pendingEnd, volatile.isEmpty ? pendingEnd : volatileEnd)-pendingStart
        if span >= ChunkBoundary.hardDuration || pending.utf16.count >= (language == .japanese ? 110 : 240) { return commit() }
        let matched = activity.flatMap { $0.through >= pendingEnd ? $0 : nil }
        let punctuationGrace = volatile.isEmpty && ChunkBoundary.hasStrongEnding(pending)
            && now-pendingUpdatedAt >= ChunkBoundary.strongPause
        if matched?.speaking == true && !punctuationGrace { return [] }
        guard now-lastResultAt >= 0.20 else { return [] }

        if !volatile.isEmpty {
            // A changing continuation is not a pause. If both recognizer and VAD have
            // gone quiet, only the stable prefix may settle; the tentative tail remains.
            guard now-volatileUpdatedAt >= ChunkBoundary.ordinaryPause, let matched, !matched.speaking,
                  matched.through >= volatileEnd, matched.silence >= ChunkBoundary.ordinaryPause else { return [] }
            return ChunkBoundary.shouldCommit(pending, pause: matched.silence,
                duration: pendingEnd-pendingStart, language: language) ? commit() : []
        }

        if punctuationGrace { return commit() }
        if let matched {
            return ChunkBoundary.shouldCommit(pending, pause: matched.silence,
                duration: pendingEnd-pendingStart, language: language) ? commit() : []
        }
        // No VAD evidence yet: recognizer-idle acts only as a bounded fallback and uses
        // the same adaptive thresholds, so punctuation settles quickly but a breath does not.
        let idle = now-lastResultAt
        return ChunkBoundary.shouldCommit(pending, pause: idle,
            duration: pendingEnd-pendingStart, language: language) ? commit() : []
    }

    mutating func finish() -> [UUID] {
        let ready = commit()
        if let id = draftID, let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].translationError = "인식 종료 · 미확정 원문"
        }
        draftID = nil; volatile = ""
        return ready
    }

    // Diarization is allowed to arrive after STT. Fill/refresh speaker metadata by the
    // source-audio interval without holding recognition audio for the classifier.
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
        // Keep the last translation on screen while the latest-wins request is in flight.
        // It is replaced atomically when translation for the new source returns.
        if let old {
            row.translation = old.translation
            row.translationError = old.translationError
            row.gutterHint = old.gutterHint
            if old.source == text { row.tokens = old.tokens }
        }
        if let previous { rows[previous] = row } else { rows.append(row) }
    }

    private mutating func commit() -> [UUID] {
        guard !pending.isEmpty, ChunkBoundary.hasSemanticContent(pending) else { return [] }
        let existingID = draftID
        let oldDraft = rows.first(where: { $0.id == existingID })
        let oldRevision = oldDraft?.revision ?? 0
        if let existingID { rows.removeAll { $0.id == existingID } }
        draftID = nil
        var ready: [UUID] = []
        for (index, piece) in ChunkBoundary.split(pending, limit: language == .japanese ? 110 : 240).enumerated() {
            guard ChunkBoundary.hasSemanticContent(piece) else { continue }
            let id = index == 0 ? existingID ?? UUID() : UUID()
            var row = Caption(id: id, captureID: captureID, language: language, source: piece,
                tokens: [], start: pendingStart,
                end: pendingEnd, isFinal: true, revision: oldRevision+1, speaker: pendingSpeaker)
            if index == 0, let oldDraft {
                row.translation = oldDraft.translation
                row.translationError = nil
                row.gutterHint = oldDraft.gutterHint
                if oldDraft.source == piece { row.tokens = oldDraft.tokens }
            }
            rows.append(row); ready.append(id)
        }
        pending = ""; pendingSpeaker = nil
        if !volatile.isEmpty { refreshDraft() }
        return ready
    }
}
