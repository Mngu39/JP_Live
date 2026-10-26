# JP_Live handoff — R5M (S1 screenshot source provenance / native verification pending)

**Active source baseline:** `JP-Live-chat-stage8_9C_R4B-validation-final-20261007.zip` → R5A → R5B → R5C → R5D → R5E → R5F → R5G → R5H → R5I repair slices.
The interrupted stage8.9D tree is not a source baseline. `Shared/` is canonical and `Phase1/JPLive.swiftpm/Sources/` contains byte-identical mirrors.

## Status — not a finished product or a full repair

The previous R4B ledger reports 37/37 **historical source-review items** closed. An independent review *after R4B* found **11 additional code/validation defects (F1–F11)**. Therefore the old 37/37 figure does **not** establish current source correctness, Apple/Xcode acceptance, or device readiness.

R5F follows R5E (Stop-error reporting and archival cleanup) and removes the unused Quality-STT/revision path. F1–F11 have source-level repair patches and portable/local checks, but native Apple framework compilation, XCTest, and iPad behavior are still **unverified**.

### Modified in R5A

- **F1** `TranscriptBuffer.commitPrefix`: source start fallback captured before mutating the rolling stable fragments.
- **F2** `SeparationAcceptance.clipped`: leading/trailing whitespace trims also clip and rebase the UTF-16 timed spans.
- **F10** punctuation-only final overlapping the newest volatile phrase: attach to that phrase rather than to the prior stable prefix. Disjoint punctuation behavior remains unchanged.
- Regression cases added in `Tests/CoreTests.swift` (native XCTest still requires Apple/Xcode). Local Linux Swift executable checks use exact `TranscriptBuffer`/`clipped` core code and pass; this is **not** an iPad execution claim.

### Modified in R5B

- **F3** popup morphology key no longer includes metadata-only row revision; semantic context changes can still refresh contextual meaning.
- **F4** word→sentence action changes the live sentence-mode state used by display, translation and save; one semantic sentence is reconstructed from all visual rows.
- **F5** speaker identity uses `(identityEpoch, speakerSlot)` across timeline aggregation, per-text spans, display and separation anchor decisions; old speaker spans remain decodable.
- Regression XCTest source and a standalone Linux pure-Swift executable probe cover the fixes (XCTest/SwiftUI execution still requires Apple/Xcode).

### Modified in R5C (Device Validation)
- **F6** entire-session STT timed-error counts survive the bounded 48-callback JSON text trace; no older failures are forgotten.
- **F7** timed runs require nondecreasing UTF-16 offsets *and* audio start/end ordering; reversed run timestamps fail.
- **F8** STT success requires recognized letters/digits rather than empty or punctuation-only callbacks; no-text sessions cannot PASS, and `notTested` checks cannot produce an overall PASS.
- **F9** restart PASS requires **both explicit user Stops**, chronological separate sessions, and clean reset/input evidence.
- **F11** natural EOF checks the late-ready diarizer mailbox *before* cancellation, installs ready analysis, and drains retained PCM. Manual Stop/error/cancellation skips this optional handoff.
- Shared pure Swift `DeviceValidationSpeechAudit` + invariants are called by Phase2 and exercised in a real Linux Swift executable. Apple/Xcode tests are provided as source but **not run**.
- Device Validation JSON schema changed from **9 to 10** with semantic-STT and invalid-timed callback counts. Recent raw STT text is still limited to 48 callbacks.

### Modified in R5D (capture switching)
- **C1 repair (source-level only):** `SystemAudioInput.selected` now serializes asynchronous picker transitions and aborts capture if the predecessor `stopCapture()` throws. `CaptureNativeStopLedger` prevents a new session from starting until native stops are confirmed; a failed stop may require fully restarting the app. The superseded-start branch and explicit Stop also mark unconfirmed native teardown. Portable Swift 6 policy tests passed; actual ScreenCaptureKit execution **has not** been run.

