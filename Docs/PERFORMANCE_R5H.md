# R5H — bounded recent-speaker presentation selection (2026-10-09)

**Baseline:** R5G full tree. P1-only production change; existing repair semantics are preserved.

## Before

`AppModel.refreshSpeakerPresentation()` filtered every `TranscriptBuffer.rows` index, then kept `.suffix(32)`. On long sessions the selection step was O(history length) per late diarizer update even when 32 recent final rows were sufficient.

## After

`TranscriptBuffer.recentFinalSpeakerRowIndices(captureID:minimumEnd:limit:)` walks backwards and stops after the latest 32 *eligible* final rows. It returns ascending indices, preserving the prior `filter(...).suffix(32)` speaker-mapper learning and recoloring order. Draft rows, rows from other captures, and rows at or before the epoch boundary are skipped exactly as before. This is a search-path optimization, not a change to how speaker identity is inferred.

Complexity for a run with 32 recent eligible final rows: approximately O(32 + ineligible tail) rather than O(entire history). The worst case is still O(history) when fewer than 32 eligible rows exist, which is required to preserve original behavior without adding an index cache or making assumptions about row ordering across capture/epoch boundaries.

## Regression evidence and limits

- Actual pure Swift Core / SpeechTimeline / TranscriptBuffer sources passed Swift 6 strict concurrency and warnings-as-errors typecheck.
- Standalone Swift 6 optimized executable compared old and new selection across 126 cases on 100,000 rows, covering mixed captures, draft rows, epoch cutoff and varying selection limits; all indices and ordering agreed.
- Under one Linux synthetic benchmark (100,000 rows, 240 repeats): old selection 1495.325 ms; bounded selection 0.037 ms. These are machine- and benchmark-specific; they are **not an iPad FPS or end-to-end STT latency estimate**.
- XCTest source regression uses the actual selector (native XCTest was not executed here).
- No change to `Caption.revision`, separation grouping, translation scheduling, native Stop, or actual diarizer inference.

**Still not verified:** Full macOS/Xcode compilation, Apple SDK/ScreenCaptureKit/FluidAudio execution, physical iPad behavior, and unbounded native Stop liveness.

> **Later update (R5J, 2026-10-12):** The remaining cross-capture worst-case history scan documented above is now addressed in `PERFORMANCE_R5J.md`. This R5H note is retained as historical design/benchmark evidence.
