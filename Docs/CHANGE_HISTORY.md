# Historical development notes — archived, not current acceptance

Nine former top-level MD files are embedded in original byte sequence below. The `bytes` and SHA-256 fields allow exact extraction (including the final newline). Historical PASS claims do not establish Apple/Xcode/iPad acceptance. Use [`../HANDOFF.md`](../HANDOFF.md) for present status.

| Former filename | Original bytes | SHA-256 |
|---|---:|---|
| `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R1.md` | 1808 | `317d3900a17b978f32d840e9dfdf3aabe13db54947d59528fd48292bd165c00d` |
| `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R2.md` | 3850 | `492cef07d01a759ffd9f7d4a2e2e2d2a638fdf1741374cc40db352849e37282a` |
| `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R3.md` | 6506 | `fd74a5b650eb860ec7804c9acace38078a98d42a73eef3b685486fd06d2429a8` |
| `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4A.md` | 3951 | `0611b63adf538349fe8577138344ff4c0003d9c37b97be5b81ddefc995812aef` |
| `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4B.md` | 3274 | `6a6e1b5e2ebea29c27d54e7d001d1e13b5bba22048924dc4d71834a8d3d24148` |
| `JP_Live_REPAIR_R5A.md` | 3003 | `d20fb0516b3d0a3142efcd0e03a049bb7f69762af9f8ff220f4ab4c5e498de4a` |
| `JP_Live_REPAIR_R5B.md` | 2711 | `16fc68a64e48414df4a98673859781429ab30cc02a486424343215a61f14876c` |
| `JP_Live_REPAIR_R5C.md` | 3227 | `448ae60e97c6b52efce071e7f3ccb98512499f9373e4e4a492e8b4d1976dfebe` |
| `JP_Live_REPAIR_R5D.md` | 3035 | `6b9142a983a0480fc0b8b413035d885aec5335820aaf2b69d20091fbd373087c` |

---

## Begin original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R1.md` (1808 bytes)

# JP Live Chat Change Ledger — stage8.9C-R1

Date: 2026-10-04  
Baseline: `JP-Live-chat-stage8_9C-overlap-only-separation-20260928.zip`

## Scope

Fresh repair slice 1 from the trusted stage8.9C full tree. Interrupted stage8.9D implementation was not used.

## Fixed defects in this slice

1. Multi-character punctuation-only final callback loss (`trimmed.last`).
2. One Apple timing run crossing multiple semantic sentences loses timing / creates zero-duration next row.
3. Primary separation cut deletes non-overlap text when a timed run straddles the overlap boundary.
4. Primary separation `min...max` cut deletes untimed UTF-16 holes between selected timed runs.
5. Async separation rebuilds prefix/suffix from stale schedule-time speaker metadata.
6. Separated-STT clipping pulls context text into the overlap by clamping time only.
7. Replacement interval safety: separated rows must remain inside and cover the exact Primary timed interval removed.
8. Timed-span offsets are rebased after sentence-prefix whitespace trimming.

## Files changed

- `HANDOFF.md`
- `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R1.md`
- `Shared/Core.swift`
- `Shared/TranscriptBuffer.swift`
- `Shared/Separation.swift`
- matching Phase 1 mirrors
- `Tests/CoreTests.swift`
- `SHA256SUMS.txt` (regenerated at packaging)

## Explicitly deferred to later repair slices

Primary volatile debounce queueing; diarizer lifecycle/backfill/recovery; VAD offline bundle/preparation; speaker epoch reset; overlap closure/global episode scheduling; lane identity and VAD/text co-evidence; semantic sentence container preservation after separation; Stop/Clear/EOF liveness; popup stale state; production diagnostics/device-validation redesign.

## Validation

See `HANDOFF.md` R1 section. No Apple/Core ML runtime certification is claimed.


## End original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R1.md`

---

## Begin original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R2.md` (3850 bytes)

# JP Live Chat Change Ledger — stage8.9C-R2

Date: 2026-10-04  
Baseline: `JP-Live-chat-stage8_9C_R1-timing-lossless-20261004.zip`

## Scope

