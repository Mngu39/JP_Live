# R5M — S1 screenshot provenance repair (2026-10-14)

Baseline: `JP-Live-chat-stage8_9C_R5L-popup-semantic-20261012.zip`.

## Provenance problem
A single AppModel `captureID` persists when `SCContentSharingPicker` selects another target. The old C4 capture-ID guard cannot distinguish a caption from source A from a screenshot of current source B. `selectionID` is an asynchronous picker request token, not a caption-level source identity.

## Implemented bounded change
1. `CaptureDelegate.activate(stream)` now resets `currentStreamFirstAudioTime` for the selected native stream; it sets this only when a PCM chunk for that same stream is **enqueued**. The delegate retains the capture-wide PTS origin across selection, so timestamps remain on the same source-time axis. It declines to expose provenance for another stream or before first PCM.
2. Study-save passes the current **full semantic sentence** start/end instead of only `captureID`. Before adding the temporary screen output and after receiving its frame, `SystemAudioInput` requires `ScreenshotSourcePolicy.matches(sentenceStart:sentenceEnd:currentSourceFirstAudioTime:)`. It also keeps existing picker-request, stream-object, AppModel capture UUID, and input-instance guards.
3. A sentence beginning before the current stream's first accepted PCM (e.g. old A caption after switching to B), crossing that boundary, or with missing/invalid timing fails closed. **Text is still saved**; only the screenshot is omitted. Newly spoken B captions can still receive B screenshots after PCM begins.
4. The no-caption `DeviceValidation` screenshot probe continues through the parameterless overload without the study-caption source guard.

## Checks and limitations
- Pure Swift strict-concurrency source-policy executable probe tests the same capture A→B distinction, captions from B, no PCM, boundary-straddling, invalid timestamps and different capture IDs.
- Python static integration guards inspect the actual native callback, source boundary reset, time-based study-save call path, and Dev Validation no-caption overload. XCTest regression cases are authored for Apple.
- Original Swift Core/SpeechTimeline/TranscriptBuffer strict typecheck and repository suite; all Shared/Phase1 mirrors must remain byte-identical.
- The native `SCStream`/Apple `SpeechTranscriber` timebase equivalence and screenshot output behavior cannot be executed on Linux. The mechanism intentionally prefers **no screenshot** when source provenance is uncertain. This is not a full Apple/Xcode build certification.
- Prior claim of 100% comprehensive source coverage was not evidence-supported; this repair does **not** certify repository-wide correctness. See the audit status in `Docs/REMAINING_AUDIT_SCOPE_R5M.md`.
