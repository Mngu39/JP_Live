# R5L — P3 sentence-popup local semantic lookup

Date: 2026-10-12 (Asia/Seoul)
Base: `JP-Live-chat-stage8_9C_R5K-recovery-boundaries-20261012.zip`

## Problem
`PopupSemanticSentence.resolve(current:rows:)` used `rows.filter` to collect the single semantic sentence, touching every previously retained caption every time a sentence popup refreshed. Prior captures can remain in history. Its caller `AppModel.popupCaption()` already knows the selected row index.

## Correction
- New function `resolve(current:rows:currentIndex:)` validates the indexed row's id, captureID and semanticID, then scans adjacent rows matching `(captureID, semanticID)` in both directions. It uses the first semantic anchor in that group (or first row) and returns the same full semantic sentence identity/source/time/context.
- Production `AppModel.popupCaption` passes the verified index returned by its existing `captionIndex`.
- `TranscriptBuffer` appends each capture at the tail and `applySeparation` replaces one row with contiguous semantic fragments. The optimization relies on that production grouping invariant; it does not support arbitrarily interleaved groups with the same semantic ID, which the normal transcript flow never constructs.
- Added XCTest regression tests for old captions + separated group, stale index rejection, missing-anchor fallback, adjacent sentence isolation; updated pre-existing semantic-container XCTest to use the indexed API.
- Added portable Python source guards and `Tools/probe-popup-semantic.swift` for independently runnable equivalence/speed checks. Diagnostic settings provenance updated from stale R5G to R5L.

## Reproduction and performance
- Portable Swift exact-core probe, compiled with `swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors Shared/Core.swift Shared/SpeechTimeline.swift Shared/TranscriptBuffer.swift Tools/probe-popup-semantic.swift -o /tmp/popup-probe`.
- 11 direct assertions PASS; full source, semantic identity, original time bounds, context group, nonanchor visual fragment, fallback anchor, historical capture, stale index handling, adjacent groups.
- 100,000 historical captions + 4 semantic rows, 300 repeated sentence lookups: **old 198.781 ms**, **new 0.069 ms** in a Linux Swift process. This measures the lookup function only, not iPad UI response.
- Full Apple framework Swift typecheck, Xcode XCTest, real iPad STT/UI remain **not run**. Native Apple Stop nonreturning await is still open.

## Integrity
`Shared` / Phase1 mirrors maintained. Exact SHA-256 manifest and full/modified-only overlay comparison performed at packaging. See BUILD_REPORT_R5L.md for final checks.