Repair slice 2, continuing only from R1, which itself was rebuilt from the trusted stage8.9C full tree. Interrupted stage8.9D implementation was not used.

## Fixed defects in this slice

1. Primary 150 ms debounce no longer has a one-slot state that can erase an earlier disjoint volatile source range. Disjoint hypotheses are retained in source order; finalization frontier promotes them in order, and EOF conservatively preserves all still-tentative text.
2. Diarizer recovery and manual pipeline cancellation no longer await a cancellation-insensitive native/Core ML analysis worker on the Primary PCM actor. Retiring workers are generation-invalidated and reaped asynchronously; natural EOF uses a bounded 2 s metadata drain instead of an unbounded join.
3. Global `speechTimeline` now accepts only authoritative `takeAnalysisUpdates()` data. Render-time `PCMChunk.decision` remains leveler metadata and can no longer race ahead of delayed backfill and make append-only history discard it.
4. Natural EOF performs one final prepared-diarizer mailbox handoff. A model that is already ready/pending is installed and ring PCM is backfilled even when there is no next PCM chunk.
5. Diarizer identity has an explicit recurrent-state `identityEpoch`. Recovery/reset renews the presentation mapper and preserves pre-epoch gutter rows instead of allowing the same real speaker to acquire the opposite tint from a new slot namespace.
6. PCM retained before late diarizer installation now survives source boundaries. Pre-boundary segments are archived, backfilled separately, and reset between discontinuous source-time segments instead of being discarded or time-compressed.
7. `SpeechTimeline.append` preserves the non-overlapping suffix of a recovery frame whose 100 ms grid partially overlaps the existing tail; it no longer drops the whole frame and creates a coverage hole.
8. Coarse Apple timing that spans a sequential A→B turn can use row-level multiple-speaker evidence even when `speakerSpans` contains a nil-speaker coarse span; the gutter no longer falls through to neutral solely because the span array is nonempty.
9. Stabilizer `speechProbability` now reflects hysteresis-active slots rather than a high raw probability from a slot that has not activated yet.
10. The stabilizer retains a raw hysteresis-active speaker count. 3+ active tracks may expose only two strongest local slot IDs for presentation, but `SpeechDecision.activeSpeakers` remains 3+, so downstream overlap/separation cannot mistake real 3-speaker evidence for a valid 2-speaker overlap.

## Files changed from R1

- `HANDOFF.md`
- `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R2.md`
- `Shared/AppModel.swift`
- `Shared/AudioPipeline.swift`
- `Shared/ModelAdapters.swift`
- `Shared/SpeechTimeline.swift`
- matching Phase 1 mirrors
- `Tests/CoreTests.swift`
- `SHA256SUMS.txt` (regenerated at packaging)

## Remaining audit inventory

19 of the original 37 repair items remain after R2. They are intentionally deferred: bundled/offline separator VAD and bounded preparation; lane identity and VAD/STT co-evidence/simultaneity; EOF multi-overlap stale-row orchestration; separator latest-timeline/late-remap; unfinished overlap closure/global episode extraction; punctuation-only separation remainder; overlap crossing semantic-row boundary; semantic sentence container preservation; Clear/separator generation timeout; stale popup/save state; and production diagnostics/device-validation false-positive redesign.

## Validation

Local validation proves repository/static/pure-core invariants only. Apple Speech, AVFoundation, FluidAudio/Core ML, Xcode XCTest, and physical-iPad runtime behavior are not claimed by this environment.


## End original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R2.md`

---

## Begin original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R3.md` (6506 bytes)

# JP Live Chat Change Ledger — stage8.9C-R3

Date: 2026-10-04  
Baseline: `JP-Live-chat-stage8_9C_R2-diarizer-lifecycle-20261004.zip`  
Trust rule: R2 descends from the trusted stage8.9C full tree. Interrupted stage8.9D implementation is not used.

## Scope

Repair slice 3 closes the separator-side VAD, overlap-episode scheduling, lane-identity, acceptance, EOF/Clear orchestration defects that remained after R2. It deliberately leaves the semantic-sentence container/UI-popup work and production validation/diagnostics redesign for the next slice.

## Closed in R3 — 11 inventory items

