import Foundation

// Keeps rolling recognizer state separate from UI geometry and the asynchronous recognizer.
// SpeechTranscriber final fragments are stable recognizer spans, not sentence boundaries.
// Keep their source-time identity until NaturalLanguage closes a sentence. Apple documents
// that a finalized range will not receive a later result; overlap reconciliation below is a
// defensive guard for duplicate/misaligned callbacks, not the assumed normal revision path.
struct TranscriptBuffer {
    private struct StableFragment {
        var text: String
        var start: Double
        var end: Double
        var speaker: Int?
    }

    var rows: [Caption] = []
    private var captureID = UUID()
    private var language: SourceLanguage = .japanese
    private var draftID: UUID?
    var draftRowID: UUID? { draftID }
    private var stable: [StableFragment] = []
    private var lastResultAt: Double = 0
    private var volatileUpdatedAt: Double = 0
    private var volatile = ""
    private var volatileStart: Double = 0
    private var volatileEnd: Double = 0
    private var volatileSpeaker: Int?
    private var displayStartsAt: Double = 0
    private let sourceSampleTolerance = 1.0 / 48000

    private var pending: String {
        stable.reduce("") { join($0, $1.text) }
    }
    private var pendingStart: Double { stable.first?.start ?? 0 }
    private var pendingEnd: Double { stable.last?.end ?? 0 }
    private var pendingSpeaker: Int? {
        guard let first = stable.first else { return nil }
        let slot = first.speaker
        return stable.allSatisfy { $0.speaker == slot } ? slot : nil
    }

    mutating func begin(captureID: UUID, language: SourceLanguage) {
        self.captureID = captureID; self.language = language
        displayStartsAt = 0
        resetChunkState()
    }

    // UI clear is intentionally independent from capture lifetime. The recognizer keeps
    // running; subsequent results start a fresh visible sentence in the same capture.
    mutating func clearDisplay(through time: Double? = nil) {
        if let time, time.isFinite { displayStartsAt = max(displayStartsAt, time) }
        rows.removeAll(keepingCapacity: true)
        resetChunkState()
    }

    private mutating func resetChunkState() {
        draftID = nil; stable.removeAll(keepingCapacity: true); volatile = ""
        volatileStart = 0; volatileEnd = 0
        volatileSpeaker = nil
        lastResultAt = 0; volatileUpdatedAt = 0
    }

    mutating func receive(_ text: String, final: Bool, start: Double, end: Double,
                          speaker: Int?, now: Double, finalizedThrough: Double? = nil) -> [UUID] {
        guard start.isFinite, end.isFinite, end >= start, now.isFinite else { return [] }
        // resultsFinalizationTime does NOT mean "discard older volatile text". Apple
        // explicitly allows a previously-volatile result to become final without sending
        // that same text again. If the incoming result is for a different range and the
        // frontier has passed our current volatile range, first promote that old hypothesis
        // into stable source-time state. An overlapping incoming result, including an empty
        // revocation, is allowed to replace/revoke it instead.
        let incomingSameStart = abs(start-volatileStart) <= sourceSampleTolerance
        let incomingOverlapsVolatile = !volatile.isEmpty && (incomingSameStart || (start < volatileEnd && end > volatileStart))
        var ready: [UUID] = []
        if !incomingOverlapsVolatile {
            ready += promoteFinalizedVolatileIfNeeded(finalizedThrough)
        }

        // A phrase crossing Clear cannot be safely sliced without token timestamps.
        // Discard that whole phrase, then resume at the next recognizer phrase.
        guard start >= displayStartsAt else { return ready }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Apple documents an empty volatile result as revocation of previous text for
            // this range. Revoke only the matching tentative hypothesis; stable/final text
            // is never deleted by an empty result from some other range.
            let sameStart = abs(start-volatileStart) <= sourceSampleTolerance
            let overlaps = start < volatileEnd && end > volatileStart
            if !volatile.isEmpty && (sameStart || overlaps) {
                volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
                lastResultAt = now
                refreshDraft()
            }
            return ready
        }

        // Punctuation-only noise must never become its own row. A final sentence mark may
        // decorate the most recent stable fragment and can then let NLTokenizer close it.
        if SentenceBoundary.isPunctuationOnly(trimmed) {
            lastResultAt = now
            guard final, !stable.isEmpty, trimmed.contains(where: { "。！？.!?…".contains($0) }) else { return ready }
            if let last = trimmed.last, stable[stable.count-1].text.last != last {
                stable[stable.count-1].text.append(last)
            }
            stable[stable.count-1].end = max(stable[stable.count-1].end, end)
            ready += commitCompletedSentences()
            if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
            return ready
        }

