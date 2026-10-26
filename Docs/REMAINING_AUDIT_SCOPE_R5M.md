# R5M audit scope / evidence status (2026-10-14)

The prior report that marked source auditing “100%” was too strong: it documented a broad pass, not exhaustive inspection. That completion claim is withdrawn. Do not convert check counts into percentages of proven correctness.

## Current-turn directly rechecked
- [x] `SystemAudioInput` picker selection → `CaptureDelegate.activate` → accepted PCM timestamp → screenshot frame output, including selection/stream identity checks. Source code read, source integration guards added, native runtime not run.
- [x] `AppModel` screenshot request and `StudyPopup.save` → full semantic caption metadata → `SavePayload.make`, with old/new capture checks. Source read, pure-core policy probe executed.
- [x] Shared ↔ Phase1 mirrors for touched files and core strict Swift typecheck.
- [x] Dev Validation separate screenshot overload remains available. Native compilation still unverified.

## Prior reviewed but not re-certified in this turn
- [ ] STT callback/finalization/debounce and EOF, all product paths; check actual Apple callback constraints.
- [ ] Diarizer recovery, cancellation, source boundaries and late mapping across the real analysis provider.
- [ ] Overlap-only separation, VAD/timed-STT acceptance and multiple replacement revision paths.
- [ ] Live translation, popup morphology, asynchronous save races, Worker/network error contracts.
- [ ] Device Validation verdict/test coverage and native model packaging/build scripts.
- [ ] Full app cancellation/Stop/Start/selection reentrancy across native SDK boundaries.

Source checks from earlier turns are useful clues, not a substitute for a documented final verification. To complete the requested one-pass review, review these unchecked paths with explicit source sections, producer/caller relationships, and actual executable evidence. Native Apple checks stay separate.
