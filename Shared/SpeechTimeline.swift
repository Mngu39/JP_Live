import Foundation

// All times identify source audio, never the wall-clock arrival of an inference.
struct SpeechDecision: Sendable, Equatable {
    var speechProbability: Float
    var activeSpeakers: Int
    var start: Double
    var end: Double
    var speakerSlot: Int? = nil
    // Local diarizer identity namespace. It changes whenever recurrent diarizer state
    // is reset, so presentation mapping never treats a post-reset slot as the same
    // person merely because its numeric slot resembles an older one.
    var identityEpoch: Int = 0
    var isValid: Bool {
        start.isFinite && end.isFinite && end > start && speechProbability.isFinite
            && (0...1).contains(speechProbability) && activeSpeakers >= 0
    }
    func shifted(by origin: Double) -> SpeechDecision {
        var value = self; value.start += origin; value.end += origin; return value
    }
}


// Product-level two-speaker temporal stabilization for raw LS-EEND slot probabilities.
// Raw LS-EEND probabilities can flicker at 100 ms resolution; do not let a single frame
// create/erase a speaker or a transient third slot disable the two-speaker product path.
// This is intentionally independent of FluidAudio so the behavior is deterministic/testable.
struct SpeakerActivityStabilizer: Sendable {
    private(set) var active: [Bool]
    private var onsetStreak: [Int]
    private var offsetStreak: [Int]
    let onsetThreshold: Float
    let offsetThreshold: Float
    let onsetFrames: Int
    let offsetFrames: Int
    let maxReportedSpeakers: Int

    init(slotCount: Int,
         onsetThreshold: Float = 0.60,
         offsetThreshold: Float = 0.42,
         onsetFrames: Int = 2,
         offsetFrames: Int = 2,
         maxReportedSpeakers: Int = 2) {
        let count = max(0, slotCount)
        self.active = Array(repeating: false, count: count)
        self.onsetStreak = Array(repeating: 0, count: count)
        self.offsetStreak = Array(repeating: 0, count: count)
        self.onsetThreshold = onsetThreshold
        self.offsetThreshold = min(offsetThreshold, onsetThreshold)
        self.onsetFrames = max(1, onsetFrames)
        self.offsetFrames = max(1, offsetFrames)
        self.maxReportedSpeakers = max(1, maxReportedSpeakers)
    }

    mutating func reset() {
        active = Array(repeating: false, count: active.count)
        onsetStreak = Array(repeating: 0, count: active.count)
        offsetStreak = Array(repeating: 0, count: active.count)
    }

    mutating func classify(_ probabilities: [Float]) -> (activeSlots: [Int], speechProbability: Float, detectedSpeakerCount: Int) {
        guard probabilities.count == active.count,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return ([], 0, 0) }

        for index in probabilities.indices {
            let value = probabilities[index]
            if active[index] {
                onsetStreak[index] = 0
                if value <= offsetThreshold {
                    offsetStreak[index] += 1
                    if offsetStreak[index] >= offsetFrames {
                        active[index] = false
                        offsetStreak[index] = 0
                    }
                } else {
                    offsetStreak[index] = 0
                }
            } else {
                offsetStreak[index] = 0
                if value >= onsetThreshold {
                    onsetStreak[index] += 1
                    if onsetStreak[index] >= onsetFrames {
                        active[index] = true
                        onsetStreak[index] = 0
                    }
                } else {
                    onsetStreak[index] = 0
                }
            }
        }

        let slots = active.indices.filter { active[$0] }
            .sorted {
                if probabilities[$0] == probabilities[$1] { return $0 < $1 }
                return probabilities[$0] > probabilities[$1]
            }
        // Keep only the strongest local slot IDs for presentation, but never hide the
        // fact that hysteresis currently sees 3+ active speakers. Downstream separation
        // must reject that frame instead of mistaking it for a valid two-speaker overlap.
        let reported = Array(slots.prefix(maxReportedSpeakers))
        let stableProbability = slots.map { probabilities[$0] }.max() ?? 0
        return (reported, stableProbability, slots.count)
    }
}

struct OverlapEpisode: Sendable, Hashable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end-start) }
    var isValid: Bool { start.isFinite && end.isFinite && end > start }
}

// The numeric slot is not meaningful outside one diarizer identity epoch.
struct LaneSpeakerIdentity: Hashable, Sendable {
    let epoch: Int
    let slot: Int
}