        lastResultAt = now
        if final {
            // A final result replaces the volatile hypothesis for the same source phrase,
            // but final itself does not mean "sentence complete".
            let sameStart = abs(start-volatileStart) <= sourceSampleTolerance
            let overlaps = start < volatileEnd && end > volatileStart
            if !volatile.isEmpty && (sameStart || overlaps) {
                volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
            }
            guard reconcileFinal(StableFragment(text: trimmed, start: start, end: end, speaker: speaker)) else {
                if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
                return ready
            }
            ready += commitCompletedSentences()
            if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
            return ready
        }

        volatile = trimmed; volatileStart = start; volatileEnd = end
        volatileSpeaker = speaker; volatileUpdatedAt = now
        refreshDraft()
        return ready
    }


    // A result can become final solely because the module's finalization frontier
    // advanced; Apple does not promise to resend unchanged text with isFinal == true.
    // Preserve that text and its source range. Revocation is signaled separately by an
    // empty result for the same range and is handled in receive(_:...).
    private mutating func promoteFinalizedVolatileIfNeeded(_ time: Double?) -> [UUID] {
        guard let time, time.isFinite, !volatile.isEmpty,
              volatileEnd <= time + sourceSampleTolerance else { return [] }
        let fragment = StableFragment(text: volatile, start: volatileStart, end: volatileEnd, speaker: volatileSpeaker)
        volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
        guard reconcileFinal(fragment) else {
            if !stable.isEmpty { refreshDraft() }
            else if draftID != nil { refreshDraft() }
            return []
        }
        let ready = commitCompletedSentences()
        if !stable.isEmpty { refreshDraft() }
        return ready
    }


    // Apple documents that an isFinal result will not receive a later result over its
    // range. Keep a defensive reconciliation path anyway so duplicate/misaligned stable
    // callbacks cannot create duplicated text. Without token-level timestamps, partial-
    // overlap surgery would be guesswork, so only full coverage may replace stable state.
    private mutating func reconcileFinal(_ next: StableFragment) -> Bool {
        // Never resurrect source time that has already been committed to visible history.
        if let committedEnd = rows.reversed().first(where: {
            $0.captureID == captureID && $0.isFinal
        })?.end, next.start < committedEnd - sourceSampleTolerance {
            return false
        }

        guard !stable.isEmpty else {
            stable = [next]
            return true
        }

        let overlapping = stable.indices.filter {
            let current = stable[$0]
            let sameStart = abs(current.start-next.start) <= sourceSampleTolerance
            return sameStart || (next.start < current.end && next.end > current.start)
        }
        if overlapping.isEmpty {
            // Results are expected in source order, but finalization can promote a prior
            // volatile phrase only after a later result arrives. Insert by source time so
            // that a delayed promotion can never be rendered as a trailing "ghost" token.
            let insertion = stable.firstIndex(where: { $0.start > next.start }) ?? stable.endIndex
            if insertion > 0 {
                guard stable[insertion-1].end <= next.start + sourceSampleTolerance else { return false }
            }
            if insertion < stable.endIndex {
                guard next.end <= stable[insertion].start + sourceSampleTolerance else { return false }
            }
            stable.insert(next, at: insertion)
            return true
        }

        guard let first = overlapping.first, let last = overlapping.last else { return false }
        let existingStart = stable[first].start
        let existingEnd = stable[last].end
        let coversExisting = next.start <= existingStart + sourceSampleTolerance &&
            next.end >= existingEnd - sourceSampleTolerance
        guard coversExisting else { return false }

        stable.replaceSubrange(first...last, with: [next])
        return true
    }

    mutating func tick(now: Double, activity: AudioActivity? = nil) -> [UUID] {
        let text = pending
        guard !text.isEmpty, now.isFinite else { return [] }

        // Normal sentence detection is text-based. These are only escape hatches for
        // punctuation-free speech or recognizer behavior that never yields an internal boundary.
        let span = max(pendingEnd, volatile.isEmpty ? pendingEnd : volatileEnd)-pendingStart
        if span >= SentenceBoundary.fallbackDuration ||
            text.utf16.count >= SentenceBoundary.fallbackCharacterLimit(language) {
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
        if let id = draftID, let index = rows.lastIndex(where: { $0.id == id && !$0.isFinal }) {
            rows[index].translationError = "인식 종료 · 미확정 원문"
        }
        volatile = ""; volatileSpeaker = nil
        return ready
    }

    // Diarization is allowed to arrive after STT. It annotates already-visible text and
    // never determines a sentence boundary.
    mutating func applySpeakerTimeline(_ timeline: SpeechTimeline) -> [UUID] {
        var changed: [UUID] = []
        for index in stable.indices {
            let fragment = stable[index]
            if timeline.decision(start: fragment.start, end: fragment.end) != nil {
                stable[index].speaker = timeline.speaker(start: fragment.start, end: fragment.end)
            }
        }
        if !volatile.isEmpty, timeline.decision(start: volatileStart, end: volatileEnd) != nil {
            volatileSpeaker = timeline.speaker(start: volatileStart, end: volatileEnd)
        }
        for index in rows.indices.reversed() {
            // Captures and their rows are chronological. Only the retained analysis
            // window can gain new attribution; older visible history stays untouched.
            guard rows[index].captureID == captureID else { break }
            if let first = timeline.frames.first, rows[index].end < first.start { break }
            guard rows[index].separationGroup == nil else { continue }
            guard timeline.decision(start: rows[index].start, end: rows[index].end) != nil else { continue }
            let slot = timeline.speaker(start: rows[index].start, end: rows[index].end)
            guard rows[index].speaker != slot else { continue }
            rows[index].speaker = slot; rows[index].revision += 1; changed.append(rows[index].id)
        }
        if draftID != nil { refreshDraft() }
        return Array(changed.reversed())
    }

    // Resolve a delayed quality-pass sentence against immutable primary history.
    // For this checkpoint, Primary source text wins on every textual disagreement.
    // Quality results are still tracked/pending so the surrounding lifecycle is testable,
    // but no source rewrite is allowed until a stronger consensus resolver is validated.
    mutating func resolveRevision(_ revised: Caption) -> TranscriptRevisionResolution {
        guard revised.isFinal, revised.captureID == captureID, revised.language == language,
              revised.start.isFinite, revised.end.isFinite, revised.start >= displayStartsAt,
              revised.end > revised.start, SentenceBoundary.hasSemanticContent(revised.source) else { return .rejected }
        var candidates: [Int] = []
        for index in rows.indices.reversed() {
            let row = rows[index]
            if row.captureID != captureID || row.end <= revised.start { break }
            if row.isFinal, row.language == language,
               min(row.end, revised.end) > max(row.start, revised.start) { candidates.append(index) }
        }
        candidates.reverse()

        guard let first = candidates.first, let last = candidates.last else {
            let latestPrimaryEnd = rows.reversed().first(where: {
                $0.captureID == captureID && $0.language == language && $0.isFinal
            })?.end ?? displayStartsAt
            return latestPrimaryEnd < revised.end - sourceSampleTolerance ? .pending : .rejected
        }
        guard candidates.allSatisfy({ rows[$0].separationGroup == nil }) else { return .rejected }
        let existingStart = rows[first].start
        let existingEnd = rows[last].end
        guard candidates == Array(first...last),
              abs(existingStart - revised.start) <= sourceSampleTolerance,
              abs(existingEnd - revised.end) <= sourceSampleTolerance else {
            return existingEnd < revised.end - sourceSampleTolerance ? .pending : .rejected
        }
        for pair in zip(candidates, candidates.dropFirst()) {
            guard abs(rows[pair.0].end - rows[pair.1].start) <= sourceSampleTolerance else { return .rejected }
        }

        // User policy for this checkpoint: when Primary and Quality differ, Primary wins.
        // Do not treat punctuation/spacing as semantically harmless (for example English
        // "well" vs "we'll" can collapse under punctuation-stripping heuristics). Until
        // the planned consensus resolver exists, Quality never rewrites Primary source text.
        // An identical result is already represented, so there is nothing to apply either.
        return .rejected
    }

    mutating func applyRevision(_ revised: Caption) -> TranscriptRevisionEffect? {
        if case .applied(let effect) = resolveRevision(revised) { return effect }
        return nil
    }

    // Replace a whole immutable request snapshot atomically. Neither a partial
    // stem nor results for text changed by quality/Clear may erase the original.
    mutating func applySeparation(original: Caption, separated: [Caption]) -> [UUID] {
        guard original.captureID == captureID, original.language == language,
              original.start >= displayStartsAt, original.isFinal,
              original.separationGroup == nil,
              let index = rows.lastIndex(where: { $0.id == original.id }),
              rows[index].captureID == original.captureID,
              rows[index].source == original.source,
              rows[index].start == original.start, rows[index].end == original.end,
              rows[index].separationGroup == nil, !separated.isEmpty else { return [] }
        let tolerance = 1.0 / 16000
        guard separated.allSatisfy({
            $0.isFinal && $0.language == language && $0.start.isFinite && $0.end.isFinite &&
            $0.start >= original.start - tolerance && $0.end <= original.end + tolerance &&
            $0.end > $0.start && ($0.speaker == 0 || $0.speaker == 1) &&
            SentenceBoundary.hasSemanticContent($0.source)
        }), Set(separated.compactMap(\.speaker)) == Set([0, 1]) else { return [] }
        var replacement = separated.sorted {
            $0.start == $1.start ? ($0.speaker ?? 0) < ($1.speaker ?? 0) : $0.start < $1.start
        }
        let group = UUID()
        for offset in replacement.indices {
            replacement[offset].id = offset == 0 ? original.id : UUID()
            replacement[offset].captureID = captureID
            replacement[offset].separationGroup = group
            replacement[offset].tokens = []; replacement[offset].translation = ""
            replacement[offset].translationError = nil
            replacement[offset].revision = rows[index].revision + 1
            replacement[offset].gutterHint = replacement[offset].speaker == 0 ? .first : .second
        }
        rows.replaceSubrange(index...index, with: replacement)
        return replacement.map(\.id)
    }

    private func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty, !second.isEmpty else { return first + second }
        let needsSpace = language == .english && first.last?.isWhitespace == false && second.first?.isWhitespace == false
        return first + (needsSpace ? " " : "") + second
    }

    private mutating func refreshDraft() {
        let stableText = pending
        let text = join(stableText, volatile)
        guard !text.isEmpty else {
            if let id = draftID, let index = rows.lastIndex(where: { $0.id == id && !$0.isFinal }) { rows.remove(at: index) }
            draftID = nil
            return
        }
        let id = draftID ?? UUID(); draftID = id
        let previous = rows.lastIndex { $0.id == id }
        let old = previous.map { rows[$0] }
        var row = Caption(id: id, captureID: captureID, language: language, source: text,
            tokens: [],
            start: stable.isEmpty ? volatileStart : pendingStart,
            end: volatile.isEmpty ? pendingEnd : volatileEnd, isFinal: false,
            speaker: stable.isEmpty ? volatileSpeaker : (volatile.isEmpty || volatileSpeaker == pendingSpeaker ? pendingSpeaker : nil))
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
        while true {
            let text = pending
            guard let length = SentenceBoundary.firstCompletedSentencePrefixUTF16Length(in: text, language: language),
                  length > 0, length <= text.utf16.count else { break }
            ready += commitPrefix(length)
            if stable.isEmpty { break }
        }
        return ready
    }

    private mutating func commitAllPending() -> [UUID] {
        let text = pending
        guard !text.isEmpty else { return [] }
        return commitPrefix(text.utf16.count)
    }

    private mutating func commitPrefix(_ utf16Count: Int) -> [UUID] {
        let original = pending
        guard utf16Count > 0, utf16Count <= original.utf16.count, !stable.isEmpty else { return [] }
        let ns = original as NSString
        let piece = ns.substring(to: utf16Count).trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSpeaker = pendingSpeaker
        let commitStart = pendingStart
        let commitEnd = consumeStablePrefix(utf16Count)
        guard SentenceBoundary.hasSemanticContent(piece) else {
            if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
            return []
        }

        let existingID = draftID
        let oldIndex = rows.lastIndex(where: { $0.id == existingID && !$0.isFinal })
        let oldDraft = oldIndex.map { rows[$0] }
        let id = existingID ?? UUID()
        if let oldIndex { rows.remove(at: oldIndex) }
        draftID = nil

        var row = Caption(id: id, captureID: captureID, language: language, source: piece,
            tokens: [], start: commitStart, end: commitEnd, isFinal: true,
            revision: (oldDraft?.revision ?? 0)+1, speaker: originalSpeaker)
        if let oldDraft {
            row.gutterHint = oldDraft.gutterHint
            // A draft translation for a longer rolling sentence is not valid for a prefix.
            if oldDraft.source == piece {
                row.translation = oldDraft.translation
                row.tokens = oldDraft.tokens
            }
        }
        rows.append(row)

        if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
        return [id]
    }

    // Consume a text prefix while preserving source-time fragments. Character-ratio timing
    // is used only inside the single recognizer fragment that the tokenizer cuts through;
    // whole preceding fragments retain their actual SpeechTranscriber result ranges.
    private mutating func consumeStablePrefix(_ utf16Count: Int) -> Double {
        var remaining = utf16Count
        var lastEnd = pendingStart
        let index = 0
        var previousText = ""

        while index < stable.count, remaining > 0 {
            var fragment = stable[index]
            let separator = join(previousText, fragment.text).utf16.count - previousText.utf16.count - fragment.text.utf16.count
            if separator > 0 {
                if remaining <= separator { break }
                remaining -= separator
            }
            let length = fragment.text.utf16.count
            if remaining >= length {
                remaining -= length
                lastEnd = fragment.end
                previousText = join(previousText, fragment.text)
                stable.remove(at: index)
                continue
            }

            let ns = fragment.text as NSString
            let consumed = max(0, min(remaining, length))
            let ratio = length == 0 ? 1 : Double(consumed) / Double(length)
            lastEnd = fragment.start + (fragment.end-fragment.start)*ratio
            let remainder = ns.substring(from: consumed).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                stable.remove(at: index)
            } else {
                fragment.text = remainder
                fragment.start = lastEnd
                stable[index] = fragment
            }
            remaining = 0
        }
        return lastEnd
    }
}
