# R5I — Device Validation native-stop failure reporting

Date: 2026-10-09 (Asia/Seoul)  
Baseline: `JP-Live-chat-stage8_9C_R5H-speaker-presentation-20261009.zip`  
Change scope: V1 only. R5H input/STT/separation/popup/runtime behavior otherwise unchanged.

## Root cause and source fix

`SystemAudioInput.stop()` intentionally stores an unconfirmed ScreenCaptureKit teardown in `stopFailure` rather than throwing. The normal `AppModel` session already checks that property. In R5H, `DeviceValidationController.run` did not check it after awaiting `input.stop()`, so `DeviceValidationMetricStore.finish()` could see an empty error list and mark `runtime_errors` PASS.

R5I explicitly invokes `metrics.recordNativeStopFailure(input.stopFailure)` immediately after the final `await input.stop()` and before the report is created. The metric helper ignores nil/blank values and deduplicates identical errors through `recordError`. Therefore, a returned native-stop failure is included in exported `errors`, the `runtime_errors` check is FAIL and the session verdict is FAIL. The UI Stop and controller teardown share the previously implemented coalesced `stop()` completion.

## Tests and evidence limits

- `Tests/CoreTests.swift` adds `testR5IDeviceValidationNativeStopFailureCannotPassSession`: constructs a valid synthetic 10-second PCM/STT metric session (PASS control), injects a native stop failure, asserts `runtime_errors == FAIL`, overall verdict FAIL and exactly one error on repeated injection.
- `Tests/test_r5i_stop_failure.py` verifies the production call-site ordering and invokes the **actual source implementation** of `recordNativeStopFailure` in a standalone Linux Swift 6 test shim. The static/portable tests are not a substitute for Apple SDK execution.
- SwiftUI, ScreenCaptureKit, Apple Speech, all Xcode XCTest, and the physical iPad were **not** run in this environment. In particular, the SDK might hang forever before `stop()` returns; this fix does not impose a timeout or declare such a native stream closed.

## Remaining work

Do not certify native teardown liveness or actual device-validation accuracy without Xcode/XCTest/device runs. Investigate Apple native-Stop non-return and any additional integration bugs separately, without weakening the `CaptureNativeStopLedger` fail-closed behavior.