struct SpeechTimeline: Sendable {
    private(set) var frames: [SpeechDecision] = []
    var latestEnd: Double? { frames.last?.end }
    // Covers delayed recognizer callbacks, while bounding per-capture history.
    private let retention: Double = 120
    private let tolerance: Double = 1.0 / 24000
    private struct Identity: Hashable {
        let epoch: Int
        let slot: Int
    }
    mutating func append(_ values: [SpeechDecision]) {
        for candidate in values where candidate.isValid {
            var value = candidate
            if let last = frames.last {
                // Recovery/backfill can restart the LS-EEND 100 ms grid at a different
                // phase. Keep the non-overlapping suffix instead of dropping the whole
                // partially-overlapping frame and creating a real coverage hole.
                if value.end <= last.end + tolerance { continue }
                if value.start < last.end - tolerance { value.start = last.end }
            }
            guard value.end > value.start else { continue }
            frames.append(value)
        }
        if let end = frames.last?.end { frames.removeAll { $0.end < end-retention } }
    }
    // Unknown gaps must remain unknown. A recent but different interval cannot fill them.
    func covering(start: Double, end: Double) -> [SpeechDecision]? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        var cursor = start
        var matches: [SpeechDecision] = []
        // Frames are appended in time order. Skip old history in logarithmic time;
        // late speaker annotation must not rescan 120 seconds for every caption.
        var low = 0, high = frames.count
        while low < high {
            let middle = low + (high-low)/2
            if frames[middle].end <= start+tolerance { low = middle+1 } else { high = middle }
        }
        for index in low..<frames.count {
            let frame = frames[index]
            if frame.start >= end-tolerance { break }
            if frame.start > cursor+tolerance { return nil }
            matches.append(frame); cursor = max(cursor, frame.end)
            if cursor >= end-tolerance { return matches }
        }
        return nil
    }
    func decision(start: Double, end: Double) -> SpeechDecision? {
        guard let values = covering(start: start, end: end), let first = values.first else { return nil }
        let sameIdentity = first.speakerSlot != nil && values.allSatisfy {
            $0.activeSpeakers == 1 && $0.speakerSlot == first.speakerSlot &&
            $0.identityEpoch == first.identityEpoch
        }
        return SpeechDecision(speechProbability: values.map(\.speechProbability).min() ?? 0,
            activeSpeakers: values.map(\.activeSpeakers).max() ?? 0, start: start, end: end,
            speakerSlot: sameIdentity ? first.speakerSlot : nil,
            identityEpoch: first.identityEpoch)
    }
    private func evidence(start: Double, end: Double) -> (speaker: Int?, confident: Double, overlap: Bool, epoch: Int?)? {
        guard let values = covering(start: start, end: end) else { return nil }
        var durations: [Identity: Double] = [:]
        var overlap = false
        var anyConfident = false
        for frame in values {
            let left = max(start, frame.start)
            let right = min(end, frame.end)
            let duration = max(0, right-left)
            guard duration > 0, frame.speechProbability >= 0.60 else { continue }
            anyConfident = true
            if frame.activeSpeakers >= 2 {
                overlap = true
                continue
            }
            if frame.activeSpeakers == 1, let slot = frame.speakerSlot {
                durations[Identity(epoch: frame.identityEpoch, slot: slot), default: 0] += duration
            }
        }
        guard anyConfident else { return (nil, 0, false, nil) }
        if overlap || durations.count != 1 {
            return (nil, durations.values.reduce(0, +), overlap, nil)
        }
        let pair = durations.first!
        return (pair.key.slot, pair.value, false, pair.key.epoch)
    }

    // Detect overlap on the authoritative GLOBAL diarization timeline first.
    // Callers may later intersect a confirmed episode with semantic rows, but the
    // minimum-duration decision must not be re-run per sentence or a real overlap
    // crossing an NLTokenizer boundary can disappear as two short fragments.
    // During live capture an episode is returned only after a non-overlap frame
    // closes it. Natural EOF may explicitly close the open tail.
    func overlapEpisodes(start: Double, end: Double, minimumDuration: Double = 0.28,
                         includeOpenTail: Bool = false) -> [OverlapEpisode] {
        guard start.isFinite, end.isFinite, end > start,
              minimumDuration.isFinite, minimumDuration > 0 else { return [] }
        var output: [OverlapEpisode] = []
        var episodeStart: Double?
        var episodeEnd: Double = 0
        func appendIfNeeded(_ s: Double?, _ e: Double) {
            guard let s, e-s >= minimumDuration else { return }
            output.append(.init(start: s, end: e))
        }

        // Do not require the *entire caption* to have continuous diarization. A gap in
        // unrelated non-overlap speech must not erase a later well-covered overlap episode.
        var low = 0, high = frames.count
        while low < high {
            let middle = low + (high-low)/2
            if frames[middle].end <= start+tolerance { low = middle+1 } else { high = middle }
        }
        for index in low..<frames.count {
            let frame = frames[index]
            if frame.start >= end-tolerance { break }
            let left = max(start, frame.start), right = min(end, frame.end)
            guard right > left else { continue }
            let overlapping = frame.activeSpeakers == 2 && frame.speechProbability >= 0.65
            if overlapping {
                if let current = episodeStart, left > episodeEnd+tolerance {
                    appendIfNeeded(current, episodeEnd)
                    episodeStart = left
                } else if episodeStart == nil {
                    episodeStart = left
                }
                episodeEnd = max(episodeEnd, right)
            } else if episodeStart != nil {
                appendIfNeeded(episodeStart, episodeEnd)
                episodeStart = nil; episodeEnd = 0
            }
        }
        if includeOpenTail { appendIfNeeded(episodeStart, episodeEnd) }
        return output
    }

    // A slot number is local to one diarizer identity epoch. Every consumer
    // that persists lane-to-speaker mapping must retain that epoch.
    func confidentSingleSpeaker(start: Double, end: Double) -> (slot: Int, seconds: Double, epoch: Int)? {
        guard let value = evidence(start: start, end: end), !value.overlap,
              let slot = value.speaker, let epoch = value.epoch,
              value.confident > 0 else { return nil }
        return (slot, value.confident, epoch)
    }

    func speakerSpans(for timedText: [TimedTextSpan]) -> [SpeakerSpan] {
        timedText.compactMap { textSpan in
            guard textSpan.isValid,
                  let value = evidence(start: textSpan.start, end: textSpan.end),
                  value.confident > 0 || value.overlap else { return nil }
            return SpeakerSpan(
                utf16Start: textSpan.utf16Start,
                utf16End: textSpan.utf16End,
                start: textSpan.start,
                end: textSpan.end,
                speaker: value.speaker,
                confidentSpeech: value.confident,
                overlap: value.overlap,
                identityEpoch: value.epoch
            )
        }
    }

    func summarySpeaker(for spans: [SpeakerSpan]) -> Int? {
        guard !spans.isEmpty, !spans.contains(where: { $0.overlap }) else { return nil }
        let slots = Set(spans.compactMap(\.speaker))
        let epochs = Set(spans.map(\.identityEpoch))
        guard slots.count == 1, epochs.count == 1,
              spans.allSatisfy({ $0.speaker != nil }) else { return nil }
        return slots.first
    }

    func speaker(start: Double, end: Double) -> Int? {
        guard let value = evidence(start: start, end: end), !value.overlap else { return nil }
        return value.speaker
    }
    // A sentence row can legitimately span a speaker turn because NLTokenizer, not
    // diarization, owns sentence boundaries. Preserve that policy while still exposing
    // useful speaker evidence to the gutter instead of collapsing the whole row to gray.
    func hasMultipleSpeakersOrOverlap(start: Double, end: Double) -> Bool {
        guard let values = covering(start: start, end: end) else { return false }
        var identities = Set<Identity>()
        for frame in values where frame.speechProbability >= 0.60 {
            if frame.activeSpeakers >= 2 { return true }
            if frame.activeSpeakers == 1, let slot = frame.speakerSlot {
                identities.insert(Identity(epoch: frame.identityEpoch, slot: slot))
                if identities.count >= 2 { return true }
            }
        }
        return false
    }

    func activity(through end: Double) -> AudioActivity? {
        guard let last = frames.last(where: { $0.start < end && $0.end >= end-tolerance }) else { return nil }
        if last.speechProbability >= 0.65 { return AudioActivity(through: end, speaking: true, silence: 0) }
        guard last.speechProbability <= 0.35 && last.activeSpeakers == 0 else { return nil }
        var start = last.start
        for frame in frames.reversed() where frame.end <= last.start+tolerance {
            guard frame.end >= start-tolerance, frame.speechProbability <= 0.35, frame.activeSpeakers == 0 else { break }
            start = frame.start
        }
        return AudioActivity(through: end, speaking: false, silence: max(0, end-start))
    }
}