1. **Bundled/offline separator VAD.** Added a pinned Silero VAD Core ML staging/verification path (`FluidInference/silero-vad-coreml`, v6.2.1 compiled bundle) and changed `FluidStemSpeechDetector` to load the app-bundled `VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc` with `VadManager(config:vadModel:)`. There is no default `VadManager()` runtime-download fallback on this separator path.
2. **Lane mapping crosstalk guard.** Non-overlap lane→global-speaker votes now require VAD support on that lane, dominance over the opposite lane, and authoritative single-speaker diarization evidence.
3. **EOF multi-overlap stale-row orchestration.** `finish()` re-reads current transcript rows and current authoritative timeline after each completed replacement instead of iterating a frozen EOF snapshot.
4. **Delivery-time identity + late remap.** Initial lane mapping uses the newest authoritative timeline at delivery time. Unresolved separated rows retain local lanes/mixed presentation and can be remapped later when sufficient non-overlap evidence arrives.
5. **Bounded separator preparation.** The optional-job watchdog now starts before model/VAD preparation, so preparation no longer sits outside the live timeout window.
6. **Only closed live overlap episodes are scheduled.** An overlap tail still active at the newest frame is not treated as complete during live capture. Natural EOF may explicitly close the open tail.
7. **VAD↔timed-STT co-evidence and simultaneous support.** Each accepted lane must have enough intersection between its own VAD-positive intervals and its own timed STT; the two supported lanes must also have a real simultaneous interval. Sequential evidence no longer validates a two-speaker overlap replacement.
8. **Punctuation-only separation remainder.** Prefix/suffix punctuation created by overlap-only replacement is attached to an adjacent semantic fragment rather than emitted as its own translation/morphology/sentence-action row.
9. **Global overlap duration before semantic-row intersection.** Overlap episodes are duration-gated on the global authoritative timeline first, then intersected with NLTokenizer rows. A valid overlap crossing a sentence boundary no longer disappears as two sub-threshold row-local fragments.
10. **Clear generation isolation.** Clear immediately resets the new generation's busy/watchdog state. A cancellation-insensitive pre-Clear separator task cannot later timeout-close the fresh generation; late old results are generation-filtered.
11. **Separator lane evidence must be genuinely simultaneous.** Acceptance now rejects cases where lane 0 and lane 1 each have valid local evidence but never overlap in time.

## Additional non-inventory correction

- Updated the Settings source-version label from stale `chat-stage8.8-2026-09-28` to `chat-stage8.9C-R3-2026-10-04` so shared diagnostics no longer misidentify this tree.

## VAD asset/Phase 2 gate

- Added `Tools/vad_assets.py`, `Tools/prepare_vad_model.py`, `Tools/prepare-vad-macos.sh`, and `Tools/vad-requirements.txt`.
- Added `separatorVADModel` provenance/pinning to `DEPENDENCIES.json`.
- Phase 2 workflow prepares the exact VAD asset before Apple validation.
- `Tools/test-apple.sh 2` requires/verifies the VAD manifest before Xcode and re-verifies the VAD inside the built Release app bundle.
- Added the generated `BuildOutputs/VAD` folder reference to the Phase 2 app resources.
- The pinned FluidAudio revision's source exposes the synchronous preloaded-model initializer `VadManager(config:vadModel:)`; R3 uses that path rather than the async default initializer that invokes `ModelHub`.

## Regression coverage added

Swift/XCTest source now covers:

- VAD/text temporal co-evidence and two-lane simultaneity rejection;
- lane mapping rejection when the intended stem lacks dominance over crosstalk;
- live open-tail overlap rejection versus EOF closure;
- one global overlap surviving an NLTokenizer sentence boundary;
- punctuation-only suffix elimination after `applySeparation`.

Python/static tests now cover the exact VAD pin, no-default-downloader source policy, Phase 2 preparation/bundle verification wiring, and dependency metadata. The Python suite is 42 tests after R3.

A local executable pure-Swift probe additionally verifies live-open-tail/EOF overlap behavior, global sentence-boundary overlap detection, and punctuation-safe overlap replacement.

## Repair inventory after R3

