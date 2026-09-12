import Foundation

// All times identify source audio, never the wall-clock arrival of an inference.
struct SpeechDecision: Sendable, Equatable {
    var speechProbability: Float
    var activeSpeakers: Int
    var start: Double
    var end: Double
    var speakerSlot: Int? = nil
    var isValid: Bool {
        start.isFinite && end.isFinite && end > start && speechProbability.isFinite
            && (0...1).contains(speechProbability) && activeSpeakers >= 0
    }
    func shifted(by origin: Double) -> SpeechDecision {
        var value = self; value.start += origin; value.end += origin; return value
    }
}

struct SpeechTimeline: Sendable {
    private(set) var frames: [SpeechDecision] = []
    // Covers delayed recognizer callbacks, while bounding per-capture history.
    private let retention: Double = 120
    private let tolerance: Double = 1.0 / 24000
    mutating func append(_ values: [SpeechDecision]) {
        for value in values where value.isValid {
            if let last = frames.last, value.start < last.end-tolerance { continue }
            frames.append(value)
        }
        if let end = frames.last?.end { frames.removeAll { $0.end < end-retention } }
    }
    // Unknown gaps must remain unknown. A recent but different interval cannot fill them.
    func covering(start: Double, end: Double) -> [SpeechDecision]? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        var cursor = start
        var matches: [SpeechDecision] = []
        for frame in frames where frame.end > start+tolerance && frame.start < end-tolerance {
            if frame.start > cursor+tolerance { return nil }
            matches.append(frame); cursor = max(cursor, frame.end)
            if cursor >= end-tolerance { return matches }
        }
        return nil
    }
    func decision(start: Double, end: Double) -> SpeechDecision? {
        guard let values = covering(start: start, end: end), let first = values.first else { return nil }
        let sameSlot = values.allSatisfy { $0.activeSpeakers == 1 && $0.speakerSlot == first.speakerSlot }
        return SpeechDecision(speechProbability: values.map(\.speechProbability).min() ?? 0,
            activeSpeakers: values.map(\.activeSpeakers).max() ?? 0, start: start, end: end,
            speakerSlot: sameSlot ? first.speakerSlot : nil)
    }
    func speaker(start: Double, end: Double) -> Int? {
        guard let values = covering(start: start, end: end), let slot = values.first?.speakerSlot,
              values.allSatisfy({ $0.activeSpeakers == 1 && $0.speechProbability >= 0.65 && $0.speakerSlot == slot })
        else { return nil }
        return slot
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
    case neutral, first, second
}

// Presentation-only, per-capture state. At most one recent primary and one short
// auxiliary candidate/track; never a growing database of people or raw-slot colors.
struct SoftSpeakerMapper {
    private struct Track {
        var slot: Int
        var tint: SpeakerGutterHint
        var lastSeen: Double
        var speech: Double
        var observations: Int
        var confirmed: Bool { observations >= 2 && speech >= 1.2 }
        mutating func observe(end: Double, duration: Double) {
            guard duration > 0 else { return }
            lastSeen = end; speech = min(12, speech+duration); observations = min(2, observations+1)
        }
    }
    private var primary: Track?
    private var auxiliary: Track?
    private var processedThrough: Double?
    mutating func hint(slot: Int?, start: Double, end: Double) -> SpeakerGutterHint {
        guard start.isFinite, end.isFinite, end > start,
              end >= (processedThrough ?? end) else { return .neutral }
        let duration = max(0, end-max(start, processedThrough ?? start))
        processedThrough = end
        if let value = primary, end-value.lastSeen > 12 { primary = nil; auxiliary = nil }
        if let value = auxiliary, end-value.lastSeen > (value.confirmed ? 6 : 3) { auxiliary = nil }
        guard let slot else { return .neutral }
        if primary == nil {
            guard duration > 0 else { return .neutral }
            primary = Track(slot: slot, tint: .first, lastSeen: end, speech: duration, observations: 1)
            return .neutral
        }
        if primary?.slot == slot {
            primary?.observe(end: end, duration: duration)
            return primary?.confirmed == true && auxiliary?.confirmed == true ? primary!.tint : .neutral
        }
        if auxiliary?.slot == slot {
            auxiliary?.observe(end: end, duration: duration)
            if auxiliary?.confirmed == true {
                // Recent returning speaker becomes primary, keeping the local pair's
                // previous tint. A one-off initial speaker is not retained as a person.
                let previous = primary
                primary = auxiliary
                auxiliary = previous?.confirmed == true ? previous : nil
                return auxiliary == nil ? .neutral : primary!.tint
            }
            return .neutral
        }
        // A third one-off voice cannot displace a live recent pair.
        guard auxiliary?.confirmed != true, duration > 0 else { return .neutral }
        auxiliary = Track(slot: slot, tint: primary?.tint == .first ? .second : .first,
            lastSeen: end, speech: duration, observations: 1)
        return .neutral
    }
}
