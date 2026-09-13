# JP Live — Phase 1 / Phase 2 소스 프로토타입

> **최신 상태: [현재상태.md](현재상태.md), checksum-preflight-2026-09-12 / CI 결과 2026-09-13.** 두 macOS CI에서 체크섬과 Python 회귀 테스트 8개가 통과했습니다. 이어 Phase 1은 Separation.swift의 try 누락으로 컴파일 실패, Phase 2는 패키지 resolve 성공 후 MLX CudaBuild 플러그인 승인 단계에서 실패했습니다. Swift XCTest 72개·기기용 build는 미진입이며, 이전 iPad STT timestamp 오류의 해결은 아직 실기로 확인되지 않았습니다. 아래 이전 검토의 수치/판정은 해당 시점의 기록입니다.

2026-09-07 작성, 2026-09-08 LanguageTools의 실제 컴파일 오류 3건 수정, 2026-09-09 전달본 갱신. **iPad에서 실행 성공을 확인한 완성 앱이나 서명된 IPA가 아닙니다.**
사용자 보고상 외부 패키지를 제거한 Phase 1은 의존성 단계를 통과했고, Apple 컴파일러에서 CFLocaleIdentifier·StringTransform 타입 추론·Bundle.module 오류가 발생했습니다. 이번에는 그 세 호출과 JSON 로드 확인만 수정했습니다. **이번 수정본의 Apple 컴파일·앱 실행·JSON 실제 로드는 아직 확인하지 못했습니다.** 이전 Nemo/unzip 실패에 대한 Phase 1 외부 SPM 0개 구성은 유지합니다.

Phase 1은 기본 파일 STT·번역·팝업/일본어 학습 연결을 검증합니다. diarization은 이번 Playground host 제약으로 Phase 1에서 비활성이고 **Phase 2에는 유지**합니다. 따라서 Phase 1에서 화자 기반 증폭·화자 전환 분할·화자 색 구분은 검증하지 않으며 gutter는 중립입니다. 가짜 VAD/화자 분석을 추가하지 않았습니다.

Phase 2에서는 **Apple STT·캡처·첫 기본 PCM 전달 후** FluidAudio/DeepFilter 모델을 독립 작업으로 준비합니다. 늦은 분석은 다음 입력 구간을 새 시간 원점으로 삼고, 늦은 enhancer는 설치 이전 대기 오디오를 소급 처리하지 않습니다. 입력 중지 시 준비 작업의 결과 수신을 닫고 다운로드 완료를 기다리지 않습니다. 기존 gain 전환·soft gutter·STT 철회 등의 수정도 유지합니다. 상세는 [추가검토결과.md](추가검토결과.md)에 있습니다.

## 확정 범위

- 일본어·영어 STT와 한국어 실시간 번역.
- 두 언어 모두 gutter → 문장 DeepL 팝업, 단어 → 기본형 DeepL 팝업, 같은 팝업 안의 문장↔단어 전환. 영어 단어에 현재 caption 문맥을 전달하는 기능은 첫 빌드 후 구현할 미완료 요구사항.
- 일본어만 후리가나, 한자/기존 deck 정보, 기존 학습로그 저장, 기존 사진번역기 방식의 AI 재구성.
- 추가 제안이었던 원문/읽기 수동 수정, 단어 선택 범위 조정, 다시 듣기는 넣지 않음.
- 클라우드 STT, 3화자 분리, 자동 YouTube URL 추출, 새로운 단어장은 없음.

## 폴더

| 폴더 | 내용 |
|---|---|
| `Phase1/JPLive.swiftpm` | iOS 26 SDK App Playground. 파일 입력, 외부 SPM 0개, diarization 비활성. |
| `Phase2/JPLive.xcodeproj` | iOS 27 Xcode 프로젝트. Shared 소스를 그대로 참조하고 ScreenCaptureKit 입력 추가. |
| `Shared` | 앱, 팝업, API, STT, 번역, DSP, 모델 연결 소스의 기준본. |
| `Native/SudachiBridge` | sudachi.rs를 Swift에 연결하는 Rust/C 소스. 바이너리는 아직 없음. |
| `Resources` | 제공된 일본어 DB와 deck에서 만든 한자 인덱스. |
| `Tools` | macOS 빌드, Sudachi XCFramework 빌드, 실험적 separator 변환 스크립트. |
| `Tests` | Worker 격리 검사와 iOS XCTest 소스. |
| `검토보고서.md` | 구현·미구현·미검증 구분, 근거 및 발견된 문제. |
| `재검토결과.md` | 이후 전수 검토에서 발견한 오류, 수정 내용, 최신 검사 범위. |
| `추가검토결과.md` | 최신 pre-build 수정, 후속 요구사항, 이전 수정 이력 및 한계. |
| `요구사항대장.md` | 원문 0~39 항목을 전부 추적. |
| `실기검증.md` | 첫 실행부터 장시간/볼륨 검증까지 절차. |

## Phase 1 적용

