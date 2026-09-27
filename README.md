# JP Live

일본어/영어 실시간 STT·한국어 번역과 일본어 학습 앱의 작업 소스입니다.
현재 상태, 한계, 검증 이력과 후속 작업은 **[HANDOFF.md](HANDOFF.md)** 한 문서를 기준으로 확인하세요.

현재 로컬 구현 진행본은 이전 stage1 ZIP보다 앞선 작업 상태입니다. Phase 2 완성 또는 Apple 빌드/실기 검증 완료본이 아닙니다.

- `Shared/`: 공통 Swift 기준 소스. `Phase1/JPLive.swiftpm/Sources/`는 동일 복사본입니다.
- `Phase1/`: 외부 Swift 패키지가 없는 파일 입력용 Playground 및 Xcode 검증 프로젝트.
- `Phase2/`: 시스템 오디오용 Xcode 프로젝트. 기존 ScreenCaptureKit 단일 stream 구조를 유지합니다.
- `Native/`, `Resources/`, `Tools/`: native bridge, 학습 데이터, 로컬 검증/Apple 빌드 도구.
- `Tests/`: 회귀 검사. 소스 구문 검사와 실제 XCTest 실행은 별개입니다.

Phase 2 Sudachi는 `Tools/test-apple.sh 2`가 생성하는 `BuildOutputs/Sudachi/`의 framework·사전을 요구합니다. 현재 작업 폴더에 생성된 바이너리는 없습니다. 준비 도구에는 macOS/Xcode/Rust/Python 3.10 이상이 필요합니다.

동시발화 분리의 bounded live 연결 소스와 회귀 테스트를 추가했습니다. 검증 모델은 아직 없으므로 실제 live 기능 완성으로 간주하지 않습니다. 모델 준비와 Apple/실기 검증은 별도 단계입니다.

루트의 오래된 한글 보고서 7개를 HANDOFF.md에 통합하고 제거했습니다. ZIP 덮어쓰기는 삭제를 적용하지 않으므로 HANDOFF.md의 정확한 삭제 목록을 함께 적용하세요.
