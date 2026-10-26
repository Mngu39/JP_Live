# R5G — Native capture and semantic identity safety (2026-10-09)

Source baseline: `JP-Live-chat-stage8_9C_R5F-live-only-cleanup-20261009.zip`.
R5G is a repair slice, **not an Apple build or iPad runtime qualification**. The source of truth remains `Shared/`, mirrored to `Phase1/JPLive.swiftpm/Sources/`.

## C2 — startCapture failure

Once `SCStream.startCapture()` has been attempted, a thrown error no longer automatically discards the associated `SCStream`. A confirmed native stop is required. If cleanup also throws, the native-stop ledger retains an unresolved entry and the old stream is retained for explicit Stop retry; replacement capture is blocked. Errors thrown before start was attempted do not require stopping a never-started stream.

A native stop that **never returns** is still an unresolved product risk: it is not reported as a confirmed stop or replaced by a fake timeout success. This repair intentionally favors safe failure over automatic restart on uncertain native state.

## C3 — screenshot output failure and repeated Stop

Screenshot setup/removal has one catch-and-cleanup path rather than nested handlers that can each call native Stop. `CaptureNativeStopFlights` coalesces in-flight stops per `SCStream`, remembers confirmed success, allows a failed stop to be retried, and maintains the process-wide unconfirmed-stop ledger. When screenshot removal and subsequent native stop both fail, the stream reference is retained until explicit Stop can retry; fresh capture remains blocked by the ledger.

## C4 — learning screenshot capture identity

`AppModel.learningScreenshot(expectedCaptureID:)` verifies selected caption capture identity **before and after** awaiting ScreenCaptureKit, and verifies that the input object has not changed. A row from a previous capture may still be saved as text, but cannot receive the currently active capture's image. `StudyPopup.save` passes the current saved row's capture ID. The core `ScreenshotCapturePolicy` is pure Swift and independently testable.

## C5 — epoch-qualified separator speaker mapping

`SpeechTimeline.confidentSingleSpeaker` includes epoch. `SeparationLaneMapper` requires continuous overlap coverage under one identity epoch and rejects anchor evidence from a different epoch. `LaneSpeakerIdentity(epoch, slot)` survives voting, live separation application, pending late remapping, and `TranscriptBuffer.applySeparationLaneMapping`, including `SpeakerSpan.identityEpoch`.

## Regression and boundaries

- Real R5G source `CaptureNativeStopLedger` + `CaptureNativeStopFlights` compiled/run on Swift 6 Linux with simulated in-flight/repeated/error stops.
- Real core files and extracted exact R5G `SeparationLaneMapper` compiled/run with cross-epoch negative, in-epoch positive and `SpeakerSpan` identity checks; pure screenshot identity policy checked.
- `Tests/CoreTests.swift` adds Phase2 native stop coalescing and retry tests (not executed in Xcode here), epoch mapping and screenshot policy cases.
- `Tests/test_r5g_safety.py` guards actual call-site wiring, not Apple runtime behavior.
- Run the repository Python test suite, Swift frontend syntax parsing, pure core strict typecheck, Shared/Phase1 equality and exact SHA checks before release of the archive.

**Not tested here:** SwiftUI build, Core ML, real `SCStream.startCapture/stopCapture/addStreamOutput/removeStreamOutput`, Apple Speech, device screenshot and native XCTest. Do not claim production PASS from portable tests. C2 and C3 are fail-closed source protections for conditional Apple failure states; these failure states must be tested on macOS/iPad. P1 speaker-update O(history) performance optimization remains deliberately deferred.
