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
        var timedSpans: [TimedTextSpan] = []
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
    private var volatileTimedSpans: [TimedTextSpan] = []
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

    // Only the latest final rows of this capture affect the two-speaker gutter.
    // Rows are appended in capture order; separation replaces rows in place, and
    // a new capture retains but never interleaves the previous capture's rows.
    // Stop at the capture boundary even if fewer than `limit` final rows exist.
    // Otherwise every diarizer update in a new capture rescans all old captions.
    // Return ascending indices to preserve speakerHints' learning order.
    func recentFinalSpeakerRowIndices(captureID: UUID, minimumEnd: Double? = nil,
                                      limit: Int = 32) -> [Int] {
        guard limit > 0 else { return [] }
        var indices: [Int] = []
        indices.reserveCapacity(min(limit, rows.count))
        for index in rows.indices.reversed() {
            let row = rows[index]
            // A different capture marks the end of the contiguous current-capture
            // suffix. This must be a break, not a continue, to avoid scanning history.
            guard row.captureID == captureID else { break }
            guard row.isFinal else { continue }
            if let minimumEnd, row.end <= minimumEnd { continue }
            indices.append(index)
            if indices.count == limit { break }
        }
        indices.reverse()
        return indices
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
        volatileSpeaker = nil; volatileTimedSpans.removeAll(keepingCapacity: true)
        lastResultAt = 0; volatileUpdatedAt = 0
    }

    mutating func receive(_ text: String, final: Bool, start: Double, end: Double,
                          speaker: Int?, now: Double, finalizedThrough: Double? = nil,
                          timedSpans: [TimedTextSpan] = []) -> [UUID] {
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
                volatileTimedSpans.removeAll(keepingCapacity: true)
                lastResultAt = now
                refreshDraft()
            }
            return ready
        }

        // Punctuation-only noise must never become its own row. A final punctuation callback
        // may contain more than one character (for example `。」` or `！？`). Preserve the
        // complete suffix, removing only an already-present prefix of that punctuation run.
        if SentenceBoundary.isPunctuationOnly(trimmed) {
            lastResultAt = now
            guard final, trimmed.contains(where: { "。！？.!?…".contains($0) }) else { return ready }
            // A punctuation-only final may replace the same source-time range as
            // an already presented volatile hypothesis. Attach it to that newer
            // phrase first; otherwise punctuation migrates to the previous stable
            // sentence while the volatile word remains stranded as a draft.
            if incomingOverlapsVolatile {
                volatile = appendingPunctuation(trimmed, to: volatile)
                volatileEnd = max(volatileEnd, end)
                let fragment = StableFragment(text: volatile, start: volatileStart, end: volatileEnd,
                                              speaker: volatileSpeaker, timedSpans: volatileTimedSpans)
                volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
                volatileTimedSpans.removeAll(keepingCapacity: true)
                _ = reconcileFinal(fragment)
            } else if !stable.isEmpty {
                stable[stable.count-1].text = appendingPunctuation(trimmed, to: stable[stable.count-1].text)
                stable[stable.count-1].end = max(stable[stable.count-1].end, end)
            } else if !volatile.isEmpty {
                volatile = appendingPunctuation(trimmed, to: volatile)
                volatileEnd = max(volatileEnd, end)
                let fragment = StableFragment(text: volatile, start: volatileStart, end: volatileEnd,
                                              speaker: volatileSpeaker, timedSpans: volatileTimedSpans)
                volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
                volatileTimedSpans.removeAll(keepingCapacity: true)
                _ = reconcileFinal(fragment)
            } else {
                return ready
            }
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
                volatileTimedSpans.removeAll(keepingCapacity: true)
            }
            let validSpans = timedSpans.filter {
                $0.isValid && $0.utf16Start >= 0 && $0.utf16End <= trimmed.utf16.count
            }
            guard reconcileFinal(StableFragment(text: trimmed, start: start, end: end,
                                                speaker: speaker, timedSpans: validSpans)) else {
                if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
                return ready
            }
            ready += commitCompletedSentences()
            if !stable.isEmpty || !volatile.isEmpty { refreshDraft() }
            return ready
        }

        volatile = trimmed; volatileStart = start; volatileEnd = end
        volatileSpeaker = speaker
        volatileTimedSpans = timedSpans.filter {
            $0.isValid && $0.utf16Start >= 0 && $0.utf16End <= trimmed.utf16.count
        }
        volatileUpdatedAt = now
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
        let fragment = StableFragment(text: volatile, start: volatileStart, end: volatileEnd,
                                      speaker: volatileSpeaker, timedSpans: volatileTimedSpans)
        volatile = ""; volatileStart = 0; volatileEnd = 0; volatileSpeaker = nil
        volatileTimedSpans.removeAll(keepingCapacity: true)
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
        volatileTimedSpans.removeAll(keepingCapacity: true)
        return ready
    }

    // Diarization is allowed to arrive after STT. It annotates already-visible text and
    // never determines a sentence boundary.
    mutating func applySpeakerTimeline(_ timeline: SpeechTimeline) -> [UUID] {
        var changed: [UUID] = []
        // The unfinished sentence is already a visible row. refreshDraft() rebuilds
        // it from stable/volatile source and may change its speaker before the row
        // comparison below. Preserve its pre-update metadata so the caller receives
        // its ID when late diarization changes what the user can see.
        let previousDraft = draftID.flatMap { id in
            rows.first(where: { $0.id == id && $0.captureID == captureID && !$0.isFinal })
        }
        for index in stable.indices {
            let fragment = stable[index]
            if timeline.decision(start: fragment.start, end: fragment.end) != nil {
                stable[index].speaker = timeline.speaker(start: fragment.start, end: fragment.end)
            }
        }
        if !volatile.isEmpty, timeline.decision(start: volatileStart, end: volatileEnd) != nil {
            volatileSpeaker = timeline.speaker(start: volatileStart, end: volatileEnd)
        }
        if draftID != nil { refreshDraft() }

        for index in rows.indices.reversed() {
            guard rows[index].captureID == captureID else { break }
            if let first = timeline.frames.first, rows[index].end < first.start { break }
            guard rows[index].separationGroup == nil else { continue }

            let spans = rows[index].timedTextSpans.isEmpty
                ? []
                : timeline.speakerSpans(for: rows[index].timedTextSpans)
            let slot: Int?
            if !spans.isEmpty {
                slot = timeline.summarySpeaker(for: spans)
            } else {
                guard timeline.decision(start: rows[index].start, end: rows[index].end) != nil else { continue }
                slot = timeline.speaker(start: rows[index].start, end: rows[index].end)
            }

            guard rows[index].speaker != slot || rows[index].speakerSpans != spans else { continue }
            rows[index].speaker = slot
            rows[index].speakerSpans = spans
            rows[index].revision += 1
            changed.append(rows[index].id)
        }
        if let previousDraft,
           let updatedDraft = rows.first(where: { $0.id == previousDraft.id && !$0.isFinal }),
           (previousDraft.speaker != updatedDraft.speaker ||
            previousDraft.speakerSpans != updatedDraft.speakerSpans),
           !changed.contains(previousDraft.id) {
            // `changed` is assembled in reverse row order. The draft is the newest
            // row, so it must come first before we restore chronological order.
            changed.insert(previousDraft.id, at: 0)
        }
        return Array(changed.reversed())
    }

    // Replace only a text/time slice that Apple timing can prove belongs wholly to the
    // overlap. If a timed run straddles the overlap boundary, or the selected timed runs
    // contain an untimed UTF-16 hole, preserve Primary rather than guessing a character cut.
    mutating func applySeparation(original: Caption, target: OverlapEpisode, separated: [Caption]) -> [UUID] {
        guard original.captureID == captureID, original.language == language,
              original.start >= displayStartsAt, original.isFinal,
              original.separationGroup == nil, target.isValid,
              let index = rows.lastIndex(where: { $0.id == original.id }),
              rows[index].captureID == original.captureID,
              rows[index].source == original.source,
              rows[index].start == original.start, rows[index].end == original.end,
              rows[index].separationGroup == nil, !separated.isEmpty else { return [] }

        // Speaker/timing metadata may have been refreshed while the asynchronous separator
        // was running. Always slice the delivery-time row, never the schedule-time snapshot.
        let current = rows[index]
        let tolerance = 1.0 / 16000
        let intersecting = current.timedTextSpans.filter { span in
            span.isValid && min(span.end, target.end) > max(span.start, target.start)
        }
        guard !intersecting.isEmpty else { return [] }

        // A partially-intersecting Apple run cannot be split without inventing token timing.
        // A conservative rejection preserves all Primary text outside the proven overlap.
        guard intersecting.allSatisfy({
            $0.start >= target.start - tolerance && $0.end <= target.end + tolerance
        }) else { return [] }

        let spans = intersecting.sorted {
            if $0.utf16Start == $1.utf16Start { return $0.utf16End < $1.utf16End }
            return $0.utf16Start < $1.utf16Start
        }
        guard let first = spans.first, let last = spans.last,
              first.utf16Start >= 0, last.utf16End <= current.source.utf16.count else { return [] }

        // The text removed from Primary must be completely accounted for by Apple timed
        // runs. Reject gaps/overlaps instead of deleting untimed text between min/max spans.
        var cursor = first.utf16Start
        for span in spans {
            guard span.utf16Start == cursor, span.utf16End > span.utf16Start else { return [] }
            cursor = span.utf16End
        }
        let cutStart = first.utf16Start
        let cutEnd = cursor
        guard cutEnd > cutStart else { return [] }

        let replaceStart = spans.map(\.start).min() ?? target.start
        let replaceEnd = spans.map(\.end).max() ?? target.end
        guard replaceEnd > replaceStart else { return [] }

        // Separated text must stay inside the exact Primary text-time interval that will be
        // removed. Otherwise retained Primary and separated text can overlap in source time.
        guard separated.allSatisfy({
            $0.isFinal && $0.language == language && $0.start.isFinite && $0.end.isFinite &&
            $0.start >= replaceStart - tolerance && $0.end <= replaceEnd + tolerance &&
            $0.end > $0.start && ($0.separationLane == 0 || $0.separationLane == 1) &&
            SentenceBoundary.hasSemanticContent($0.source)
        }), Set(separated.compactMap(\.separationLane)) == Set([0, 1]) else { return [] }

        // Do not erase a longer Primary interval with separator rows that only cover a small
        // subrange. The union of accepted rows must cover the full replacement interval.
        let orderedRanges = separated.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        guard let firstRange = orderedRanges.first,
              firstRange.0 <= replaceStart + tolerance else { return [] }
        var coveredThrough = firstRange.1
        for range in orderedRanges.dropFirst() {
            guard range.0 <= coveredThrough + tolerance else { return [] }
            coveredThrough = max(coveredThrough, range.1)
        }
        guard coveredThrough >= replaceEnd - tolerance else { return [] }

        let ns = current.source as NSString
        func slice(_ range: NSRange, start: Double, end: Double) -> Caption? {
            guard range.length > 0, end > start else { return nil }
            let text = ns.substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var row = current
            row.id = UUID(); row.source = text; row.start = start; row.end = end
            row.translation = ""; row.translationError = nil; row.tokens = []
            row.separationGroup = nil; row.separationLane = nil
            row.timedTextSpans = current.timedTextSpans.compactMap { value in
                let a = max(value.utf16Start, range.location)
                let b = min(value.utf16End, range.location+range.length)
                guard b > a, value.end > start, value.start < end else { return nil }
                return TimedTextSpan(utf16Start: a-range.location, utf16End: b-range.location,
                                     start: max(value.start, start), end: min(value.end, end))
            }
            row.speakerSpans = current.speakerSpans.compactMap { value in
                let a = max(value.utf16Start, range.location)
                let b = min(value.utf16End, range.location+range.length)
                guard b > a, value.end > start, value.start < end else { return nil }
                return SpeakerSpan(utf16Start: a-range.location, utf16End: b-range.location,
                                   start: max(value.start, start), end: min(value.end, end),
                                   speaker: value.speaker,
                                   confidentSpeech: min(value.confidentSpeech, max(0, min(value.end,end)-max(value.start,start))),
                                   overlap: value.overlap, identityEpoch: value.identityEpoch)
            }
            let slots = Set(row.speakerSpans.compactMap(\.speaker))
            let epochs = Set(row.speakerSpans.map(\.identityEpoch))
            row.speaker = slots.count == 1 && epochs.count == 1 &&
                !row.speakerSpans.contains(where: { $0.overlap }) ? slots.first : nil
            return row
        }

        var replacement: [Caption] = []
        if cutStart > 0, let prefix = slice(NSRange(location: 0, length: cutStart),
                                           start: current.start, end: replaceStart) {
            replacement.append(prefix)
        }
        let group = UUID()
        for var row in separated.sorted(by: {
            if $0.start == $1.start { return ($0.separationLane ?? 0) < ($1.separationLane ?? 0) }
            return $0.start < $1.start
        }) {
            row.id = UUID(); row.captureID = captureID; row.separationGroup = group
            row.tokens = []; row.translation = ""; row.translationError = nil
            row.revision = current.revision + 1
            // An unmapped local lane must never masquerade as global teal/orange.
            row.gutterHint = row.speaker == nil ? .mixed : .neutral
            replacement.append(row)
        }
        if cutEnd < ns.length,
           let suffix = slice(NSRange(location: cutEnd, length: ns.length-cutEnd),
                              start: replaceEnd, end: current.end) {
            replacement.append(suffix)
        }

        // Separation must not create punctuation-only captions. Preserve the marks by
        // attaching them to an adjacent semantic fragment in source order. This keeps
        // punctuation visible without sending "。" / "！？" rows through translation,
        // morphology, or sentence actions as if they were independent utterances.
        func prepend(_ punctuation: Caption, to input: Caption) -> Caption {
            var row = input
            let shift = punctuation.source.utf16.count
            row.source = punctuation.source + row.source
            row.start = min(punctuation.start, row.start)
            row.timedTextSpans = punctuation.timedTextSpans + row.timedTextSpans.map {
                TimedTextSpan(utf16Start: $0.utf16Start+shift, utf16End: $0.utf16End+shift,
                              start: $0.start, end: $0.end)
            }
            row.speakerSpans = punctuation.speakerSpans + row.speakerSpans.map {
                SpeakerSpan(utf16Start: $0.utf16Start+shift, utf16End: $0.utf16End+shift,
                            start: $0.start, end: $0.end, speaker: $0.speaker,
                            confidentSpeech: $0.confidentSpeech, overlap: $0.overlap,
                            identityEpoch: $0.identityEpoch)
            }
            return row
        }
        func append(_ punctuation: Caption, to input: Caption) -> Caption {
            var row = input
            let shift = row.source.utf16.count
            row.source += punctuation.source
            row.end = max(row.end, punctuation.end)
            row.timedTextSpans += punctuation.timedTextSpans.map {
                TimedTextSpan(utf16Start: $0.utf16Start+shift, utf16End: $0.utf16End+shift,
                              start: $0.start, end: $0.end)
            }
            row.speakerSpans += punctuation.speakerSpans.map {
                SpeakerSpan(utf16Start: $0.utf16Start+shift, utf16End: $0.utf16End+shift,
                            start: $0.start, end: $0.end, speaker: $0.speaker,
                            confidentSpeech: $0.confidentSpeech, overlap: $0.overlap,
                            identityEpoch: $0.identityEpoch)
            }
            return row
        }
        var normalized: [Caption] = []
        var leadingPunctuation: Caption?
        for row in replacement {
            let trimmed = row.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuationOnly = !trimmed.isEmpty && !SentenceBoundary.hasSemanticContent(trimmed)
            if punctuationOnly {
                if !normalized.isEmpty {
                    normalized[normalized.count-1] = append(row, to: normalized[normalized.count-1])
                } else if var combined = leadingPunctuation {
                    combined.source += row.source; combined.end = max(combined.end, row.end)
                    leadingPunctuation = combined
                } else {
                    leadingPunctuation = row
                }
            } else {
                var semantic = row
                if let pending = leadingPunctuation {
                    semantic = prepend(pending, to: semantic)
                    leadingPunctuation = nil
                }
                normalized.append(semantic)
            }
        }
        if let leadingPunctuation, !normalized.isEmpty {
            normalized[normalized.count-1] = append(leadingPunctuation, to: normalized[normalized.count-1])
        }
        replacement = normalized
        guard !replacement.isEmpty else { return [] }

        // Keep one semantic NLTokenizer sentence even though overlap separation needs
        // several visual rows. Re-use an existing sentence identity when this is a second
        // overlap replacement inside the same sentence; otherwise the original row ID is
        // the stable sentence identity. The original visible row ID also stays on the first
        // replacement so open sentence-level UI can resolve the new semantic container.
        let semanticID = current.semanticID
        replacement[0].id = original.id
        for i in replacement.indices {
            replacement[i].semanticSentenceID = semanticID
            replacement[i].semanticSentenceAnchor = false
            replacement[i].revision = current.revision + 1
        }
        rows.replaceSubrange(index...index, with: replacement)

        // A prior replacement may already have split this semantic sentence. Recompute
        // the logical sentence from every current visual segment, not just this target.
        let semanticIndices = rows.indices.filter { rows[$0].semanticID == semanticID }
        guard let anchorIndex = semanticIndices.first else { return [] }
        let semanticSource = semanticIndices.map { rows[$0].source }.joined()
        let semanticStart = semanticIndices.map { rows[$0].start }.min() ?? current.start
        let semanticEnd = semanticIndices.map { rows[$0].end }.max() ?? current.end
        for rowIndex in semanticIndices {
            rows[rowIndex].semanticSentenceID = semanticID
            rows[rowIndex].semanticSentenceSource = semanticSource
            rows[rowIndex].semanticSentenceStart = semanticStart
            rows[rowIndex].semanticSentenceEnd = semanticEnd
            rows[rowIndex].semanticSentenceAnchor = rowIndex == anchorIndex
            // Sentence translation is owned by the semantic anchor only. Any earlier
            // translation became stale as soon as separated text changed the sentence.
            rows[rowIndex].translation = ""
            rows[rowIndex].translationError = nil
            rows[rowIndex].revision = max(rows[rowIndex].revision, current.revision + 1)
        }
        return semanticIndices.map { rows[$0].id }
    }

    mutating func applySeparationLaneMapping(ids: [UUID], mapping: [Int: LaneSpeakerIdentity]) -> Bool {
        guard !ids.isEmpty, !mapping.isEmpty else { return false }
        let wanted = Set(ids)
        var changed = false
        for index in rows.indices where wanted.contains(rows[index].id) && rows[index].separationGroup != nil {
            guard let lane = rows[index].separationLane, let identity = mapping[lane] else { continue }
            rows[index].speaker = identity.slot
            rows[index].speakerSpans = rows[index].timedTextSpans.map {
                SpeakerSpan(utf16Start: $0.utf16Start, utf16End: $0.utf16End,
                            start: $0.start, end: $0.end, speaker: identity.slot,
                            confidentSpeech: $0.duration, overlap: true, identityEpoch: identity.epoch)
            }
            rows[index].gutterHint = .neutral
            rows[index].revision += 1
            changed = true
        }
        return changed
    }

    private func appendingPunctuation(_ punctuation: String, to text: String) -> String {
        let marks = Array(punctuation)
        guard !marks.isEmpty else { return text }
        let existing = Array(text)
        let maximum = min(existing.count, marks.count)
        var shared = 0
        if maximum > 0 {
            for length in stride(from: maximum, through: 1, by: -1) {
                if Array(existing.suffix(length)) == Array(marks.prefix(length)) {
                    shared = length
                    break
                }
            }
        }
        return text + String(marks.dropFirst(shared))
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
            timedTextSpans: draftTimedTextSpans(stableText: stableText),
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
        let rawPiece = ns.substring(to: utf16Count)
        let piece = rawPiece.trimmingCharacters(in: .whitespacesAndNewlines)
        // The rolling buffer may already contain the next speaker's unfinished text when
        // NLTokenizer seals only the leading sentence. Attribute the committed prefix from
        // the fragments it actually consumes, not from the whole pending buffer.
        let originalSpeaker = speakerForStablePrefix(utf16Count)
        // consumeStablePrefix mutates `stable`. The fallback start must belong to
        // the consumed prefix, never to the remaining sentence (or to zero at EOF).
        let originalStart = pendingStart
        let consumed = consumeStablePrefix(utf16Count)
        let leadingTrim = String(rawPiece.prefix { $0.isWhitespace }).utf16.count
        let pieceRange = NSRange(location: leadingTrim, length: piece.utf16.count)
        let rowSpans = consumed.spans.compactMap { value -> TimedTextSpan? in
            let a = max(value.utf16Start, pieceRange.location)
            let b = min(value.utf16End, pieceRange.location + pieceRange.length)
            guard b > a else { return nil }
            return TimedTextSpan(utf16Start: a-pieceRange.location, utf16End: b-pieceRange.location,
                                 start: value.start, end: value.end)
        }
        let commitStart = rowSpans.map(\.start).min() ?? originalStart
        let commitEnd = max(commitStart, rowSpans.map(\.end).max() ?? consumed.end)
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
            revision: (oldDraft?.revision ?? 0)+1, timedTextSpans: rowSpans,
            speaker: originalSpeaker)
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

    private func speakerForStablePrefix(_ utf16Count: Int) -> Int? {
        guard utf16Count > 0, !stable.isEmpty else { return nil }
        var remaining = utf16Count
        var previousText = ""
        var resolved: Int?
        var sawSemanticSpeaker = false
        for fragment in stable where remaining > 0 {
            let separator = join(previousText, fragment.text).utf16.count
                - previousText.utf16.count - fragment.text.utf16.count
            if separator > 0 {
                if remaining <= separator { break }
                remaining -= separator
            }
            let take = min(remaining, fragment.text.utf16.count)
            guard take > 0 else { continue }
            let consumed = (fragment.text as NSString).substring(to: take)
            if SentenceBoundary.hasSemanticContent(consumed) {
                guard let slot = fragment.speaker else { return nil }
                if let resolved, resolved != slot { return nil }
                resolved = slot; sawSemanticSpeaker = true
            }
            remaining -= take
            previousText = join(previousText, fragment.text)
        }
        return sawSemanticSpeaker ? resolved : nil
    }

    // Consume a text prefix while preserving Apple's per-run audioTimeRange data.
    // Timed runs own source-time attribution; proportional timing is only a fallback for
    // text Apple did not annotate.
    private mutating func consumeStablePrefix(_ utf16Count: Int) -> (end: Double, spans: [TimedTextSpan]) {
        var remaining = utf16Count
        var lastEnd = pendingStart
        let index = 0
        var previousText = ""
        var rowOffset = 0
        var consumedSpans: [TimedTextSpan] = []

        while index < stable.count, remaining > 0 {
            var fragment = stable[index]
            let separator = join(previousText, fragment.text).utf16.count
                - previousText.utf16.count - fragment.text.utf16.count
            if separator > 0 {
                if remaining <= separator { break }
                remaining -= separator
                rowOffset += separator
            }

            let length = fragment.text.utf16.count
            if remaining >= length {
                consumedSpans += fragment.timedSpans.filter(\.isValid).map {
                    $0.shiftedUTF16(by: rowOffset)
                }
                remaining -= length
                lastEnd = max(lastEnd, fragment.end)
                rowOffset += length
                previousText = join(previousText, fragment.text)
                stable.remove(at: index)
                continue
            }

            let ns = fragment.text as NSString
            let consumed = max(0, min(remaining, length))
            let localConsumedSpans = fragment.timedSpans.compactMap { span -> TimedTextSpan? in
                guard span.isValid, span.utf16Start < consumed else { return nil }
                var clipped = span
                clipped.utf16End = min(clipped.utf16End, consumed)
                return clipped.utf16End > clipped.utf16Start ? clipped : nil
            }
            consumedSpans += localConsumedSpans.map { $0.shiftedUTF16(by: rowOffset) }

            // If a sentence boundary falls inside one Apple timing run, preserve that same
            // coarse source-time run on both text pieces. Never consume the run from the
            // remainder or manufacture a character-ratio split.
            if let crossingEnd = fragment.timedSpans.filter({
                $0.isValid && $0.utf16Start < consumed && $0.utf16End > consumed
            }).map(\.end).max() {
                lastEnd = crossingEnd
            } else if let exact = localConsumedSpans.map(\.end).max() {
                lastEnd = exact
            } else {
                let ratio = length == 0 ? 1 : Double(consumed) / Double(length)
                lastEnd = fragment.start + (fragment.end-fragment.start)*ratio
            }

            let rawRemainder = ns.substring(from: consumed)
            let leadingRemoved = String(rawRemainder.prefix { $0.isWhitespace }).utf16.count
            let remainder = rawRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                stable.remove(at: index)
            } else {
                let rawRemainderOffset = consumed + leadingRemoved
                fragment.text = remainder
                fragment.timedSpans = fragment.timedSpans.compactMap { span in
                    guard span.isValid, span.utf16End > rawRemainderOffset else { return nil }
                    var shifted = span
                    shifted.utf16Start = max(span.utf16Start, rawRemainderOffset) - rawRemainderOffset
                    shifted.utf16End = span.utf16End - rawRemainderOffset
                    return shifted.isValid ? shifted : nil
                }
                fragment.start = fragment.timedSpans.map(\.start).min() ?? lastEnd
                stable[index] = fragment
            }
            remaining = 0
        }
        return (lastEnd, consumedSpans)
    }

    private func draftTimedTextSpans(stableText: String) -> [TimedTextSpan] {
        var result: [TimedTextSpan] = []
        var text = ""
        for fragment in stable {
            let joined = join(text, fragment.text)
            let offset = joined.utf16.count - fragment.text.utf16.count
            result += fragment.timedSpans.filter(\.isValid).map { $0.shiftedUTF16(by: offset) }
            text = joined
        }
        if !volatile.isEmpty {
            let joined = join(stableText, volatile)
            let offset = joined.utf16.count - volatile.utf16.count
            result += volatileTimedSpans.filter(\.isValid).map { $0.shiftedUTF16(by: offset) }
        }
        return result
    }
}