R1 closed 8, R2 closed 10, and R3 closes 11 more: **29 / 37 closed, 8 remain**.

The remaining eight are intentionally not claimed fixed here:

1. semantic sentence container preservation across separated segments;
2. stale popup/save state after asynchronous transcript replacement;
3. production-orchestration Device Validation (original validation defect #10);
4. `two_speaker_slots` false-positive logic;
5. expected-overlap-window false-positive logic;
6. live-diarization continuity/coverage false-positive logic;
7. Apple timed-span validity/coverage validation;
8. contradictory/insufficient 3-speaker production-path regression contract plus the broader diagnostics evidence redesign needed to prove these conditions.

## Local validation

- Python unittest discovery: **42/42 PASS**.
- Python `compileall`: **PASS**.
- all repository shell scripts `bash -n`: **PASS**.
- workflow YAML parse: **PASS**.
- Phase 2 `project.pbxproj` `plutil -lint`: **PASS**.
- Swift frontend parse: **40/40 PASS**.
- pure-core Swift strict concurrency + warnings-as-errors typecheck (`Core.swift`, `SpeechTimeline.swift`, `TranscriptBuffer.swift`): **PASS**.
- Shared ↔ Phase1 mirrors for all R3-touched shared files: **PASS**.
- executable pure-Swift R3 policy probe: **PASS**.

Apple Speech/AVFoundation/FluidAudio/Core ML execution, Xcode XCTest, VAD model preparation itself, device build, and physical-iPad behavior are **not** claimed by this Linux/local validation boundary.


## End original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R3.md`

---

## Begin original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4A.md` (3951 bytes)

# JP Live Chat Change Ledger — stage8.9C-R4A

Date: 2026-10-07  
Baseline: `JP-Live-chat-stage8_9C_R3-separator-vad-overlap-20261004.zip`  
Trust rule: R3 descends from the trusted stage8.9C full tree. Interrupted stage8.9D implementation is not used.

## Scope

Repair slice 4A closes only the two deferred UI/semantic-lifecycle audit items. Production diagnostics and Device Validation redesign remain for R4B.

## Closed in R4A — 2 inventory items

1. **Semantic sentence container preservation across separated visual segments.**
   - `Caption` now carries optional semantic-sentence identity/source/start/end/anchor metadata.
   - `applySeparation` keeps all visual prefix/lane/suffix rows under one stable semantic sentence identity and recomputes the logical source after every later overlap replacement in the same sentence.
   - Only one semantic anchor owns sentence translation; translation uses the full logical semantic source rather than translating every separator fragment as an independent utterance.
   - Source and translation panes render/synchronize by semantic group ID. The source pane may still show multiple speaker/lane visual rows, while the translation pane shows the one sentence translation.
   - `contextGroup` now uses the semantic sentence identity so learning records from visual fragments remain tied to the same logical sentence.

2. **Stale popup/save state after asynchronous transcript replacement.**
   - Sentence popup resolves the current semantic sentence from the retained original/anchor ID, so a separation that occurs while the popup is open refreshes to the current logical source.
   - Word popup is stricter: its token offsets belong to one visual source row, so any replacement/source change invalidates the selection instead of silently saving stale text.
   - Popup morphology/translation work is keyed by current semantic source/revision and restarts when that source changes.
   - Save re-resolves the current caption both before and after asynchronous screenshot/translation work; if the transcript changed, save is rejected rather than mixing stale source with a current screenshot.
   - English word lookup context uses the full current semantic sentence source.

## Regression coverage

- XCTest source includes a semantic-container regression asserting one stable semantic ID/context group, one anchor, and one logical source across prefix + two separated lanes + suffix.
- Local executable pure-Swift probe verifies the same semantic-container invariant.
- Popup lifecycle is additionally guarded in source by current-row/source re-resolution on display and save; full SwiftUI interaction still requires Apple/Xcode execution.

## Repair inventory after R4A

R1 closed 8, R2 closed 10, R3 closed 11, and R4A closes 2 more: **31 / 37 closed, 6 remain**.

The remaining six are the production diagnostics/Device Validation redesign:

1. production-orchestration Device Validation;
2. `two_speaker_slots` false-positive logic;
3. expected-overlap-window false-positive logic;
4. live-diarization continuity/coverage false-positive logic;
5. Apple timed-span validity/coverage validation;
6. contradictory/insufficient 3-speaker production-path regression contract plus broader diagnostic evidence needed to prove these conditions.

## Local validation boundary

- Python unittest discovery: **42/42 PASS**.
- Python `compileall`: **PASS**.
- all repository shell scripts `bash -n`: **PASS**.
- workflow YAML parse: **PASS**.
- Swift frontend parse: **40/40 PASS**.
- pure-core Swift strict concurrency + warnings-as-errors typecheck (`Core.swift`, `SpeechTimeline.swift`, `TranscriptBuffer.swift`): **PASS**.
- Shared ↔ Phase1 mirrors for every R4A-touched shared file: **PASS**.
- executable pure-Swift semantic-container probe: **PASS**.

Apple Translation/Speech/SwiftUI runtime, Xcode XCTest/build, and physical-iPad behavior are not claimed by this Linux/local validation boundary.


## End original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4A.md`

---

## Begin original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4B.md` (3274 bytes)

# JP_Live chat change ledger — stage8.9C R4B

Base: `JP-Live-chat-stage8_9C_R4A-semantic-popup-20261007.zip`
Date: 2026-10-07
Scope: final diagnostics / Device Validation corrections. No stage8.9D implementation was used.

## Closed inventory (remaining 6 / total 37)

1. Production orchestration validation no longer relies only on isolated helper/unit seams. Device Validation now runs a deterministic contract through the actual production core types `LiveSeparationPass.target` → `SeparationAcceptance.accepted` → `TranscriptBuffer.applySeparation`, including semantic-sentence preservation. Physical SepFormer/CoreML execution remains a real-device/Xcode concern and is not fabricated in this environment.
2. `two_speaker_slots` no longer counts two numeric slots from different diarizer identity epochs as two people. PASS requires >=0.5 s stable single-speaker evidence for two distinct slots inside the same identity epoch.
3. `overlap_detected` no longer accepts an arbitrary overlap anywhere in the session. The Device Validation UI records an explicit expected-overlap source-time window with “겹쳐 말하기 시작/종료”; only overlap evidence inside that window can PASS.
4. `live_diarization` now checks temporal coverage (head lag, tail lag, and maximum internal analysis gap), so a diarizer that produces a few early frames and then dies cannot PASS.
5. Semantic Apple STT callbacks now require non-empty, valid, ordered timed spans with continuous UTF-16 text coverage. Text-only callbacks with broken/missing per-text timing cannot PASS `speech_timed_span_integrity`.
6. The 3-speaker safety test contract is connected end-to-end at the product decision seam: `SpeakerActivityStabilizer.detectedSpeakerCount == 3` is fed into `OverlapGate` and must be rejected. This prevents the old contradictory “cap to two” vs “reject three” isolated-test false confidence.

## Supporting diagnostics changes

- `DiarizationFrameTrace` now records `identityEpoch`.
- Device Validation tracks diarization first/last source time, maximum internal gap, per-epoch stable single-speaker duration, and explicit overlap-probe evidence.
- Device Validation report schema bumped from 8 to 9.
- Validation instructions/UI expose explicit overlap probe start/end controls.

## Verification performed in this environment

- Python asset/source tests: 42/42 PASS.
- Python compileall: PASS.
- All `Tools/*.sh`: `bash -n` PASS.
- Workflow YAML parse: PASS.
- Swift frontend parse over all Swift sources: PASS.
- Pure-core strict-concurrency + warnings-as-errors typecheck (`Core.swift`, `SpeechTimeline.swift`, `TranscriptBuffer.swift`): PASS.
- Shared/Phase1 mirrors for modified shared files: byte-identical PASS.
- SHA-256 manifest regenerated after R4B changes and verified before packaging.
- R4A + R4B modified-only overlay compared against R4B full tree before packaging.

## Not claimed

No claim is made here that Apple SpeechAnalyzer, FluidAudio, CoreML SepFormer, AVFoundation, ScreenCaptureKit, Xcode/XCTest, or a physical iPad executed successfully in this Linux/container environment. Those runtime checks remain real-device/Xcode checks. The 37-item source-review correction inventory is nevertheless closed at source/contract level by R1→R4B.


## End original: `JP_Live_CHAT_CHANGE_LEDGER_stage8_9C_R4B.md`

---

## Begin original: `JP_Live_REPAIR_R5A.md` (3003 bytes)

# JP_Live R5A — independent-audit repair slice 1

Baseline: R4B `JP-Live-chat-stage8_9C_R4B-validation-final-20261007.zip` (complete source, NOT stage8.9D).
Scope: fix **F1, F2, F10** without unrelated refactoring. Other defects remain open.

## Code changes

- `Shared/TranscriptBuffer.swift`: F1 fallback capture starts before `consumeStablePrefix` mutates `stable`; F10 overlapping punctuation-only final is attached first to the corresponding volatile text, then reconciled to stable. A non-overlapping punctuation callback continues to attach to the latest completed stable phrase.
- `Shared/Separation.swift`: F2 computes whitespace-trimmed UTF-16 range and intersects each timed span before rebasing offsets into the new `Caption.source`. Rejects rows with no remaining spans instead of retaining invalid pointers.
- Exact updated copies of these two files are maintained under `Phase1/JPLive.swiftpm/Sources/`.
- `Tests/CoreTests.swift`: targeted checks for F1 nonzero source time and EOF, F2 whitespace + multi-unit UTF-16, F10 direct core overlap + disjoint control, and an AppModel Primary queue async regression (Apple XCTest pending).

## Verification boundary

- Executable Swift 6 core harness using original `Core.swift`, `SpeechTimeline.swift`, `TranscriptBuffer.swift`: F1 and F10 PASS.
- Executable Swift 6 harness using **original extracted** `SeparationAcceptance.clipped()` body plus actual core types: F2 whitespace and Unicode UTF-16 PASS. Full Core ML dependent `Separation.swift` could not be compiled here.
- Swift parsing / strict pure-core typecheck / Python regressions / checksum verification are performed prior to packaging; final counts recorded in completion report.
- Apple platform SDK compile, XCTest, FluidAudio/Core ML, ScreenCaptureKit and physical iPad behavior: **NOT RUN**. A source regression test added does not mean its XCTest executed.

## Cleanup policy and completed items

- Removed versioned Python `__pycache__`/`.pyc` (generated, not imported source).
- Removed stale `Tests/static-review-results.json` (2026-09-21 historical build review) and `Tests/worker-contract-results.txt` (old test output); kept the **actual** worker contract test (`Tests/worker-contract.cjs`). No source/tool references to removed outputs.
- Added `.gitignore` for generated cache/build artifacts.
- Replaced stale R4B `HANDOFF.md` with this explicit open-defect handoff; refreshed `README.md`.
- **Deliberately not removed:** old R1–R4B MD historical change ledgers, Shared/Phase1 mirrors, Xcode project manifests, model/Native toolchain scripts, bundled JSON dictionaries. These are not automatically dead code; consolidate old ledgers only after the remaining repairs, and remove code/assets only after project-reference analysis and regression verification.

## Deferred

F3–F9 (excluding fixed F10), F11, C1; semantic popup / diarizer / Device Validation; test execution on Apple targets; final full unused code/files inventory and historical MD consolidation.


## End original: `JP_Live_REPAIR_R5A.md`

---

## Begin original: `JP_Live_REPAIR_R5B.md` (2711 bytes)

# JP_Live R5B — semantic popup and epoch-identity repair

Baseline: R5A `JP-Live-chat-stage8_9C_R5A-core-integrity-20261009.zip`. R4B/8.9D are **not** used as the direct source tree for R5B.

## Fixed in this slice

- **F3:** Popup morphology identity no longer depends on `Caption.revision`. Metadata-only speaker/translation updates preserve a selected word; real visual text/mode changes invalidate token offsets. English contextual meaning uses the full semantic source in its independent request identity.
- **F4:** `StudyPopup.sentenceView` is live state, initially copied from `PopupSelection.sentenceMode`. The word→sentence toolbar action sets it to true. All three `AppModel.popupCaption` callers (display/early save/late save) now use this state, and the logical sentence is resolved by production `PopupSemanticSentence.resolve` rather than using the single selected visual lane.
- **F5:** `SpeechTimeline` aggregates identities as `(identityEpoch, speakerSlot)` for coarse decision, single-speaker evidence, multi-speaker detection, and timed spans. `SpeakerSpan.identityEpoch` carries the epoch through existing UTF-16 slicing and punctuation shifts, and per-text summary/display decline to collapse two epochs with identical numeric slots. Legacy JSON speaker spans without this optional field still decode.

## Regression evidence

- Swift 6 local executable with unchanged project `Core.swift`, `SpeechTimeline.swift`, `TranscriptBuffer.swift`: **23/23 PASS** (source key behavior, actual separation to full semantic source + `SavePayload.make`, cross-epoch timing/spans/summary/gutter and same-epoch control, legacy speaker-span decode).
- `Tests/CoreTests.swift`: new native XCTest source tests for F3/F5; extended existing semantic separation test with F4 sentence-source/save assertions. **Not run** on this Linux host.
- SwiftUI `.task` lifecycle and native AppModel/UI integration require Apple/Xcode. Swift frontend parsing is not runtime UI validation.

## Cleanup/documentation

- `README.md` and `HANDOFF.md` updated to R5B. No unproven source, project references, Native dependencies or historical MD ledgers deleted in this functional repair slice.
- `Shared/` and exact `Phase1/JPLive.swiftpm/Sources/` mirrors retained. The full ZIP is the authoritative basis for the next Chat-only repair slice.

## Open items

- F6, F7, F8, F9, F11 (Device Validation); C1 conditional ScreenCaptureKit stop-error path; Apple native Stop liveness.
- Complete reference-based unused code/file review and historical Markdown consolidation after functional repairs.
- Apple SDK build, XCTest, Core ML/FluidAudio/ScreenCaptureKit and physical-iPad runs: NOT performed in local Linux validation.


## End original: `JP_Live_REPAIR_R5B.md`

---

## Begin original: `JP_Live_REPAIR_R5C.md` (3227 bytes)

# JP_Live — R5C Device Validation repair (Chat)

Date: 2026-10-09 (Asia/Seoul). Parent: **R5B full source ZIP**. R4B and interrupted 8.9D are not direct edit trees.

## Production changes

- **F6:** `Shared/Core.swift` adds monotonic `DeviceValidationSpeechAudit` recording every callback and timed-integrity failure. `DeviceValidationMetricStore` delegates to it, while retaining only 48 raw callbacks for diagnostics. Old failures cannot be evicted.
- **F7:** `DeviceValidationInvariants.validTimedSpeech` validates ordered UTF-16 runs with complete coverage and nondecreasing start/end audio times. No sorting masks out-of-order results.
- **F8:** a true recognized-speech callback must contain Unicode letters or digits. Punctuation-only and empty callbacks remain in raw counters but do not establish recognized STT. An absent recognized transcript yields WARNING; missing/invalid timing for a recognized transcript yields FAIL. `notTested` does not yield an overall session PASS.
- **F9:** `stop_restart` requires recorded manual Stop in **both** sessions, the second session to begin after the first ended, clean PCM/STT state with recognized speech and valid timing in both sessions with recognized speech and valid timing in both sessions, and fresh zero-based timestamps. Existing `userStopped` report fields are used; no invented native teardown confirmation.
- **F11:** Device Validation performs a final **nonwaiting** `takeReady()` handoff before `cancel()` for natural EOF only. When ready it installs diarization and drains retained source PCM. Manual Stop, failure, and canceled tasks skip the optional handoff. Does not wait for an unprepared/slow Core ML loader.
- `Phase2/DeviceValidationView.swift` instructs explicit manual stop twice and shows semantic/invalid counts.
- JSON schema version raised **9 → 10**, adding `semanticSpeechResults` and `invalidTimedSpeechResults`. No report-import migration implemented; these JSON reports are created/exported anew.

## Tests and limits

- Swift 6.2 Linux strict core typecheck and an **executable** pure-Swift probe exercise the exact production invariants/audit, including 56 callbacks with the first invalid, reverse audio times, punctuation-only callbacks, emoji UTF-16 and manual Stop/chronological restart policy.
- `Tests/CoreTests.swift` contains direct XCTest regressions through the production Device Validation metric store, restart report, plus a synthetic ready-at-EOF provider and `AudioPreprocessor` backfill case. These **have not been run with Apple/Xcode**.
- Portable repository Python tests, shell syntax, and Swift frontend parsing are useful but do **not** certify Apple frameworks, Xcode linking, ScreenCaptureKit, SwiftUI, Core ML, FluidAudio or physical iPad.

## Deliberate non-changes

- No R5A/R5B behavioral edits reverted. No new capture architecture or Third Speaker support.
- C1 `SCStream.stopCapture()` failure-before-restart remains unresolved, as does native Stop completion liveness.
- No source/model/project/old history files deleted without dependency analysis; full MD/source pruning waits until final stabilization.
- `Shared/` is canonical; touched Core.swift copied byte-identically to the Phase1 source mirror.


## End original: `JP_Live_REPAIR_R5C.md`

---

## Begin original: `JP_Live_REPAIR_R5D.md` (3035 bytes)

# JP_Live R5D — Capture selection safety (Chat)

Date: 2026-10-09 (Asia/Seoul). **Parent: R5C full-source ZIP.** This is a source-level repair checkpoint, not Apple/Xcode or iPad certification.

## C1 source repair

- `Phase2/SystemAudioInput.swift`: introduced `CaptureSelectionQueue`, a MainActor FIFO of async picker transitions. A newer selection cannot start until a predecessor's native stop or native start cleanup has actually returned. Obsolete request IDs are checked after predecessor completion, not as a reason to skip in-flight cleanup.
- `installSelected` now uses throwing `stopNativeCapture(previous)`. If that fails, it terminates the active capture with an error and **does not start** another `SCStream`. The old stream is retained until a later Stop retry.
- A superseded `startCapture()` also checks failure of native stop rather than ignoring it.
- `CaptureNativeStopLedger.shared` tracks any unconfirmed native stop (including a stop in progress) across `SystemAudioInput` instances. It deliberately retains an object reference to avoid recycled `ObjectIdentifier` collisions. `start()` and the selection handoff reject a new capture when the ledger is not empty.
- `CaptureDelegate.deactivate()` rejects the retiring stream's remaining PCM while the switch is in progress.
- `SystemAudioInput.stop()` invalidates incoming callbacks, drains queued selection transitions, and attempts the final stop. If the native stop throws, the ledger continues to block future captures in the same process. The user may need to fully restart the app.
- Added two XCTest regression cases (queue serialization; multi-stream native-stop ledger state) for later Xcode execution.

## Verified locally

- Extracted **unaltered** `CaptureSelectionQueue` and `CaptureNativeStopLedger` from the production file and compiled them with Swift 6 strict concurrency / warnings-as-errors. Verified FIFO, no overlap during a suspended transition, fail-closed start eligibility while one or multiple native stops are unconfirmed, and release only after confirmation.
- The portable regression is **not** execution of ScreenCaptureKit; fail-closed integration was traced in source, and Swift frontend parsing only checks the syntax of the Apple-specific implementation.

## Explicitly unresolved

- **Native Stop liveness:** `SCStream.stopCapture()` and Apple Speech `cancelAndFinishNow()` / result-task draining can ignore cancellation or fail to return. `AppModel.stop()` still awaits those operations. No bounded native teardown or device proof is claimed; reporting success on a watchdog timeout would be unsafe because an old capture may remain alive.
- A ScreenCaptureKit start failure or screenshot removal failure remains an Apple-native boundary that requires actual iPad testing. A thrown stop now leaves a blocking ledger entry, not an invented success.
- R5A–R5C fixes have not been tested end-to-end with Xcode/UIKit/ScreenCaptureKit/Apple Speech/Core ML. Full code/doc cleanup is still pending a dependency/reference audit.


## End original: `JP_Live_REPAIR_R5D.md`

---
