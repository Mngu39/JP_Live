#!/usr/bin/env python3
"""Swift 6 executable seam probe against the actual AudioPreprocessor recovery methods.

Runs portable orchestration logic extracted *verbatim* from Shared/AudioPipeline.swift;
substitutes only AVFoundation/PCM and native SpeechAnalysisProvider. Not an Apple runtime test.
"""
from pathlib import Path
import subprocess, tempfile, shutil
ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT/'Shared/AudioPipeline.swift').read_text()

def extract_method(name):
    needle = '    private func '+name+'('
    assert SOURCE.count(needle) == 1, name
    start = SOURCE.index(needle)
    pos = SOURCE.index('{',start)
    depth = 0
    for i in range(pos,len(SOURCE)):
        if SOURCE[i] == '{': depth += 1
        elif SOURCE[i] == '}':
            depth -= 1
            if not depth: return SOURCE[start:i+1]
    raise AssertionError(name)

methods='\n\n'.join(extract_method(n) for n in ('requestAnalysisRecovery','beginAnalysisRecoveryIfNeeded','completeAnalysisRecovery'))
source = r'''import Foundation
protocol SpeechAnalysisProvider: Actor { func reset() async }

actor ResetGate {
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func entered() {
        started = true
        startWaiter?.resume(); startWaiter = nil
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in startWaiter = c }
    }
    func waitRelease() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in releaseWaiter = c }
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}
actor MockAnalysis: SpeechAnalysisProvider {
    private var resets = 0
    let gate: ResetGate?
    init(gate: ResetGate? = nil) { self.gate = gate }
    func reset() async {
        resets += 1
        if resets == 1, let gate {
            await gate.entered()
            await gate.waitRelease()
        }
    }
    func count() -> Int { resets }
}
actor AudioPreprocessor {
    private enum AnalysisRecoveryReason { case sourceBoundary, failure }
    private var analysis: (any SpeechAnalysisProvider)?
    private var analysisInput: AsyncStream<(Int,Double)>.Continuation?
    private var analysisGeneration = UUID()
    private var analysisTask: Task<Void, Never>?
    private var analysisRecoveryTask: Task<Void, Never>?
    private var analysisRecoveryPending: AnalysisRecoveryReason?
    private var analysisRecoveryToken: UUID?
    private var analysisRecoveryAttempts = 0
    private let maxAnalysisRecoveryAttempts = 2
    private var closed = false
    private var warnings: [String] = []
    private var starts = 0
    init(_ provider: (any SpeechAnalysisProvider)) { analysis = provider }
    private func warn(_ value: String) { if !warnings.contains(value) { warnings.append(value) } }
    private func startAnalysisStream(replayRecentPCM: Bool) async {
        starts += 1
        analysisGeneration = UUID()
        analysisTask = Task { }
    }
    func boundary() {
        requestAnalysisRecovery("source boundary", reason: .sourceBoundary)
        beginAnalysisRecoveryIfNeeded()
    }
    func failure() {
        requestAnalysisRecovery("native failure", reason: .failure)
        beginAnalysisRecoveryIfNeeded()
    }
    func settle() async {
        for _ in 0..<100000 {
            if analysisRecoveryTask == nil, analysisRecoveryPending == nil { return }
            await Task.yield()
        }
        preconditionFailure("Recovery failed to settle")
    }
    func state() -> (Int,Bool,Int) { (analysisRecoveryAttempts,analysis != nil, starts) }
    func staleToken() async {
        await completeAnalysisRecovery(token: UUID())
    }
    func stop() {
        closed = true
        analysisRecoveryToken = nil
        analysisRecoveryTask?.cancel(); analysisRecoveryTask = nil
    }
''' + methods + r'''
}
@main struct Main {
    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        print("PASS " + name)
    }
    static func main() async {
        let normal = MockAnalysis()
        let p = AudioPreprocessor(normal)
        for _ in 0..<5 { await p.boundary(); await p.settle() }
        let a = await p.state(), n = await normal.count()
        check(a.0 == 0 && a.1 && a.2 == 5 && n == 5, "five normal boundaries keep diarizer and zero error attempts")
        await p.failure(); await p.settle()
        let b = await p.state()
        check(b.0 == 1 && b.1, "first genuine error counted after normal boundaries")
        await p.failure(); await p.settle()
        let c = await p.state()
        check(c.0 == 2 && c.1, "second genuine error uses remaining retry")
        await p.failure(); await p.settle()
        let d = await p.state()
        check(d.0 == 2 && !d.1, "third genuine error disables diarizer")

        let gate = ResetGate(), delayed = MockAnalysis(gate: gate), q = AudioPreprocessor(delayed)
        await q.boundary(); await gate.waitStarted()
        await q.boundary(); await q.boundary()
        await gate.release(); await q.settle()
        let e = await q.state(), eCount = await delayed.count()
        check(e.0 == 0 && e.1 && e.2 == 1 && eCount == 2,
              "overlapping boundaries coalesce and do not install stale stream")

        let gate2 = ResetGate(), delayed2 = MockAnalysis(gate: gate2), r = AudioPreprocessor(delayed2)
        await r.boundary(); await gate2.waitStarted()
        await r.failure(); await gate2.release(); await r.settle()
        let f = await r.state(), fCount = await delayed2.count()
        check(f.0 == 1 && f.1 && f.2 == 1 && fCount == 2,
              "genuine error during normal boundary dominates pending reset")

        let gate3 = ResetGate(), delayed3 = MockAnalysis(gate: gate3), z = AudioPreprocessor(delayed3)
        await z.boundary(); await gate3.waitStarted()
        await z.staleToken()
        let before = await z.state()
        check(before.2 == 0, "stale token cannot publish a stream")
        await z.stop(); await gate3.release()
        for _ in 0..<500 { await Task.yield() }
        let after = await z.state()
        check(after.2 == 0, "stopped recovery cannot publish an obsolete stream")
    }
}
'''
assert shutil.which('swiftc'), 'Swift compiler unavailable'
with tempfile.TemporaryDirectory(prefix='jplive-recovery-') as folder:
    swiftfile=Path(folder)/'main.swift'; exe=Path(folder)/'probe'
    swiftfile.write_text(source)
    cmd=['swiftc','-parse-as-library','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',str(swiftfile),'-o',str(exe)]
    subprocess.run(cmd,check=True)
    subprocess.run([str(exe)],check=True)
