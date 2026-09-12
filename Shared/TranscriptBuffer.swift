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
    private var lastResultAt: Double = 0
    private var volatileUpdatedAt: Double = 0
    private var volatile = ""
    private var volatileStart: Double = 0
    private var volatileEnd: Double = 0
    private var volatileSpeaker: Int?
    mutating func begin(captureID: UUID, language: SourceLanguage) {
        self.captureID = captureID; self.language = language
        draftID = nil; pending = ""; volatile = ""
        pendingSpeaker = nil; volatileSpeaker = nil
    }
    mutating func receive(_ text: String, final: Bool, start: Double, end: Double,
                          speaker: Int?, now: Double) -> [UUID] {
        guard start.isFinite, end.isFinite, end >= start, now.isFinite else { return [] }
        if text.isEmpty {
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
        lastResultAt = now
        var ready: [UUID] = []
        if final {
            volatile = ""
            let pause = pending.isEmpty ? 0 : max(0, start-pendingEnd)
            let changedSpeaker = pendingSpeaker != nil && speaker != nil && pendingSpeaker != speaker && start >= pendingEnd-0.02
            if !pending.isEmpty && (changedSpeaker || ChunkBoundary.shouldCommit(pending, pause: pause,
                duration: pendingEnd-pendingStart, language: language)) { ready += commit() }
            if pending.isEmpty { pendingStart = start; pendingSpeaker = speaker }
            else if pendingSpeaker != speaker { pendingSpeaker = nil }
            pending = join(pending, text); pendingEnd = end
            if ChunkBoundary.shouldCommit(pending, pause: 0, duration: end-pendingStart, language: language) {
                ready += commit()
            } else { refreshDraft() }
        } else {
            volatile = text; volatileStart = start; volatileEnd = end; volatileSpeaker = speaker; volatileUpdatedAt = now
            refreshDraft()
        }
        return ready
    }
    mutating func tick(now: Double, activity: AudioActivity? = nil) -> [UUID] {
        guard !pending.isEmpty, now.isFinite else { return [] }
        // Maximum length/duration is a deliberate latency cap, not detected silence.
        let span = max(pendingEnd, volatile.isEmpty ? pendingEnd : volatileEnd)-pendingStart
        if span >= 9 || pending.utf16.count >= (language == .japanese ? 110 : 240) { return commit() }
        let matched = activity.flatMap { $0.through >= pendingEnd ? $0 : nil }
        if matched?.speaking == true { return [] }
        guard now-lastResultAt >= 0.35 else { return [] }
        if !volatile.isEmpty {
            // A still-changing continuation is not a pause. Only real silence can
            // release a stable prefix while retaining an old tentative tail.
            guard now-volatileUpdatedAt >= 1.2, let matched, !matched.speaking,
                  matched.through >= volatileEnd, matched.silence >= 1.2 else { return [] }
        }
        if let matched {
            return ChunkBoundary.shouldCommit(pending, pause: matched.silence,
                duration: pendingEnd-pendingStart, language: language) ? commit() : []
        }
        // No VAD available: recognizer-idle fallback, never advertised as VAD silence.
        return volatile.isEmpty && now-lastResultAt >= 1.2 ? commit() : []
    }
    mutating func finish() -> [UUID] {
        let ready = commit()
        if let id = draftID, let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].translationError = "인식 종료 · 미확정 원문"
        }
        draftID = nil; volatile = ""
        return ready
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
        var row = Caption(id: id, captureID: captureID, language: language, source: text,
            tokens: [],
            start: pending.isEmpty ? volatileStart : pendingStart,
            end: volatile.isEmpty ? pendingEnd : volatileEnd, isFinal: false,
            speaker: pending.isEmpty ? volatileSpeaker : (volatile.isEmpty || volatileSpeaker == pendingSpeaker ? pendingSpeaker : nil))
        row.revision = previous.map { rows[$0].revision + 1 } ?? 0
        if let previous, rows[previous].source == text { row.tokens = rows[previous].tokens }
        if let previous { rows[previous] = row } else { rows.append(row) }
    }
    private mutating func commit() -> [UUID] {
        guard !pending.isEmpty else { return [] }
        let existingID = draftID
        let oldRevision = rows.first(where: { $0.id == existingID })?.revision ?? 0
        if let existingID { rows.removeAll { $0.id == existingID } }
        draftID = nil
        var ready: [UUID] = []
        for (index, piece) in ChunkBoundary.split(pending, limit: language == .japanese ? 110 : 240).enumerated() {
            let id = index == 0 ? existingID ?? UUID() : UUID()
            let row = Caption(id: id, captureID: captureID, language: language, source: piece,
                tokens: [], start: pendingStart,
                end: pendingEnd, isFinal: true, revision: oldRevision+1, speaker: pendingSpeaker)
            rows.append(row); ready.append(id)
        }
        pending = ""; pendingSpeaker = nil
        if !volatile.isEmpty { refreshDraft() }
        return ready
    }
}