struct AudioActivity: Sendable {
    var through: Double
    var speaking: Bool
    var silence: Double
}

enum SpeakerGutterHint: String, Codable, Sendable {
    case neutral, first, second, mixed
}

// Presentation-only, per-capture state. At most one recent primary and one short
// auxiliary candidate/track; never a growing database of people or raw-slot colors.
struct SoftSpeakerMapper {
    mutating func hint(for row: Caption) -> SpeakerGutterHint {
        // Separator lane 0/1 is local to its interval, not a diarizer identity.
        if row.separationGroup != nil { return row.gutterHint }

        if !row.speakerSpans.isEmpty {
            let single = row.speakerSpans.filter { !$0.overlap && $0.speaker != nil }
            // Never train the same presentation track from two identity epochs in one row.
            if Set(single.map(\.identityEpoch)).count > 1 { return .mixed }
            for span in single {
                _ = hint(slot: span.speaker, start: span.start, end: span.end,
                         evidenceDuration: span.confidentSpeech)
            }
            let distinct = Set(single.compactMap(\.speaker))
            if row.speakerSpans.contains(where: { $0.overlap }) || distinct.count > 1 {
                return .mixed
            }
            if let slot = distinct.first { return resolvedHint(slot: slot) }
            return .neutral
        }
        return hint(slot: row.speaker, start: row.start, end: row.end,
                    evidenceDuration: max(0, row.end-row.start))
    }
    func resolvedHint(slot: Int?) -> SpeakerGutterHint {
        guard let slot,
              let primary, primary.confirmed,
              let auxiliary, auxiliary.confirmed else { return .neutral }
        if primary.slot == slot { return primary.tint }
        if auxiliary.slot == slot { return auxiliary.tint }
        return .neutral
    }
    private struct Track {
        var slot: Int
        var tint: SpeakerGutterHint
        var lastSeen: Double
        var speech: Double
        var observations: Int
        // Confirmation is based on actual confident speech time, not how NLTokenizer
        // happened to split that speech into rows.
        var confirmed: Bool { speech >= 1.2 }
        mutating func observe(end: Double, duration: Double) {
            guard duration > 0 else { return }
            lastSeen = max(lastSeen, end)
            speech = min(12, speech+duration)
            observations = min(2, observations+1)
        }
    }
    private struct EvidenceKey: Hashable {
        var slot: Int
        var startSample: Int64
        var endSample: Int64
    }
    private var primary: Track?
    private var auxiliary: Track?
    // A row may be shown before delayed diarization arrives, then revisited later.
    // Only successful speaker evidence is deduplicated; a prior nil/neutral lookup must
    // never consume the row's time range and prevent the late result from being learned.
    private var seenEvidence: Set<EvidenceKey> = []
    private var evidenceOrder: [EvidenceKey] = []