### Modified in R5E (Stop reporting and documentation consolidation)
- `CaptureStopFlight` makes user Stop and input-loop cleanup await the same native stop; the second caller cannot incorrectly return early while the first stop is pending. Portable Swift 6 concurrency test passed.
- `AudioInput.stopFailure` is `nil` for file/simulator inputs and set when `SystemAudioInput.stop()` receives a thrown `stopCapture()` error. `AppModel` does not convert such a failure into its normal “입력 중지” status.
- **Nonreturning native `await` still blocks Stop**; this patch does not invent a watchdog success. See [`Docs/NATIVE_STOP_AUDIT.md`](Docs/NATIVE_STOP_AUDIT.md).
- The previous five `JP_Live_CHAT_CHANGE_LEDGER...` and four `JP_Live_REPAIR...` root Markdown files are preserved verbatim with original content hashes in [`Docs/CHANGE_HISTORY.md`](Docs/CHANGE_HISTORY.md); their old root copies were removed. See [`Docs/REPOSITORY_AUDIT.md`](Docs/REPOSITORY_AUDIT.md) for retained paths and deferred source cleanup.

### Modified in R5F (live-only simplification)
- Removed the dormant `QualitySpeechPass`/`QualityWorkLease` runtime and its second `AudioPreprocessor`, `revisionTranscript`, inert quality-to-primary text resolver, quality-only settings/diagnostics and their 14 obsolete XCTest methods. The actual capture loop had **no `quality.offer` call**: a separate live Quality recognizer was never supplied any PCM.
- Preserved `Caption.revision`, translation revision tracking, speaker timeline, primary STT, overlap separation, Apple file/system audio inputs, and real model preparation. Source `Shared` and Phase1 mirrors remain identical.
- Exported `LivePipelineDiagnostics` no longer contains the old quality-only fields; downstream JSON consumers must account for the schema change. See [`Docs/REFACTOR_R5F.md`](Docs/REFACTOR_R5F.md).
- Portable/static tests are not a native Xcode build. No Apple-XCTest or iPad runtime success is claimed.

### Still open / not product-accepted
- Existing **Stop liveness** / Apple native cleanup upper bound is not proven; requires Apple testing and careful design.
- A nonreturning `stopCapture()` or Apple Speech cancel/finalize may still block Stop. Do **not** replace native completion with a naive timeout, declare the stream stopped, or permit another capture to start. R5D does not claim to solve this risk.
- **Do not infer that F1–F11 or product behavior passed native Xcode/iPad testing.** Local/pure Swift tests do not substitute for those runtime checks. Retest repaired paths after full Apple build.
- History Markdown consolidation is complete. The specifically unused Quality-STT path was removed in R5F based on call-path analysis; remaining source/resource deletion still requires a separate review and Apple verification.

### Modified in R5G (post-repair cross-review corrections)
- **C2:** confirm native teardown of a stream whose `startCapture()` was attempted but threw; retain the stream and fail closed if stop also fails.
- **C3:** coalesce every native `SCStream` Stop by stream identity, including screenshot-detach failure and user Stop; avoid redundant stops after confirmed success.
- **C4:** prevent cross-capture screenshots during historical-caption save by checking expected capture ID and input identity before/after the async screenshot.
- **C5:** keep diarizer epoch attached through separator anchor voting, initial lane assignment, late remapping and `SpeakerSpan` metadata.
- Native Apple SDK compilation/XCTest and iPad execution are still **not** claimed. See `Docs/REPAIR_R5G.md`. P1 is addressed in R5H.

### Modified in R5H (bounded speaker presentation)
- `AppModel.refreshSpeakerPresentation()` now selects recent final rows through a backwards bounded `TranscriptBuffer` helper rather than filtering all historical captions on every diarizer update.
- Same capture/epoch/`isFinal` predicate, same ascending processing order. Local 100,000-caption Swift equivalence test covers 126 cases. Details in `Docs/PERFORMANCE_R5H.md`.
- This does not resolve unbounded Apple native Stop, nor certify Xcode/physical-device behavior.

## Workflow (Chat only)

Future inspection, editing, regression tests, and file/document cleanup are performed in Chat, not Work. Use bounded coherent repair slices with a full-source ZIP plus repair notes and an exact SHA-256 manifest at each committed slice. Do not rewrite Apple tests as Linux PASS. User performs genuine macOS/Xcode and iPad runtime testing as available. The current R5K tree is a native-unverified repair build; it is **not** a deployable acceptance build.

## Repository sources / build

- `Shared/` — Swift source of record.
- `Phase1/JPLive.swiftpm/Sources/` — byte-for-byte mirrors of `Shared/` for Phase 1; changes to `Shared/` must be copied here.
- `Phase1/`, `Phase2/` — separate Xcode targets. **Do not delete project, scheme, SDK resource references, or Native/Tools assets by filename alone.**
- `Native/`, `Resources/`, `Tools/` — bundled resource preparation and Apple build scripts.
- `Tests/` — Swift/XCTest and portable Python tests.
- Phase 2 uses generated `BuildOutputs/` model and Sudachi artifacts, prepared by `Tools/test-apple.sh 2` on macOS/Xcode. They are intentionally *not* included as source binaries in this ZIP.

