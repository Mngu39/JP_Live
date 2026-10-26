# R5J — capture-boundary speaker history optimization (2026-10-12)

**Base:** R5I full source ZIP. **Scope:** P2 only. No changes to speaker inference, diarizer/Primary STT, separation, native Stop, storage, or translation behavior.

## Problem and fix

`TranscriptBuffer.begin` deliberately retains past-capture captions for UI history. R5H's reverse selector stopped upon finding 32 eligible current-capture final rows, but skipped old-capture rows when fewer than 32 existed. Early in each new capture, `refreshSpeakerPresentation()` thus scanned the entire lifetime history on every diarizer update.

`TranscriptBuffer.recentFinalSpeakerRowIndices` now **breaks on the first different capture ID** and only then tests `isFinal` and `minimumEnd`. It still selects at most `limit` eligible rows and returns their indices in ascending order. The production invariant is that captions for each capture are contiguous: new captures append rows, separation replaces a current-capture row in place, and late results are guarded by capture identity. `clearDisplay` removes rows rather than interleaving captures. If a future feature deliberately interleaves capture rows, the optimization must be revisited.

## Validation and boundaries

- Actual Swift 6 compiled Core/SpeechTimeline/TranscriptBuffer execution: **150/150 exact result comparisons** against the previous complete filter, including 0/1/10/31/32/40 new-capture rows, trailing draft, `minimumEnd`, and varied limits.
- On one Linux test, 100,000 previous-capture rows with 0 current final rows: 1,000 calls took approximately **240 ms** using the old selector versus **3.2 ms** with R5J. Benchmark varies with hardware, compiler, and measurement; it is *not* an iPad end-to-end speed or FPS estimate.
- XCTest regression source added for the new-capture boundary and all selection filters; authored but **not executed** on Xcode.
- Python source guards assert the boundary break precedes the row validity/time filters and the Phase1 mirror matches Shared.

No Apple Xcode full build, XCTest, ScreenCaptureKit, SpeechAnalyzer, Core ML or actual iPad runtime was exercised. Existing native Stop nonreturning-await safety concern remains open.