1. iPad에서 Swift Playground 4.7 이상을 준비합니다. 이 프로젝트는 iOS 26 SDK를 기준으로 작성했습니다.
2. **최신** `JPLive-Playgrounds.zip`을 파일 앱의 새 폴더에 풀고 그 안의 `JPLive.swiftpm`을 Swift Playground로 엽니다. 이전에 가져온 사본을 다시 열지 않도록 합니다.
3. 패키지를 열고 컴파일합니다. manifest의 package/target dependencies는 모두 비어 있습니다. 직전 사본은 사용자 보고상 의존성 단계를 통과했습니다. FluidAudio/Nemo 다운로드가 다시 표시되면 이전 사본인지 먼저 확인하고, 이번 수정본의 compile/run을 확인합니다.
4. 실행 후 `… → 오디오 파일 열기`에서 일본어 또는 영어 음성이 담긴 WAV/M4A 등을 선택합니다. 파일을 사용자에게 들려주는 기능은 아니며, 실시간 속도로 STT 입력에 공급합니다.
5. 선택 언어의 Apple Speech/Translation 모델은 런타임에 별도 준비가 필요합니다. 처음에는 다운로드 때문에 시간이 걸릴 수 있습니다. Phase 1에는 FluidAudio/DeepFilter 모델 다운로드가 없습니다. Apple STT 준비가 실패하면 오류를 확인하고 다시 시작해야 합니다.
6. 실시간 Apple 번역은 Worker 토큰이 없어도 동작하도록 분리했습니다. DeepL/일본어 AI 재구성/학습로그 사용 전 `… → 설정`에 **기존 APP_TOKEN**을 한 번 입력합니다. DeepL 키가 아닙니다.
7. 일본어에서 gutter/단어를 누르고 저장할 때 기존 세션을 선택하거나 이름/YouTube URL을 입력합니다.
8. 앱이 열리면 먼저 **… → 설정 · 연결 상태 → 학습 데이터 확인**을 엽니다. 동봉 파일 기준으로 **한자 사전 5663개, 단어장 인덱스 2306개 로드됨**이 표시되어야 합니다. 이 표시는 팝업에서 사용하는 실제 JSON 해석 결과이며, 파일 없음/읽기 실패/형식 오류/빈 데이터면 실패 이유가 표시됩니다. 이 수치는 패키지 원본에서 확인한 기대값이며 기기에서 이미 로드 성공했다는 기록은 아닙니다.

중요: 외부 패키지 제거는 확인된 host 의존성 실패 경로를 없애는 수정입니다. 수정본의 Apple 컴파일 성공을 의미하지 않습니다. 오류가 나면 첫 번째 resolve/compiler 오류 원문과 OS/Playground 버전을 보존해야 합니다. AppleProductTypes는 Playground 호스트가 제공하는 manifest 모듈이며 별도 원격 SPM 의존성을 추가한 것이 아닙니다.

Phase 1은 `preferredStrategy` 심볼을 사용하지 않는 기존 TranslationSession 생성자를 사용합니다. 이 명시적 전략 API는 공식 메타데이터상 iOS 26.4 도입입니다. 시스템 캡처·DeepFilterNet 패키지는 Phase 1에 포함하지 않았습니다. 후자는 현재 Swift 6.2 패키지 요구 때문이며, OS 자체의 제한이라고 단정한 것이 아닙니다.

## Phase 2 빌드 / sideload

1. iOS 27 SDK를 포함한 Xcode가 설치된 macOS 호스트가 필요합니다. Windows와 SideStore만으로 Swift 앱을 빌드하지는 못합니다.
2. `Phase2/JPLive.xcodeproj`를 열고 `JPLive` scheme을 사용합니다. FluidAudio와 DeepFilterNetCoreML 커밋은 고정했습니다. 전이 의존성은 최초 Xcode resolve 뒤 생성되는 Package.resolved도 함께 보관해야 재현성이 완성됩니다.
3. 먼저 시뮬레이터에서 빌드·XCTest를 수행합니다. STT/번역/캡처의 판정은 실기로 합니다.
4. `bash Tools/build-macos.sh`는 Release archive를 만들고 `BuildOutputs/JPLive-unsigned.ipa`로 묶습니다. **이 파일은 스크립트가 성공했을 때만 생성됩니다. 현재 제공물에는 IPA가 없습니다.**
5. 생성한 IPA를 SideStore 등으로 서명·설치합니다. 현재 기기의 iPadOS 27 빌드와 SideStore 호환성, 계정/설치 조건을 먼저 확인합니다. 임의의 계정 생성, 유료 호스트 구매, 원격 작업 실행은 하지 않았습니다.
6. 앱의 `… → 시스템 오디오 시작`에서 OS의 전체 화면 공유 picker를 사용합니다. 마이크 입력을 붙이지 않습니다. 시스템 오디오 수신 성공은 실기로 별도 판정합니다.

빌드만으로 해결되는 것은 SDK/프로젝트 구성입니다. YouTube 오디오 수신·백그라운드 유지·분리 모델 성능을 sideload만으로 해결했다고 간주하지 않습니다.

