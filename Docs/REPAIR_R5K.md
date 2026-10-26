# R5K — diarizer recovery on audio source boundaries

Baseline: `JP-Live-chat-stage8_9C_R5J-capture-boundary-20261012.zip` (2026-10-12). Chat-only repair slice; source-level and portable tests, **not** an Apple/Xcode/device certification.

## Root cause

`AudioPreprocessor.requestAnalysisRecovery` previously used the same failure retry budget for a normal audio-source/format boundary and an actual failed/terminated analysis worker. The two allowed attempts were exhausted by routine discontinuities, permanently disabling diarization at the third boundary even when the model never failed.

## Changes

1. `AnalysisRecoveryReason` distinguishes `.sourceBoundary` from `.failure`. **Only actual analysis failures** consume the existing two-attempt budget. The bound is still enforced: a third actual failure disables analysis metadata, while Primary PCM remains live.
2. New source boundaries during a noncancelable reset are kept as a coalesced pending reason; actual errors take precedence. Once the previous reset finishes, the pending reason triggers another reset before a new worker stream is published. This avoids installing an obsolete post-boundary analysis stream.
3. An explicit `analysisRecoveryToken` stops callbacks from canceled/replaced recovery tasks from installing a stale stream or clearing a newer task. Provider replacement and Stop/Cancel invalidate the token.
4. Natural EOF drains chained recoveries under **one aggregate two-second deadline**, preserving bounded shutdown; an unresolved native recovery is invalidated without declaring success.
5. `maxAnalysisWait: Double = 2` is now explicitly declared. The identifier was referenced twice in R5J `AudioPipeline.swift` but not defined anywhere in the shipped source tree: Swift parsing alone did not catch this typechecking error.

No changes to Primary STT, translation, separation, speaker epoch mapping, or UI. The previously discovered popup lookup scaling problem **P3 remains open**.

## Evidence

- `python3 Tools/probe-analysis-recovery.py`: builds extracted **unaltered production method bodies** using Swift 6 strict concurrency, then tests 8 policy/state cases: five routine boundaries, first/second/third real failures, overlapping boundaries, failure during a pending boundary reset, stale token, and Stop invalidation. Actual AVFoundation/Core ML calls are substituted in this portable seam test.
- `Tests/test_analysis_recovery_policy.py`: source-wiring and mirror checks.
- `Tests/CoreTests.swift`: new Apple/Xcode-only integration regression `testR5KNormalAudioSourceBoundariesDoNotUseFailureBudget`, driving actual `AudioPreprocessor` with synthetic PCM and a deterministic analysis actor. **Authored but not executed on Linux.**
- Other repository regression tests, parse/typechecks, SHA manifest, and overlay comparison: see `BUILD_REPORT_R5K.md` accompanying the ZIP.

## Still not verified

Apple framework module-wide typecheck, Xcode/XCTest, actual live diarizer (Core ML) reset behavior, SideStore install/real-iPad use, native Stop non-return, and performance P3. Do not treat an executable policy probe as physical-device validation.
