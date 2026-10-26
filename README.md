# JP Live

일본어/영어 실시간 STT · 한국어 번역 · 일본어 학습 앱 소스입니다.

**현재 기준: R5M (Chat-only, S1 screenshot provenance repair).** R5A~R5D에서 F1~F11 및 C1의 소스 수준 수정이 반영됐습니다. R5E는 **동시 Stop을 단일 완료 작업으로 합치고, native Stop 실패 상태를 사용자에게 표시하도록 보완**하고 문서 9개를 손실 없이 통합했습니다. R5F에서는 실제로 실행되지 않던 2차 Quality-STT 및 텍스트 수정 경로와 그 전용 테스트·진단 UI를 제거했습니다. **iPad 실기기, macOS/Xcode 전체 빌드·XCTest를 통과한 배포 승인본은 아닙니다.**

- [`HANDOFF.md`](HANDOFF.md) — 현재 상태, 경로, 아직 검증되지 않은 사항
- [`Docs/CHANGE_HISTORY.md`](Docs/CHANGE_HISTORY.md) — R1~R5D 변경기록 통합 보관 (구기록의 PASS 주장은 현재 승인 근거 아님)
- [`Docs/NATIVE_STOP_AUDIT.md`](Docs/NATIVE_STOP_AUDIT.md) — 종료 실패 vs 무응답, 남은 위험 및 실기기 검증
- [`Docs/REPOSITORY_AUDIT.md`](Docs/REPOSITORY_AUDIT.md) — 보존/제거 근거, 미사용 코드 후보
- [`Docs/REFACTOR_R5F.md`](Docs/REFACTOR_R5F.md) — 미사용 Quality/Revision 제거 범위와 검증 경계

`Shared/`가 Swift 공통 원본이고 `Phase1/JPLive.swiftpm/Sources/`는 Phase1의 동일 복사본입니다. Phase2는 `SystemAudioInput.swift`, `DeviceValidation*.swift`, Xcode 프로젝트를 추가합니다. 런타임 모델·Sudachi 프레임워크는 저장소에 들어 있지 않고 macOS에서 `Tools/test-apple.sh 2`가 사용하는 준비 절차로 생성됩니다. 모델 및 네이티브 Apple 환경 테스트는 별도 검증이 필요합니다.

기존 버전 위에 변경분 ZIP만 덮어쓰면 삭제된 구형 MD 파일이 그대로 남습니다. **정리된 저장소는 전체 ZIP을 새 폴더에 압축 해제**하는 것이 안전합니다.

## R5G source-level safety follow-up

See [`Docs/REPAIR_R5G.md`](Docs/REPAIR_R5G.md) for capture start/stop failure handling, screenshot capture identity checks, and epoch-safe separation speaker mapping. Current source is still pending Apple SDK/Xcode and physical-device validation.

## R5H — bounded speaker presentation

화자 메타데이터 갱신 시 전체 자막 이력을 훑는 P1 비용을 줄였습니다. 최근 32개 적격 자막을 뒤에서부터 탐색하며, 기존 순서는 유지합니다. 로컬 Swift 코어 회귀 검증을 통과했지만 Apple SDK/Xcode/기기 검증은 아직 필요합니다. [세부 내용](Docs/PERFORMANCE_R5H.md).

## R5I — 진단 Stop 실패 보고 수정

Device Validation도 일반 앱과 동일하게 네이티브 Stop 실패를 확인해 `runtime_errors`와 세션 판정을 FAIL로 기록합니다. 변경 및 검증 범위: [`Docs/REPAIR_R5I.md`](Docs/REPAIR_R5I.md). **Apple SDK/Xcode/실기기 검증 전이며**, 원래 존재하던 네이티브 Stop 무응답 위험은 남아 있습니다.

## R5J — 신규 캡처의 과거 자막 탐색 중단

R5H 성능 수정의 남은 P2 문제를 보완했습니다. 새 캡처에서 확정 자막 32개가 쌓이기 전에도 이전 캡처의 자막 이력을 탐색하지 않으며 기존 화자 표시 대상의 순서를 유지합니다. [검증 범위와 재현](Docs/PERFORMANCE_R5J.md). 전체 Apple/Xcode 빌드 및 실기기 실행은 미검증입니다.

## R5K — 소스 경계 화자 분석 복구

정상적인 오디오 소스/형식 경계는 오류 재시도 횟수로 계산하지 않도록 수정했습니다. 복구 중 겹치는 경계는 합쳐서 처리하고, 늦은 복구 완료는 토큰으로 거부합니다. EOF의 복구 대기 전체 상한은 2초입니다. 이전 R5J에 정의 없이 사용된 `maxAnalysisWait` 상수도 선언했습니다. [수정·검증 범위](Docs/REPAIR_R5K.md). **네이티브 Stop 무응답은 미해결이며, P3는 R5L에서 개선했습니다.**


## R5L — P3 popup semantic sentence lookup

`AppModel.popupCaption()`이 이미 검증한 자막 인덱스를 `PopupSemanticSentence.resolve()`로 전달합니다. 같은 `(captureID, semanticID)`의 인접 행만 검색하며, 이전 캡처 이력을 매번 전체 필터링하지 않습니다. 원문·semantic ID·시간·학습 context의 로컬 비교 테스트, 오래된 캡처 조회 및 잘못된 인덱스 거부 테스트를 포함합니다. [세부 내용](Docs/PERFORMANCE_R5L.md). Apple/Xcode 전체 컴파일·XCTest 및 실기기는 아직 검증하지 않았습니다.


## R5M — picker 변경 전후 스크린샷 출처 검사

한 AppModel 캡처에서 공유 대상을 바꾸더라도 `captureID`는 유지됩니다. 학습 스크린샷은 현재 선택된 `SCStream`의 **첫 정상 수신 PCM 시각**과 보존된 문장 전체의 소스 시간을 대조하고, 일치하지 않거나 아직 새 PCM이 없으면 이미지 없이 텍스트만 저장합니다. 실제 PCM 타임라인을 사용하는 경로를 추가하고 앞뒤로 검사합니다. 기기에서의 Apple Speech 타임라인 일치·화면 캡처 동작은 미검증입니다. [수정·검증 범위](Docs/REPAIR_R5M.md).