Phase 2의 DeepFilterNetCoreML target에는 DeepFilterNetMLX·MLX·HuggingFace가 연결되며 패키지 그래프에는 swift-argument-parser도 있습니다. Core ML 단독 패키지라고 취급하지 않습니다. 최초 resolve 후 `Phase2/JPLive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`를 프로젝트에 보존해야 합니다. 빌드 스크립트는 이 파일을 확인·복사하고 archive에 `-disableAutomaticPackageResolution`을 사용합니다. 실제 resolve 전인 지금 임의의 버전으로 lockfile을 만들지는 않았습니다. 근거와 빌드 검증 범위는 [추가검토결과.md](추가검토결과.md)에 정리했습니다.

## Sudachi 연결 상태

`Native/SudachiBridge`에는 고정한 sudachi.rs 버전의 실제 API로 작성한 C ABI가 있습니다. 원래 UTF-8 byte offset을 UTF-16 offset으로 변환합니다. `Tools/build-sudachi-macos.sh`로 XCFramework를 만든 후 프로젝트에 연결해야 합니다.

별도로 Sudachi 공식 사전 `system.dic`과 해당 버전에 맞는 `sudachi.json`, `char.def`, 입력 정규화 리소스를 `Resources/Sudachi` 폴더로 준비해야 합니다. 사전 배포 라이선스와 필요한 파일 목록도 확인해야 합니다. 사전/바이너리를 준비하지 않은 현재 기본 앱은 Apple NaturalLanguage와 CFStringTokenizer의 읽기 변환을 사용합니다. **Sudachi와 같은 정확도를 달성한 것으로 보고하지 않습니다.**

## 가장 큰 미완료 항목

**낮은 capture PCM 전체를 보정하는 별도 input normalization 단계는 아직 없습니다.** diarization 준비 실패·timeout 때 작은 입력을 보정하지 못하는 상태를 최종 구현으로 인정하지 않습니다. 첫 빌드 후 저레벨 파일과 시스템 볼륨 10/50/100%의 PCM을 측정하고, 필요한 입력 보정량·상한·무음/소음 보호를 정해야 합니다. 이 입력 보정과 이번에 차단한 overlap mixed 신호의 화자별 증폭은 별도 단계입니다.

첫 빌드 이후에는 긴 transcript의 반복 선형 검색/배열 mutation 비용도 최적화해야 합니다. 이력을 임의로 자르지 않고 1~3시간 검사 전에 처리 경로를 개선합니다. 영어 단어 팝업의 caption 문맥 전달 역시 남아 있으며, 기존 Worker 계약 변경이 필요하면 변경 내용을 먼저 보고한 뒤 진행합니다. 상세 완료 기준은 [요구사항대장.md](요구사항대장.md)에 기록했습니다.

**실시간 2화자 분리→stem별 STT→기본 자막 대체·병합은 아직 연결하지 않았습니다.** 모델 계약을 검사하는 Core ML runner, 두 SpeechAnalyzer 경로의 검증용 코드, 변환 스크립트는 있지만 모델 가중치가 없고 변환/성능 검증도 미실행입니다. 전체 요구사항 완성으로 간주하면 안 됩니다. 상세 내용은 검토보고서를 확인하세요.

화자 정보는 오디오 구간에 맞춘 이력에서 조회하도록 연결했습니다. 연속된 final STT 결과가 각각 알려진 단일 화자에 대응하고 화자가 바뀌면 chunk를 구분합니다. 다만 **한 STT 결과 내부의 화자 전환을 단어 시각으로 나누는 기능은 미완료**이며 unknown/겹침 구간을 임의로 분할하지 않습니다. 독립 separation 실험의 `speechProbability: nil`은 limiter만 적용하고 작은 stem을 증폭하지 않습니다. stem마다 음성 판정과 프레임별 독립 leveling을 연결하는 작업이 남아 있습니다.

분석을 켠 기본 경로는 해당 오디오 구간의 finalized 화자 결과를 기다리며 오디오를 제한적으로 보관합니다. **입력 처리 시 확인하는 대기 예산은 2초**이고 초과/오류 시 분석 경로를 중단하고 원본 기반 STT를 유지합니다. 입력 이벤트가 멈춘 경우 잔여분은 다음 입력 또는 종료에서 처리합니다. 이 값은 실제 지연 측정 결과가 아니며 기기 처리 여유를 실측해야 합니다. 개선 신호를 쓰지 않는 구간은 DeepFilter 추론을 호출하지 않습니다.

Apple 번역의 개별 행 실패는 1초·3초 간격으로 최대 두 번 자동 재시도하며, 이후에는 메뉴의 ‘실패한 번역 재시도’로 새 시도를 요청할 수 있습니다. 일본어·영어 단어 분석은 별도 actor와 제한된 캐시에서 처리합니다. 임시 원문 변경 직후에는 분석 완료까지 후리가나/단어 탭 정보가 잠시 없을 수 있으며, 팝업은 자신의 원문 snapshot에 맞춰 분석을 준비합니다.

기존 GitHub/Worker/GCP에 업로드·수정·배포하지 않았습니다. APP_TOKEN이나 서비스 비밀키를 포함하지 않습니다.
