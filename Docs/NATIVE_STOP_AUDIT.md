# Native Stop liveness / teardown audit — R5E, 2026-10-09

## What is and is not guaranteed

- `Phase2/SystemAudioInput.swift`: `SystemAudioInput.stop()` deactivates callbacks and finishes the PCM consumer before awaiting the picker-selection queue and `SCStream.stopCapture()`. It **does not** guarantee Apple returns from those `await`s within a time limit.
- If user Stop and input-loop cleanup call `SystemAudioInput.stop()` concurrently, `CaptureStopFlight` coalesces them into one in-flight native teardown; both callers await its completion before reading `stopFailure`. Portable Swift execution exercises this class without Apple SDK.
- If `stopCapture()` **throws**, `CaptureNativeStopLedger` retains the stream and blocks future starts. Since R5E, `AudioInput.stopFailure` propagates that failure to `AppModel.status` instead of silently displaying `입력 중지`. This is **error-reporting**, not proof that the stream stopped.
- If `stopCapture()` **never returns**, the `stopFailure` property cannot become available and `AppModel.stop()` may remain suspended. R5E has **not** solved that liveness case.
- `Shared/Audio.swift` `AppleSpeechEngine.finish(aborting:)` awaits SpeechAnalyzer finalization/cancellation and an STT result task with no guaranteed upper bound. Cancelling the enclosing Swift task does not prove native completion.
- `Shared/AppModel.swift` waits for `input?.stop()`, its input-loop task, and STT cleanup. It must not announce a successful teardown or allow a new capture just because a watchdog expired.

## Why not add a naive timeout?

A task racing a timer against native stop may return to the UI while the original `SCStream` still captures system audio. Cancellation of a Swift task is not verified native teardown. `CaptureNativeStopLedger` must retain the unresolved stream; adding a timeout requires a designed **pending/unknown** state, visible warning, blocked subsequent starts, and device-tested escalation. Even that does not forcibly stop a hung Apple API.

## Verification boundary

R5E's policy regressions verify source wiring and string/error-state invariants; pure Swift core typecheck and parser checks cannot execute `ScreenCaptureKit` or Apple `SpeechAnalyzer`. A macOS/Xcode build and physical iPad tests are necessary for thrown stops, switching races, in-flight screenshots, Stop during model loading, and cleanup that never returns. No native Stop timeout or successful device teardown is claimed.

## Recommended Apple device probes

1. Normal Start → Stop → Start, with device capture privacy indicator and callback-count diagnostics.
2. Inject/mock an immediate thrown `stopCapture` (at an adapter seam in Xcode); assert warning remains visible and a new capture cannot start.
3. Simulate suspended native Stop using a **test double**, not live system capture; assert UI warning/pending semantics are designed before any watchdog mitigation.
4. Check `SpeechAnalyzer.cancelAndFinishNow()`/result task completion on real device during Stop and Clear.
5. Observe a second selection arriving while the first `SCStream.stopCapture()` is pending.
