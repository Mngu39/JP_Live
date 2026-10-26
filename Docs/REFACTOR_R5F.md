# R5F — dormant Quality-STT / revision-path cleanup

Date: 2026-10-09 (Asia/Seoul)  
Base: `JP-Live-chat-stage8_9C_R5E-stop-report-doc-cleanup-20261009.zip`  
Mode: Chat-only source edit; **not** Xcode/device certified.

## Reason and exact boundary

The previous `AppModel.run` constructed a second `AudioPreprocessor` and `QualitySpeechPass`, ticked its dormant `revisionTranscript`, and exported quality-only diagnostics. **There was no call to `quality.offer(...)` in the live PCM loop.** The only remaining inline reference was an explanatory comment about Quality being on hold. The `TranscriptBuffer.resolveRevision` path rejected all corrections, so it could not modify Primary. As a result, this was dead code with additional complexity and stale diagnostics, not an active fallback.

## Deleted declarations and wiring

- Entire `QualitySpeechPass`/`QualityWorkLease` classes, their `QualitySpeechSink` adapter and `QualityAudioBudget`, Quality-only model preparation, idle second pipeline and unused buffer.
- `AppModel`’s `revisionTranscript`, `applyQualityRevisions`, `applyQualityCaption`, dormant result callback and quality tracing; Quality-only settings rows and JSON properties.
- Quality-only `AudioAnalysisDeliveryPolicy` and the branch waiting for optional analysis metadata in `AudioPreprocessor` (Primary always used the realtime policy). `drain(force:)` simplified to `drain()` because its sole former force-dependent branch was removed.
- `TranscriptBuffer.resolveRevision/applyRevision`, `TranscriptRevisionEffect/Resolution`, and **14** obsolete Quality-exclusive XCTest cases plus their `TestQualitySpeechSink` test double.
- Stale Quality references in comments, while preserving real Xcode model and resource references.

## Intentionally retained

Primary SpeechTranscriber callback queue, `Caption.revision` (used for UI state), `translationRevision` (translation session invalidation), overlap-only separation, full diarization/backfill/recovery, `OptionalProviderPreparation` (still used for live diarization), `AudioPreprocessor.setProviders` (covered by native tests), all shipped resources, and both Xcode project definitions.

## Compatibility caution

The live diagnostics JSON keys `quality`, `qualityRevisions` and `qualitySpeech` are removed. This is a deliberate **diagnostics schema change**; consumers of old JSON must tolerate missing keys. No migration of user data is needed because diagnostics are exported as an ephemeral snapshot, not a saved app database. Historical logs remain in `Docs/CHANGE_HISTORY.md` and were not modified.

## Validation boundary

Run Python repository/test guard, Swift source frontend parser, pure-core `-swift-version 6 -strict-concurrency=complete -warnings-as-errors` typecheck, Shared-to-Phase1 byte mirrors, SHA-256 manifest, and full+delta archive comparison. None of these compile `SwiftUI`, `AVFoundation`, `SpeechAnalyzer`, `ScreenCaptureKit` or execute physical iPad/Xcode tests on Linux. **Native XCTest must verify initialization, stop/EOF, translation, separation and diagnostic export before use.**

## Not removed

Resources, `Native/`, `Tools/`, `Phase1`, `Phase2`, generated resource recipes and Apple CI. Those can be runtime/build dependencies without direct Swift text references. Further removal requires Apple build checks.
