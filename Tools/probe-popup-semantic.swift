import Foundation

@main
struct Probe {
    static func oldResolve(current: Caption, rows: [Caption]) -> Caption? {
        let semanticID = current.semanticID
        let group = rows.filter { $0.captureID == current.captureID && $0.semanticID == semanticID }
        guard !group.isEmpty else { return nil }
        let anchor = group.first(where: \.isSemanticSentenceAnchor) ?? group[0]
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
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        print("PASS \(name)")
    }
    static func main() {
        let oldCapture = UUID(), activeCapture = UUID()
        var all: [Caption] = []
        all.reserveCapacity(100_008)
        for i in 0..<100_000 {
            all.append(Caption(captureID: oldCapture, language: .japanese,
                               source: "old\(i)", start: Double(i), end: Double(i+1), isFinal: true))
        }
        let groupID = UUID()
        let p = ["前", "甲", "乙", "後"]
        for (i, text) in p.enumerated() {
            var row = Caption(captureID: activeCapture, language: .japanese, source: text,
                              start: Double(i), end: Double(i+1), isFinal: true)
            row.semanticSentenceID = groupID
            row.semanticSentenceSource = "前甲乙後"
            row.semanticSentenceStart = 0
            row.semanticSentenceEnd = 4
            row.semanticSentenceAnchor = i == 0
            all.append(row)
        }
        let tail = Caption(captureID: activeCapture, language: .japanese,
                           source: "次", start: 4, end: 5, isFinal: true)
        all.append(tail)
        let group = all[100_002]
        let old = oldResolve(current: group, rows: all)!
        let fresh = PopupSemanticSentence.resolve(current: group, rows: all, currentIndex: 100_002)!
        check(old.source == fresh.source && fresh.source == "前甲乙後", "full semantic source identical")
        check(old.id == fresh.id && fresh.id == groupID, "stable semantic identity")
        check(old.start == fresh.start && old.end == fresh.end, "semantic timeline unchanged")
        check(old.contextGroup == fresh.contextGroup, "learning context unchanged")
        check(old.isSemanticSentenceAnchor == fresh.isSemanticSentenceAnchor, "anchor unchanged")
        check(PopupSemanticSentence.resolve(current: group, rows: all, currentIndex: 99_999) == nil, "stale index rejected")
        check(PopupSemanticSentence.resolve(current: tail, rows: all, currentIndex: 100_004)?.source == "次", "adjacent sentence isolated")
        check(PopupSemanticSentence.resolve(current: all[50], rows: all, currentIndex: 50)?.source == "old50", "historical capture accessible")
        var missingAnchor = all
        missingAnchor[100_000].semanticSentenceAnchor = false
        let fallback = PopupSemanticSentence.resolve(current: missingAnchor[100_002], rows: missingAnchor, currentIndex: 100_002)
        check(fallback?.source == "前甲乙後", "fallback anchor selection unchanged")
        let joined = (0..<4).allSatisfy { offset in
            let idx = 100_000+offset
            let o = oldResolve(current: all[idx], rows: all)
            let n = PopupSemanticSentence.resolve(current: all[idx], rows: all, currentIndex: idx)
            return o?.source == n?.source && o?.contextGroup == n?.contextGroup
        }
        check(joined, "four visual rows produce identical logical sentence")
        func measure(_ body: () -> Void) -> Double {
            let s = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - s) * 1000
        }
        var checksum = 0
        let iterations = 300
        let oldMS = measure { for _ in 0..<iterations { checksum += oldResolve(current: group, rows: all)?.source.utf16.count ?? 0 } }
        let newMS = measure { for _ in 0..<iterations { checksum += PopupSemanticSentence.resolve(current: group, rows: all, currentIndex: 100_002)?.source.utf16.count ?? 0 } }
        check(checksum == 2*iterations*4, "benchmark outputs validated")
        print(String(format: "BENCHMARK 100000 historical captions, %d calls: old %.3f ms, new %.3f ms", iterations,oldMS,newMS))
    }
}
