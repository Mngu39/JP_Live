# Repository reference audit — R5F, 2026-10-09

## Verified cleanup

- Combined historical R1–R4B source-review notes and R5A–R5D repair notes into one [`CHANGE_HISTORY.md`](CHANGE_HISTORY.md). Original contents and per-file SHA-256 are preserved; the nine top-level originals were removed from this full tree.
- Kept only authoritative project-facing `README.md`, `HANDOFF.md`, and specific audit documents; generated Python cache and local build outputs are excluded from source archives.
- Updated checksum manifest. **A modified-only ZIP does not remove stale files when extracted over an old folder**; use full clean extraction or the provided deletion list.

## Retained: live dependency or required fallback

| Paths | Reason they are retained |
|---|---|
| `Shared/*.swift` | Phase2 source of record; `Phase1/JPLive.swiftpm/Sources/*.swift` are exact byte mirrors required for Phase1 package compilation |
| `Phase1/JPLive.xcodeproj`, `Phase1/JPLive.swiftpm/Package.swift` | Phase1 Xcode/Playgrounds entry points; cannot delete one simply because Phase2 exists |
| `Phase2/JPLive.xcodeproj`, `Phase2/SystemAudioInput.swift`, `DeviceValidation*.swift` | Phase2 build, live capture and device validation targets |
| `Resources/*`, `Phase1/JPLive.swiftpm/Resources/*` | Runtime data copies for distinct packaging targets; byte equality does not mean the second copy is safe to remove |
| `Native/SudachiBridge/*` | Native Rust bridge staged by `Tools/build-sudachi-macos.sh` |
| `Tools/*` and `DEPENDENCIES.json` | Referenced by model prep, CI, build scripts, validations, or manual entry points |
| `.github/workflows/apple-validation.yml` | Apple CI entry and SDK resource staging |
| `Tests/CoreTests.swift`, `AudioConversionTests.swift`, Python tests, `worker-contract.cjs` | Cross-platform, native, asset and worker contract verification |

## R5F production-only Quality removal — performed, not native certified

- R5F removed dormant `QualitySpeechPass`, its lease and sink adapter, `revisionTranscript` resolver, quality-only diagnostics UI/JSON keys and tests, because the actual input loop never offered Quality PCM. See [`REFACTOR_R5F.md`](REFACTOR_R5F.md). This code removal has **not** been compiled against the Apple SDK.
- `Caption.revision` and `translationRevision` are active features, **not** the deleted second-pass correction resolver. They remain unchanged.
- `Tools/build-macos.sh` is a short manual entry-point wrapper over `test-apple.sh`. No automatic references were found; it is nevertheless documented-useful, so not deleted merely for having no `rg` inbound hits.
- Native/SDK resource paths are used via build-system paths, dynamic runtime lookups, or code generation; static `rg` alone cannot justify deletion.
- Native Stop non-returning awaits remain open, as documented in `NATIVE_STOP_AUDIT.md`.

R5E removed only nine consolidated historical Markdown files; R5F removes unused Swift declarations and associated XCTest cases **within existing source files**, but keeps all live source files, build resources, Xcode projects, Native and Tools assets.
