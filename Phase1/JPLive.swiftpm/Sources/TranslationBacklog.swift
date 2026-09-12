import Foundation

// Inactive-language jobs never scan the entire transcript in the polling loop.
struct TranslationBacklog {
    private var jobs: [SourceLanguage: [UUID]] = [:]
    private var inFlight: Set<UUID> = []
    private var failures: [UUID: Int] = [:]
    private var eligibleAt: [UUID: Double] = [:]
    private var exhausted: [SourceLanguage: [UUID]] = [:]
    mutating func enqueue(_ ids: [UUID], language: SourceLanguage) {
        for id in ids where !inFlight.contains(id) && !(jobs[language] ?? []).contains(id)
            && !(exhausted[language] ?? []).contains(id) {
            jobs[language, default: []].append(id)
        }
    }
    mutating func take(language: SourceLanguage, now: Double = ProcessInfo.processInfo.systemUptime) -> UUID? {
        guard let index = jobs[language]?.firstIndex(where: { (eligibleAt[$0] ?? 0) <= now }) else { return nil }
        let id = jobs[language]!.remove(at: index)
        inFlight.insert(id)
        return id
    }
    mutating func restore(_ id: UUID, language: SourceLanguage) {
        inFlight.remove(id)
        if !(jobs[language] ?? []).contains(id) { jobs[language, default: []].insert(id, at: 0) }
    }
    // Initial attempt + at most two retries. Other rows may pass a delayed job.
    mutating func failed(_ id: UUID, language: SourceLanguage, now: Double) -> Bool {
        inFlight.remove(id)
        let count = (failures[id] ?? 0) + 1; failures[id] = count
        if count <= 2 {
            eligibleAt[id] = now + (count == 1 ? 1 : 3)
            enqueue([id], language: language)
            return true
        }
        eligibleAt[id] = nil
        if !(exhausted[language] ?? []).contains(id) { exhausted[language, default: []].append(id) }
        return false
    }
    mutating func complete(_ id: UUID) {
        inFlight.remove(id); failures[id] = nil; eligibleAt[id] = nil
    }
    func failedIDs(language: SourceLanguage) -> [UUID] { exhausted[language] ?? [] }
    mutating func retryFailed(language: SourceLanguage) -> [UUID] {
        let ids = exhausted.removeValue(forKey: language) ?? []
        for id in ids { failures[id] = nil; eligibleAt[id] = nil }
        enqueue(ids, language: language)
        return ids
    }
    func pending(language: SourceLanguage) -> [UUID] { jobs[language] ?? [] }
}