See `Docs/CHANGE_HISTORY.md` for preserved R1–R5D historical notes and `Docs/REPOSITORY_AUDIT.md` for source/reference cleanup. These records do **not** supersede this handoff. R5E–R5F notes are above.

### Modified in R5I (V1 native Stop reporting in Device Validation)
- `DeviceValidationController.run` now records `input.stopFailure` after shared `input.stop()` completion and before report finalization. This prevents `runtime_errors` and session overall PASS from hiding a returned native Stop failure.
- A PHASE2 XCTest case covers a otherwise-passing metric session, stop-failure injection, FAIL verdict, and deduplicated diagnostic errors. Portable source and Swift-method checks were also added. Details in `Docs/REPAIR_R5I.md`.
- Does not solve a native Apple `stopCapture`/SpeechAnalyzer await that never returns; no Xcode/XCTest or iPad execution has been performed.

### Modified in R5J (P2 new-capture speaker history optimization)
- `TranscriptBuffer.recentFinalSpeakerRowIndices` now stops on the first different-capture row when scanning the contiguous current-capture suffix, rather than scanning prior sessions when fewer than 32 current final rows exist. It retains the existing final/time predicates, ascending order, and limit semantics.
- Source invariant checked: `begin()` retains history, but every production new-capture append happens at the tail; separation replaces rows in place, and stale capture callbacks are gated before reaching the buffer.
- Linux Swift 6 exact-core old-vs-new comparisons: 150/150 PASS. Native XCTest is authored but not run. Full details: `Docs/PERFORMANCE_R5J.md`.
- **Pending:** unbounded native Apple Stop awaits, full Xcode compile/XCTest/physical-iPad validation. No device-level behavior is certified.

### Modified in R5K (R1 boundary-vs-failure diarizer recovery)
- Normal source/format discontinuities trigger diarizer reset/replay without charging the two-attempt **real error** retry budget. Third real analysis failure still disables diarization metadata.
- Coalesced boundary/failure requests during in-flight recovery, token-guarded completion and an aggregate 2-second EOF recovery deadline prevent stale stream installation and unbounded chained reset waits.
- Declared missing `maxAnalysisWait: Double = 2` referenced by R5J EOF code.
- Source-extracted portable Swift 6 policy checks: 8 PASS; Xcode-only live pipeline test source added but not executed here. See `Docs/REPAIR_R5K.md`.
- **Outstanding:** native Apple stop non-return; native Apple/Xcode/XCTest/iPad validation. P3 is addressed in R5L.


### Modified in R5L (P3 popup semantic lookup)
- `AppModel.popupCaption()` passes its validated `captionIndex` into `PopupSemanticSentence.resolve`; the latter checks row identity and scans only contiguous `(captureID, semanticID)` neighbors to find the sentence anchor.
- Preservation: same logical sentence source, anchor ID, start/end, learning context; historical capture captions remain accessible. Stale or wrong indices return nil rather than displaying another row.
- Portable Swift benchmark/probe `Tools/probe-popup-semantic.swift` and XCTest source cases cover the semantic grouping contract. Linux source-level typecheck and tests are **not** a full Apple typecheck or XCTest runtime result.
- Remaining: native Apple Stop nonreturning await and full Xcode/real-device validation. New P3 code has **not** been tested on an iPad.


### R5M (2026-10-14): S1 picker source mismatch guard
- `SystemAudioInput` tracks the first successfully enqueued PCM source time separately for each activated `SCStream`. New selection invalidates the old mark; queued old-stream callbacks are rejected by the existing stream ID check.
- The study-save screenshot call checks the full semantic sentence start against current stream's source-time start, in addition to existing AppModel capture UUID and input-instance checks, both before and after screenshot capture. If uncertain, only screenshot is omitted; the text save remains allowed.
- Device Validation's existing no-caption screenshot probe is unaffected.
- `Shared` and Phase1 mirrors were updated, regression policy tests added. Apple native clock equivalence and Xcode/iPad execution remain **unverified**. See `Docs/REPAIR_R5M.md`.
- The prior standalone report's claim of an evidence-backed 100% source audit has been **withdrawn**. Further end-to-end review is tracked by explicit subsystem/evidence, not an invented percentage.