    mutating func hint(slot: Int?, start: Double, end: Double) -> SpeakerGutterHint {
        hint(slot: slot, start: start, end: end, evidenceDuration: max(0, end-start))
    }

    mutating func hint(slot: Int?, start: Double, end: Double,
                       evidenceDuration: Double) -> SpeakerGutterHint {
        guard start.isFinite, end.isFinite, end > start,
              evidenceDuration.isFinite, evidenceDuration >= 0 else { return .neutral }
        let referenceEnd = max(end, primary?.lastSeen ?? end, auxiliary?.lastSeen ?? end)
        if let value = primary, referenceEnd-value.lastSeen > 12 { primary = nil; auxiliary = nil }
        if let value = auxiliary, referenceEnd-value.lastSeen > (value.confirmed ? 6 : 3) { auxiliary = nil }
        guard let slot else { return .neutral }

        guard uniqueEvidence(slot: slot, start: start, end: end) else {
            return resolvedHint(slot: slot)
        }
        let duration = evidenceDuration
        if primary == nil {
            primary = Track(slot: slot, tint: .first, lastSeen: end, speech: duration,
                            observations: duration > 0 ? 1 : 0)
            return .neutral
        }
        if primary?.slot == slot {
            primary?.observe(end: end, duration: duration)
            return resolvedHint(slot: slot)
        }
        if auxiliary?.slot == slot {
            auxiliary?.observe(end: end, duration: duration)
            if auxiliary?.confirmed == true {
                let previous = primary
                primary = auxiliary
                auxiliary = previous?.confirmed == true ? previous : nil
            }
            return resolvedHint(slot: slot)
        }
        guard auxiliary?.confirmed != true else { return .neutral }
        auxiliary = Track(slot: slot, tint: primary?.tint == .first ? .second : .first,
                          lastSeen: end, speech: duration,
                          observations: duration > 0 ? 1 : 0)
        // One contiguous interval may already exceed the confidence threshold.
        // Requiring a second callback would make gutter colors depend on the
        // recognizer's arbitrary caption/chunk segmentation.
        return resolvedHint(slot: slot)
    }

    private mutating func uniqueEvidence(slot: Int, start: Double, end: Double) -> Bool {
        let key = EvidenceKey(slot: slot,
            startSample: Int64((start*48000).rounded()),
            endSample: Int64((end*48000).rounded()))
        guard seenEvidence.insert(key).inserted else { return false }
        evidenceOrder.append(key)
        if evidenceOrder.count > 128 {
            let removeCount = evidenceOrder.count-128
            let removed = Array(evidenceOrder.prefix(removeCount))
            evidenceOrder.removeFirst(removeCount)
            seenEvidence.subtract(removed)
        }
        return true
    }
}
