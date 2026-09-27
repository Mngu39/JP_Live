# JP Live 인수인계 — Chat stage8.3 deep pre-CI review

2026-09-27 / 기준본은 Work `JP-Live-local-stage7-20260921.zip`. 사용자가 stage8.2 업로드 전에 다시 더 넓게 검토해 달라고 요청해 capture→fast STT→debounce/finalization→TranscriptBuffer→Clear/Stop→quality/separation→CI/test 연결을 재감사했다. **stage8.2는 폐기하고 stage8.3만 사용한다.** Worker stage3는 이미 배포된 상태이며 이번 변경은 Worker를 건드리지 않는다.

## 이번 deep review에서 추가로 찾고 수정한 실제 결함

1. **Clear 시 이미 캡처됐지만 아직 fast loop에서 처리되지 않은 오디오가 다시 나타날 수 있었다.** stage8.2의 `clearTranscript()`는 `audioThrough`(AppModel이 이미 처리한 PCM 끝 시각)만 watermark로 사용했다. source queue가 조금이라도 밀린 순간에는 `SystemAudioInput.AudioInputProgress.capturedThrough`가 더 앞서 있으므로, Clear 이전에 실제로 캡처되어 queue에 대기하던 PCM이 이후 STT로 처리되면서 빈 화면에 옛 자막을 다시 만들 수 있었다. stage8.3은 `max(processedThrough, capturedThrough)`를 metadata 기반 Clear watermark로 사용한다. 임의 시간 threshold는 추가하지 않았다. crossing phrase는 기존 정책대로 전체 폐기하고 다음 recognizer phrase부터 표시한다.
2. **Quality revision 소비 ID의 세션 장기 누적을 bounded history와 맞췄다.** hidden revision row는 32개로 prune하면서 `consumedQualityRevisionIDs`는 계속 누적되던 비대칭을 수정해, prune된 revision ID도 set에서 제거한다. 이는 텍스트 선택 정책을 바꾸지 않는 메모리 hygiene 수정이다.
3. 위 Clear watermark를 순수 helper로 분리하고 XCTest에 `processed=3 / captured=5 -> 5`, 반대 순서, nil/nonfinite 조합을 추가했다. 기존 `TranscriptBuffer.clearDisplay(through:)`의 delayed/crossing phrase 회귀 테스트와 함께 source-time Clear 계약을 고정한다.

## 이번에 다시 확인했지만 임의로 바꾸지 않은 부분

- **Primary/Quality**: 현재 lexical conflict는 계속 Primary가 이긴다. 이 correctness checkpoint에서 second Quality STT는 source text를 자동 rewrite하지 않는다. 따라서 quality STT의 현재 연산비 대비 lexical benefit은 제한적이다. 다만 Work의 overload shedding과 향후 3-way consensus 연결을 보존하기 위해 이번 deep review에서 quality path 자체를 제거하는 큰 변경은 하지 않았다. 실기기 throughput/thermal을 본 직후 3-way/evidence resolver와 함께 재평가한다.
- **Speech finalization**: `isFinal` 또는 `resultsFinalizationTime`으로 확정된 범위를 stable로 취급하고, empty volatile은 matching tentative range의 revocation으로 처리하는 stage8.2 구조를 유지한다. 150 ms UI debounce 전에 frontier가 전진한 phrase도 먼저 transcript로 전달한다.
- **final-final overlap**: Apple 정상 계약에서는 이미 final인 range가 다시 바뀌지 않아야 한다. 현재 overlap reconciliation은 malformed/duplicate callback에 대한 defensive path일 뿐 정상 품질 로직으로 의존하지 않는다. device evidence 없이 다시 heuristic을 추가하지 않았다.
- **문장 내부 source time**: 완전한 SpeechTranscriber fragment는 실제 source range를 보존하지만 NLTokenizer가 한 fragment 내부를 자를 때는 아직 문자 비율 근사가 남아 있다. Apple AttributedString의 더 세밀한 audio-time attributes를 보존하는 것은 3-way/canonical-segment 단계의 개선 후보이며, 이번 correctness patch에 섞지 않았다.
- **Stop/restart**: capture generation 선무효화 + system capture stop + primary `cancelAndFinishNow()` + quality abort 구조를 다시 따라갔고 소스상 새 deadlock을 찾지는 못했다. 다만 Apple runtime에서 과거 stuck 증상이 사라졌다는 주장은 실제 iPad 반복 테스트 전에는 하지 않는다.

## stage8.3 검증 우선순위

1. Phase 1 + Phase 2 Apple CI로 type-check/XCTest/device build를 먼저 통과시킨다.
2. iPad에서 Clear 직전/직후 연속 발화, 특히 약간의 backlog가 생긴 상태에서도 Clear 이전 말이 다시 나타나지 않는지 본다.
3. Stop→Start 반복, 언어 변경, empty revocation/ghost token을 짧게 확인한다.
4. 같은 일반 일본어 대화로 5~10분 이상 실행해 source backlog와 fast STT latency가 시간에 따라 누적되지 않는지 본다.
5. correctness와 throughput가 안정되면 **3-way consensus를 바로 다음 품질 개선 후보로 상기한다.** 목표는 user-visible latency를 거의 유지하고 bounded 병렬 compute를 늘리는 것이다.

---

# JP Live 인수인계 — Chat stage8.2 pre-CI review correction

2026-09-27 / 기준본은 Work `JP-Live-local-stage7-20260921.zip`. stage8.1을 사용자가 올리기 전에 다시 전체 연결을 검토했고, **stage8.1은 사용하지 않도록 폐기**했다. Worker stage3는 이미 사용자가 기존 `jp-translator-api`에 배포했으며 stage8.2는 Worker를 변경하지 않는다.

## 이번 재검토에서 실제로 찾은 결함

1. **Apple XCTest 컴파일 차단**: `QualitySpeechPass` 결과 callback이 5인자(`finalizedThrough` 추가)로 바뀌었는데 `Tests/CoreTests.swift`의 6개 call site가 4인자 closure로 남아 있었다. Swift parse는 이를 잡지 못하지만 Xcode type-check에서는 실패할 수 있는 불일치다. 전부 5인자로 맞췄다.
2. **낡은 XCTest 기대값**: 기존 테스트 하나가 Quality가 두 Primary row를 merge/rewrite한다고 기대했지만, 현재 사용자 정책은 “합의 근거가 없으면 Primary 유지”다. 현재 `resolveRevision`과 모순되는 테스트였으므로 Primary 두 row와 ID가 그대로 남는 것을 검증하도록 수정했다.
3. **실제 live text 유실 가능성**: 150 ms visual debounce는 아직 `bufferedPrimaryVolatile` 하나만 보관한다. 첫 volatile phrase A가 debounce 안에서 아직 `TranscriptBuffer`에 들어가지 않은 상태에서, 다음 disjoint result B가 `resultsFinalizationTime`을 A 끝까지 전진시키면 B가 buffer를 덮어써 A를 잃을 수 있었다. stage8.2는 B가 A를 finalize했다는 Apple metadata가 있을 때 A를 먼저 transcript에 넘긴 뒤 B를 처리한다. 임의 문장 threshold가 아니라 source range + Apple finalization frontier만 사용한다.
4. **Stop teardown 정리**: 명시적 Stop/언어 변경이 시작되는 순간 capture generation을 무효화해 cancelled capture의 늦은 primary/quality/model callback이 transcript를 다시 만지지 못하게 했다. `SpeechAnalyzer.cancelAndFinishNow()` abort는 그대로 유지한다. 로컬 `finishPrimaryTranscript`는 유지한다. 이유는 `stop(returnToHome:false)`가 언어 변경에도 쓰이므로, 그 경우 이미 보이던 draft/history를 정상적으로 종료 표시해야 하기 때문이다. 일반 Stop→홈은 직후 Clear된다.

Apple 문서와 다시 맞춘 계약:
- `SpeechTranscriber.Result`는 phrase를 순서대로 보내고 volatile phrase를 finalize될 때까지 갱신할 수 있다.
- `isFinal == true`인 range에는 이후 결과가 오지 않으며, volatile result가 동일 text의 final result로 다시 발행된다는 보장은 없다. `resultsFinalizationTime`이 range end를 지난 것도 finalization 근거다.
- volatile range의 empty text는 같은 range의 이전 tentative result revocation을 뜻한다.
- 명시적 Stop은 `SpeechAnalyzer.cancelAndFinishNow()`로 pending analysis를 취소하고 즉시 finish하는 경로를 사용한다.

## 현재 STT 구조에 대한 전반 판정

- **fast capture→primary STT**: Work stage7에서 quality processing을 동기 `await`하던 구조가 제거되어 fast input loop는 quality에 synchronous bounded enqueue만 한다. system-audio input은 512개/6초 emergency bound, quality는 256개/3초 bound이며 optional overload는 fast STT를 멈추지 않고 해당 quality pass를 중단한다. 이 구조적 backlog 수정은 stage8.2에서 되돌리지 않았다.
- **Primary/Quality resolver**: 현재는 correctness 우선으로 Quality가 Primary source text를 자동 rewrite하지 않는다. 따라서 두 번째 SpeechTranscriber가 현재 lexical 정확도를 직접 높여 주는 단계는 아니다. quality path는 analysis/enhancement/diagnostics 파이프라인을 유지하고 있으며, correctness가 실기기에서 안정된 뒤 3-way consensus 또는 동등한 evidence-based resolver를 적극 검토한다.
- **ghost/stale text**: 정상 API 경로의 핵심은 volatile replacement/revocation/finalization frontier이며 stage8.2가 debounce 전/후 양쪽에서 이를 보존한다. final-final overlap reconciliation은 Apple의 정상 계약상 필요하지 않아야 하며, duplicate/misaligned callback에 대한 방어 장치로만 유지한다.
- **Stop/restart**: 소스 수준에서 late callback generation 차단 + quality abort + primary abort를 연결했다. 언어 변경 경로의 history 보존 때문에 로컬 transcript finish는 유지한다. 실제 iPad에서 과거 stuck 상태가 없어졌는지는 Apple runtime 검증 전에는 완료 판정하지 않는다.
- **남은 자원 감사 항목**: `consumedQualityRevisionIDs`는 capture 동안 누적되고, `AudioPreprocessor`의 12초 ring은 현재 후속 pre-roll 후보지만 읽히지 않으며, visible transcript/history 자체는 의도적으로 무상한이다. 당장 correctness blocker로 보지는 않지만 장시간 memory/thermal 측정 때 같이 본다.

## stage8.2 다음 검증 순서

1. GitHub/Apple Phase 1 + Phase 2: checksum → compile/type-check → XCTest → unsigned device build를 구분해서 본다.
2. 성공한 IPA에서 Stop→Start 여러 번, language switch, Clear를 먼저 본다.
3. 같은 일반 일본어 대화로 5~10분 이상 실행해 fast backlog가 시간에 따라 증가하지 않는지와 ghost/stale token이 남는지 본다.
4. 맞게 나온 Primary가 후행 Quality 때문에 다른 단어/의미로 바뀌지 않는지 확인한다.
5. correctness/throughput가 안정되면 **3-way consensus를 다음 품질 개선 후보로 다시 꺼낸다.** 목표는 latency를 거의 유지하면서 bounded 병렬 연산을 더 쓰는 것이다.

---

# JP Live 인수인계 — Chat stage8.1 STT correctness overlay

2026-09-27 / 기준본 `JP-Live-local-stage7-20260921.zip` 위 Chat 수정. stage8 초안은 재검토 중 Apple finalization 의미를 잘못 해석한 결함을 발견해 폐기하고 stage8.1로 교체했다. Worker는 사용자가 stage3 `src/index.js`를 기존 `jp-translator-api` Worker에 배포했으며, 이번 Chat stage8에서는 Worker를 변경하지 않는다.

## Chat stage8.1 변경 요약

- 사용자 Stop은 어차피 표시 내역을 지우므로 primary/quality의 남은 drain을 기다리지 않는다. 수동 취소에서는 primary SpeechAnalyzer도 abort 경로로 종료하고 quality revision 적용을 생략한다. 자연 EOF만 기존처럼 accepted audio를 drain/finalize한다.
- `TranscriptBuffer`의 stable final을 단순 문자열 append하지 않고 source-time fragment로 보존한다. 같은/포괄 source span의 새 final은 기존 stable fragment를 교체하고, 부분 겹침·과거 committed span을 되살리는 결과는 보수적으로 거절한다. 목적은 `も` 같은 stale/ghost token이 다음 문장까지 끌려가는 구조적 원인을 제거하는 것이다.
- Apple `SpeechTranscriber.Result.resultsFinalizationTime`도 fast/quality/separation 경로에서 끝까지 전달한다. **stage8 초안의 “frontier가 지나면 volatile을 삭제” 해석은 잘못되어 stage8.1에서 수정했다.** Apple은 이전 volatile이 변경 없이 final이 되면 같은 text를 final result로 다시 보내지 않아도 된다고 명시한다. 따라서 다른 range의 후속 result가 frontier를 전진시키면 기존 volatile을 source-time stable fragment로 승격한다. 같은 range의 empty result만 명시적 revocation으로 처리한다. 이로써 valid speech를 지우지 않으면서 예전 tentative text가 뒤쪽 새 text의 꼬리로 이동하지 않게 한다.
- 문장 prefix commit의 audio boundary는 더 이상 rolling 전체 문자열 길이 비율 하나로 자르지 않는다. 완전히 소비한 SpeechTranscriber fragment는 실제 result range를 유지하고, tokenizer가 한 fragment 내부를 자를 때만 그 fragment 안에서 비율 근사를 사용한다.
- quality revision은 이번 단계에서 **Primary source text 절대 우선**으로 고정했다. exact source interval이 일치해도 Quality text가 한 글자라도 다르면 자동 교체하지 않는다. stage8 초안의 “문장부호/공백만 허용”도 재검토에서 제거했다. 영어 `well`/`we'll`처럼 문장부호 제거 heuristic이 의미 차이를 숨길 수 있기 때문이다. 더 강한 correction은 3-way consensus 또는 동등한 검증 가능한 resolver를 실기기 처리량 확인 뒤 별도 단계에서 검토한다.
- quality result UUID를 한 번 결정(applied/rejected)한 뒤 다시 replay하지 않는다. primary가 아직 해당 source interval을 확정하지 않은 경우만 pending으로 남겨 후속 primary final에서 재시도한다.
- 이번 단계는 Apple SDK compile/실기기 결과를 주장하지 않는다. 로컬 Swift parse, Linux Foundation harness, checksum/구조 검사를 수행한 뒤 GitHub Apple validation과 iPad 실사용 검증이 필요하다.

## 다음 실기기 체크포인트

1. 5~10분 연속 실행에서 fast STT 지연이 누적되지 않는지.
2. Stop → 빈 화면 → 즉시 새 Start가 반복해서 정상 동작하는지.
3. volatile→finalization/empty-revocation 전환에서 글자가 사라지거나 뒤 문장 꼬리로 이동하지 않는지, 특정 글자/꼬리가 반복되는지.
4. quality pass가 맞게 나온 primary lexical text를 다른 단어/의미로 뒤집지 않는지.
5. 위 correctness가 안정된 뒤 STT 품질이 부족하면 3-way consensus를 우선 재검토한다. latency 목표는 거의 유지하고 bounded 병렬 처리량을 늘리는 방향이 기본이다.

---

# JP Live 인수인계 — 로컬 구현 진행본

2026-09-21 / 소스 식별자 `local-stage7-2026-09-21` (이전 stage1 ZIP 이후의 작업 폴더)

## 판정과 범위

이것은 **중간 소스 기준본**이다. Phase 2 완성, Apple 컴파일 성공, 장시간 지연 해결을 판정한 버전이 아니다.
사용자가 추가 보고한 “처음에는 빠르다가 몇 분 뒤 수초씩 늦어지는 현상”을 우선해 관련 경로를 수정했다.
ledger/기존 요구사항의 소스 대조와 문서 통합을 진행했다. Phase 2의 모델 준비·Apple/실기 검증은 아직 미완료이며 아래 후속 범위를 유지한다.
GitHub 접속/업로드/commit/push/PR/Actions 실행/배포는 하지 않았다. 참조 원본은 유지했다. 별도 Worker 작업 사본의 번역 context/오류 응답만 수정했고 배포하지 않았다. Translator/Cloud Run은 변경하지 않았다.

입력 기준본: `JP_Live-main 중간 최종.zip`
SHA256: `e59c45e13d573079b8dad2bca63359cf5bedc04cebaa7822f1934355370dd94a`
이전 root 보고서 7개의 유지 요구사항/검증 절차는 이 문서에 통합했다. 과거 원문은 사용자가 제공한 기준 ZIP에 남아 있다. 이번 상태 판단에는 이 문서를 우선한다.

## 재검토 — 마지막 임시 STT와 EOF 순서 (stage7)

- `receivePrimarySpeech`는 임시 결과를 150ms 동안 최신값 하나로 보류한다. 그런데 EOF는 timer를 취소하고 보류값을 nil로 만든 뒤 `TranscriptBuffer.finish()`를 호출했다. 마지막 final이 없는 경우 보류 중인 최신 임시 원문이 유실될 수 있었다.
- EOF에서 대기 task를 취소한 뒤 보류값을 한 번 반영하고 transcript를 종료하도록 수정했다. 이미 Clear나 final로 제거된 값은 재등장하지 않는다. 미확정 결과를 확정 자막으로 승격하지 않는다.
- 실제 AppModel 진입점을 사용하는 XCTest 3개를 추가했다: 최신 임시값 보존/미확정 표시, Clear 뒤 EOF, final이 임시값을 대체한 뒤 EOF. Apple 실행은 미실시다.
- stage6의 quality lease/종료 대기, optional loader 취소, gutter 보존, 번역 source guards를 다시 추적했다. 이번 검토에서 그 수정들의 추가 확정 결함은 찾지 않았다. 동작 성공을 실행으로 입증한 것은 아니다.
- Python 26개/격리 Worker 13개 검사를 다시 실행해 통과했다. 외부 요청/저장은 0회다. Swift 구문/Shared 복사본/프로젝트 구조와 최종 ZIP checksum도 확인한다. 실제 Apple 빌드, XCTest, 모델 변환, 실기 검증은 여전히 미실행이다.
- 추가 삭제 파일 없음. 모델·사전 바이너리가 없는 소스 검증본이며 완료 앱 판정을 내리지 않는다.

## 경로 단위 추가 감사 (stage6)

완료 판정이 아니라 **추가 결함 수정 및 미검증 범위 기록**이다. 기존 제품 방향을 바꾸거나 원격 GitHub/CI/배포를 수행하지 않았다.

| 경로 | 확인된 문제/조치 | 검증과 한계 |
|---|---|---|
| 분리 결과 → 자막 교체 → 번역 큐 | `applySeparation`의 두 lane 표시를 `enqueueTranslations`가 일반 diarization 표시로 다시 덮었다. 분리 group 표시는 보존하고 일반 화자 추적 상태에 lane 번호를 넣지 않는다. | 색상 보존과 일반 화자 추적 불변성 XCTest 추가. Apple 미실행. |
| 품질 보정 EOF/Stop/재시작 | 준비 이후 `finish`가 worker 완료를 무기한 기다렸고, abort는 반환하면서 이전 native 작업이 살아 있을 수 있었다. EOF 대기는 총 8초 상한, 대기 중 취소 감지, 이전 worker/loader 실제 종료까지 전역 lease 유지. 중첩 실행 대신 이번 capture의 optional 보정을 중단하고 원인을 표시한다. | 종료를 일부러 멈춘 가짜 sink, 취소를 무시하는 loader로 3개 XCTest 추가. 테스트 소스만 작성; native/Apple 실행 미확인. |
| 수동 Stop → 분리 작업 | 앱 Stop 진입 때 분리도 즉시 취소 요청하도록 연결. | 취소는 native 연산의 강제 종료가 아니다. 기존 lease와 늦은 결과 차단 유지. |
| 임시 번역 → 확정/철회 | 완료된 draft의 source 문자열이 capture 전체 동안 deduplication 사전에 남았다. 현재 draft 한 개의 항목만 유지한다. | 사용자 자막 history는 삭제하지 않았다. Swift 구문/복사본 검사 통과. |
| 모델 생성 → 자산 검증 | conversion report의 파일 해시는 검사했지만 내용은 읽지 않았다. 버전/원본 파일 hash 목록/4개 필수 parity case/성공 flag/유한 측정값을 함께 검사한다. | 보고서를 비우거나 실패/누락/NaN으로 바꾸고 hash를 재계산해도 거부하는 Python 3개 검사 통과. 실제 모델이 생성됐다는 뜻은 아니다. |
| 소스 → 전달 ZIP | 최신 상태와 과거 결과를 구분하고 전체 source manifest 및 ZIP bytes를 검증한다. | 오래된 static report는 historical 키 아래 보관. 이번 단계 추가 삭제 파일 없음. |

함께 추적한 경로: source clock→PCM 변환/flush→STT 입력, quality mailbox와 overload, Clear 이후 늦은 결과, 번역 source/capture guards, 형태소 mode 교체, 팝업 저장 snapshot, one-stream screenshot 부착/해제, native 사전 준비→Xcode resource 참조. 이번 감사에서 추가 확정 결함을 찾지 않은 경로도 **실행 성공으로 판정하지 않는다**.

중요한 미검증 범위:

- Windows의 syntax tree 검사로 Swift 타입/API, Rust 빌드, Core ML 변환, Apple SDK 동작을 확인할 수 없다. Bash 스크립트 실행도 하지 않았다.
- 위 8초는 optional quality EOF 대기 예산이다. primary Apple STT의 finalization이나 시스템 캡처 SDK 호출이 8초 내 끝난다는 보장은 아니다.
- 분리 모델/실제 사전 바이너리는 ZIP에 아직 없다. 모델 도구를 작성한 것과 성공한 모델을 확보한 것은 다르다.
- 빠른 입력 backlog는 앱이 STT에 전달하기 전 대기량이다. Apple 내부 인식 지연 및 UI까지의 전체 지연을 단독으로 증명하지 않는다. 기존 quality source 시각 지표와 실제 발화→표시 측정을 함께 사용해야 한다.
- 장시간 throughput, GPU 경쟁/발열, 일본어 겹친 발화 품질, RAIL/DOCK 스크롤·gutter 터치 및 실제 저장은 Apple 빌드/실기 검증이 필요하다. 이 기록은 “남은 결함 없음” 보증이 아니다.

## 완료 판정 재검토 (stage5)

- stage4의 “이 환경에서 가능한 준비·수정은 마쳤다”는 판정을 정정한다. 자연 EOF에서 분리 pass를 STT flush보다 먼저 취소해 끝부분 확정 자막을 분리하지 못하는 경로를 추가 발견했다.
- 자연 EOF는 primary/quality STT와 analysis를 마친 뒤 최근 32개 최종 자막을 분리 pass에 전달한다. 진행 중 작업과 새 후보를 합쳐 총 8초까지만 기다린다. 모델 준비도 이 예산에 포함하며 초과 시 원본을 유지한다. 파일 전체를 사후 분리하는 기능은 아니다.
- 수동 중지·입력 오류·Clear는 취소를 유지한다. 취소된 native 작업의 실제 종료까지 기존 전역 lease를 유지하여 다음 실행과 추론이 겹치지 않게 한다. 종료 진단은 처리 중으로 방치하지 않고 종료/취소 요청 상태로 표시한다.
- EOF 후보 처리 및 명시적 중지 회귀 XCTest 2개를 추가했다. Apple 실행은 하지 못했으므로 테스트 통과나 실제 EOF 분리 성공을 주장하지 않는다.
- 추가 로컬 검사: Python 23개 통과, 소스 구문/복사본/프로젝트 구조 검사 통과. 모델 생성, native Sudachi 빌드, Apple compile/XCTest, 일본어 2화자 품질, iPad 장시간 처리량은 여전히 미검증이다. 현재 ZIP은 완성 앱이 아니다.

## 발견 및 수정

1. 빠른 입력 루프에서 보정 전처리와 두 번째 STT를 기다리던 구조를 분리했다.
   - 첫 빠른 STT 전달 이후 별도 선택 작업을 시작한다. 모델 다운로드/보정 STT 준비 중의 원본 오디오는 보정용으로 쌓아 두지 않는다.
   - 빠른 입력 루프는 보정 경로에 동기식 enqueue만 한다. 보정 오류는 feature 상태로 보고하고 빠른 STT 오류로 전파하지 않는다.
   - 보정 입력은 처리 중인 버퍼를 포함해 최대 3초/256개다. 초과하면 해당 실행의 보정을 중단한다. 중간 PCM을 버린 뒤 잘못 이어 붙이지 않는다.
   - 빠른 입력의 실제 대기 오디오가 0.75초 이상인 상태가 1초 지속되어도 보정을 중단한다. 자동 재시작에 의한 부하 진동은 넣지 않았다.
   - Phase 1에는 선택 모델이 없으므로 두 번째 SpeechAnalyzer를 시작하지 않는다.
2. 시스템 입력의 `.unbounded`를 제거했다.
   - 최대 512개와 실제 미처리 오디오 6초를 상한으로 둔다. 6초는 정상 목표 지연이 아니라 보정 중단 후에도 회복 못한 경우의 최종 오류 한도다.
   - 한도 초과는 명시적으로 입력을 종료한다. 필수 PCM을 조용히 버리며 진행하지 않는다. 짧은 burst는 한도 내에서 보존한다.
   - 캡처 callback에서 직접 계측하고 빠른 STT 입력 전달 뒤에 차감한다. 기기 검증 경로에도 같은 차감을 연결했다.
3. 설정의 ‘실시간 지연 진단’에서 현재/최대 입력 대기, source 시각 차이, 보정 큐, 생략 수, 과부하 중단 수, 자막 보정 수, 모델 연결 시각을 확인하고 JSON 텍스트로 공유할 수 있다.
   - 원본 시각 차이에는 실제 캡처 gap도 포함될 수 있다. overload 판단은 gap을 제외한 미처리 PCM 양을 사용한다.
   - 보정 큐 지표는 내부 최대 2초 분석 대기 및 Apple 내부 인식 시간을 포함하지 않는다. 보정 수신/Analyzer 전달/인식 결과 source 시각을 별도로 표시한다.
   - 모델 연결 시각은 해당 source 시간이다. 모델이 준비되었다는 사실만으로 실제 성능이 검증된 것은 아니다.
4. 보정 STT의 짧은 결과가 긴 기존 자막 전체를 지우던 overlap 판정을 수정했다.
   - 동일 capture/language에서 연속한 확정 row의 전체 source 구간이 일치할 때만 교체/merge한다. 허용 오차는 source 1 sample이며 오디오 timestamp를 보정하는 것이 아니다.
   - 부분 결과를 문자 길이 비례로 억지로 끼워 넣지 않는다. **부작용: 경계가 다르게 잡힌 유효한 보정도 거절될 수 있다.** 더 넓은 적용에는 단어/구간 대응을 보강해야 한다.
5. Clear의 source watermark를 양쪽 transcript에 적용했다. Clear 전 시작한 늦은 결과가 재등장하지 않는다.
   - 단어별 시각이 없으므로 Clear 경계를 가로지르는 인식 phrase는 전체 제외한다. 다음 phrase부터 표시하며 새 capture에서는 watermark를 초기화한다.
6. 같은 ID가 보정된 뒤 도착한 옛 번역의 성공/실패/취소가 새 원문의 번역 대기 상태나 오류를 변경하지 않게 했다.
7. 화자 갱신은 현재 capture의 최근 분석 범위만 역순 검색하고 변경 결과는 시간순으로 적용한다. 이전 capture 자막을 현재 timeline으로 다시 분류하지 않는다.
   - timeline 구간 검색에 이진 탐색을 적용했다. 보정 row 검색도 최근 현재 capture부터 찾는다.
   - 숨은 보정 자막은 32개만 유지한다. 사용자에게 보이는 자막은 임의 삭제하지 않았다.

## 이번 후속 구현 — 소스 반영, Apple 실행 미검증

- Sudachi A/B/C(default C)를 설정 저장→Rust ABI→mode별 cache→현재/과거 자막 재분석→popup까지 연결했다. 재분석 도중의 오래된 AI/형태소 응답과 저장 snapshot 혼합을 방지했다. native 실패/미연결은 화면에서 Apple fallback으로 구분한다.
- Phase 2 target에 생성될 Sudachi XCFramework와 사전 폴더를 연결했다. macOS 준비 도구가 pinned SudachiPy 0.6.11 / SudachiDict-full 20260723.1, 라이선스와 자산 hash를 수집하고 실제 사전 기반 Rust 검사 후 3개 iOS 아키텍처를 빌드하도록 했다. 바이너리/사전은 아직 생성하지 않았다. cargo transitive lock은 최초 빌드에서 생성·기록되며 현재 소스에 고정된 것은 아니다.
- RAIL은 원문 위/번역 아래, DOCK은 좌우의 독립 pane이다. 스크롤은 caption ID 기준으로 맞춘다. 전체 row gutter의 고품질 문장 action은 확정 자막만 허용한다. 실제 화면 크기/스크롤 검증은 미실행이다.
- history를 자르지 않고 caption ID→index cache(최대 2048)와 직접 mutation으로 반복 검색/배열 복사 경로를 줄였다. mode 변경 시에는 한 작업으로 이력을 순차 재분석한다.
- 영어 단어 popup이 기존 /run/translate에 optional context로 현재 caption을 전달한다. Worker는 문자열/12000 UTF-16 길이를 검증하고 DeepL context로 전달한다. 기존 context 없는 요청/응답은 유지한다. route의 비동기 오류가 JSON 400/401로 반환되도록 await를 수정했다. 배포 전에는 수정된 context 동작을 실서비스 성공으로 간주하지 않는다.
- 분리 실험에서 nil VAD를 제거했다. FluidAudio의 stem별 실제 VAD 결과를 4096 sample 구간에 맞추고, 10ms 처리 및 stem별 독립 gain을 적용한다. 비음성 구간은 이전 gain을 즉시 끊는다. 잘못된 확률/길이/NaN을 거부하고 양쪽 성공 전 결과를 반환하지 않는다. 모델 준비 실패 시 이전 모델을 남기지 않으며 취소 후 늦은 추론 결과도 거부한다. 이 독립 경로는 이후 아래의 bounded live 연결에도 재사용한다. 모델/실기 검증 완료라는 의미는 아니다.
- stem별 증폭/비음성/짧은 EOF/잘못된 VAD/overlap confidence에 대한 XCTest 4개 추가. 앞선 A/B/C 테스트를 포함해 XCTest는 전부 미실행이다.
- SRC 보상/누적 출력 길이/flush 알고리즘을 유지하고 진단 print와 assertion 없는 일회성 실험만 제거했다. 유효한 오디오 회귀 테스트는 유지한다.

참고 계약: [SudachiPy](https://pypi.org/project/SudachiPy/), [SudachiDict-full](https://pypi.org/project/SudachiDict-full/), [DeepL context](https://developers.deepl.com/api-reference/translate/request-translation).
Swift/Rust/Python Tree-sitter 구문 검사와 프로젝트 구조 파싱만 수행했다. Bash 구문 검사는 설치된 parser의 호환성 오류로 수행하지 못했다. Swift 타입/API 검증, Rust 실제 빌드, 사전 asset 생성, Apple XCTest/기기 검증은 실행하지 않았다.

## 후속 live 분리 연결 — 2026-09-21, 실행 미검증

- 기본 PCM 참조를 최대 32초/4096개 보관한다. 모델 미탑재 시 이 보관/분리 작업은 하지 않는다. 만료 버퍼는 head 인덱스로 해제하고 128개 단위로 정리해 빠른 입력마다 전체 배열을 이동하지 않는다.
- 최근 32개 자막 중 현재 capture의 확정 문장에 대해, 전체 구간의 분석이 존재하고 3명 이상 구간이 없으며 2명 overlap이 3개 분석 프레임 이상 연속 확인될 때만 후보로 삼는다. 현재 선택 예산은 문장당 최대 20초다. 오래되거나 PCM이 누락된 후보는 생략하고 원본을 유지한다.
- 별도 actor에서 기존 검증 대상 SRC 변환기로 48→16kHz 변환과 flush를 수행한다. 4초 모델 window를 2초 겹쳐 처리하고 공통 파형의 correlation으로 lane 교환을 판단한다. 모호한 연결은 실패 처리하며 arbitrary 화자 연결을 만들지 않는다. 마지막 window의 padding은 출력에서 제거한다.
- 한 번에 한 작업, 별도 대기열 없음. 두 stem STT는 순차 실행해 두 분석기를 동시에 추가하지 않는다. 다만 기존 primary+quality에 분리 STT 하나가 추가되는 최대 3개 상태의 성능은 아직 미검증이다.
- 각 stem의 실제 VAD→독립 leveling→SpeechTranscriber→기존 NLTokenizer 문장 경계를 사용한다. 양쪽 모두 final이어야 하며 같은 결과 중복, 미확정 tail, 구간 이탈은 원본 유지다. 강한 필터 때문에 유효한 분리를 거절할 수도 있으며 실제 자료로 조정해야 한다.
- 원본 row ID/source/capture/시간이 요청 snapshot과 같을 때만 두 stem 결과를 한 번에 교체한다. 첫 ID를 보존하고 다른 행에는 새 ID를 부여한다. 오래된 번역/형태소 작업을 무효화하고 다시 요청한다. 분리 group의 화자 힌트는 해당 구간 안의 두 lane이며 지속적인 인물 identity가 아니다. 이후 mixed 보정/diarization이 분리 결과를 덮지 않는다.
- Clear/Stop/새 capture는 늦은 결과를 차단한다. 빠른 PCM 대기 0.75초 이상이 1초 지속되거나, 모델 준비 후 한 작업이 8초를 넘으면 이번 capture의 분리를 취소한다. 이 값은 초기 보수적 예산이며 측정된 최적값이 아니다. Core ML 동기 추론은 중간에 즉시 중단되지 않을 수 있지만 결과 전달은 차단한다.
- 분석 timer가 actor 대기 후 취소/새 capture를 다시 검사하도록 보강했다. 종료된 timer가 새 capture의 timeline/분리 작업을 갱신하지 않는다.
- 설정에서 분리 상태/시도/반영/생략/실패/과부하 중단을 보고 JSON으로 공유한다.
- XCTest 7개 추가: lane 교환 연결·모호한 window 거절·atomic 교체와 mixed 보호·Clear/stale/범위 거절·분석 gate·PCM retention/gap·모델 없음. **실행하지 않았다.**

### 모델 준비 경로 확정 및 남은 실행 관문

모델은 [SpeechBrain sepformer-whamr16k](https://huggingface.co/speechbrain/sepformer-whamr16k)의 [commit 21a5b500c6f52fddc387c5d9e5fb13ffd6f039c5](https://huggingface.co/speechbrain/sepformer-whamr16k/commit/21a5b500c6f52fddc387c5d9e5fb13ffd6f039c5)으로 고정했다. 모델 카드에는 Apache-2.0, 16kHz mono와 WHAMR 영어 평가가 명시되어 있다. 일본어 평가 결과는 제공하지 않으므로 일본어 부적합/적합 어느 쪽도 단정하지 않는다.

`Tools/export_separator.py`는 고정된 snapshot의 필요한 6개 파일만 받고, 로컬 snapshot으로 SpeechBrain을 초기화한다. 오래된 from_hparams의 revision 인자가 pretrainer의 모든 weight 다운로드에 전달된다고 가정하지 않는다. 원본 파일 SHA256, 실제 설치 패키지 버전, 호스트/Python, 비교 결과를 기록한다. 앱 자산에는 모델 카드와 Apache-2.0 원문을 함께 넣는다. **현재 이 환경에서는 다운로드/변환/실제 모델 생성은 수행하지 않았다.**

Python 3.11/macOS의 고정 top-level 패키지 조합은 `Tools/separator-requirements.txt`에 있다. 이 조합의 실제 resolve/실행은 미검증이며 완전한 transitive lockfile로 설명하지 않는다. 공식 separate_batch→wrapper→trace→Core ML 결과를 noise/silence/impulse/공식 영어 음원으로 비교한 뒤에만 compiled model을 공개 경로로 이동한다. 변환 성공은 일본어 분리 품질 또는 iPad 속도 성공을 뜻하지 않는다.

`Tools/separator_assets.py`는 생성물의 revision/shape/license 증빙/파일 목록/SHA256을 검사한다. 모델이 없는 빈 폴더는 MODEL_NOT_PREPARED로 기록하지만, 깨진 모델 폴더·해시 불일치·누락된 라이선스는 빌드 전에 실패한다. 정상 빌드 스크립트가 자동으로 모델을 내려받지는 않는다.

macOS/Xcode와 Python 3.11이 있는 호스트에서 프로젝트 루트 기준:

```bash
bash Tools/prepare-separator-macos.sh
bash Tools/test-apple.sh 1
bash Tools/test-apple.sh 2
```

첫 명령은 별도 가상환경을 만들고 패키지 설치→고정 모델 준비→변환 비교→Core ML compile→자산 검사를 실행한다. 기존 비어 있는 BuildOutputs/Separation 폴더는 허용하고, 기존 모델이 있으면 검증 후 보존한다. 실패 로그는 BuildOutputs/separator-export.*/install.log 또는 export.log에 남는다. 기존 모델 교체가 필요하면 해당 폴더를 먼저 별도 보관한다. 나머지 두 명령은 기존 Apple 검사 단계이며, 원격 GitHub Actions 실행은 사용자가 한다. 이 작업에서 GitHub/배포를 실행하지 않았다.

현재 Windows에서는 [Core ML prediction에 필요한 macOS framework](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)가 없어 모델 생성의 필수 비교/compile을 실행할 수 없다. 따라서 **다음 필요한 결과는 macOS 모델 준비 및 Apple compile/XCTest 로그이며, 아직 iPad 반복 전송을 요청하는 단계가 아니다.** 실패하면 첫 실제 오류를 기준으로 이어서 수정한다. 앱이 빌드된 뒤 일본어 실제 2화자 자료·1명/3명/BGM/작은 목소리·Stop/Start/Clear·30분 지연을 확인해야 한다.

### 재시작 시 추가 보강

분리 작업은 취소해도 Core ML 내부 동기 호출이 즉시 끝나지 않을 수 있다. 이전 capture의 작업이 실제로 종료할 때까지 프로세스 공통 lease를 유지해 새 capture가 또 다른 분리 모델 작업을 겹쳐 실행하지 않도록 했다. 현재 capture 안의 1개 제한만으로 충분하다고 가정하지 않았다. 이 lifecycle XCTest 1개를 추가했고 미실행이다.

## 장시간 자원 감사: 남은 한계

확인한 상한: 입력 6초/512개, 보정 queue 3초/256개, Apple 입력 각각 512개,
분석 queue 150개, 분석 timeline 120초, 기존 오디오 ring 12초, morphology cache 128개, 숨은 보정 row 32개.
보정 전처리의 최대 2초 분석 대기는 유지하되 빠른 경로와 분리했다.
화면 자막/history와 번역 backlog에는 아직 전체 개수 상한이 없다. 장시간 자막 보관을 잃지 않는 정리/보관 방식은 후속 감사 대상이다.
Task 분리는 CPU/GPU 처리량 보장을 뜻하지 않는다. 진행 중인 native 모델 연산의 즉시 취소도 보장하지 않는다.
실기에서 steady-state 처리량, 두 STT 동시 비용, 발열/메모리, 실제 지연 추이를 확인해야 한다.
`あ`/`ま` 한 글자 인식은 사용자 보고만 있는 미확정 현상이다. 노래 특성과 과부하를 동일 원인으로 단정하지 않았다.

## 이번에 실행한 검증

- Shared 17개 ↔ Playground Sources 17개 byte 일치.
- Swift 40개: Tree-sitter 구문 검사 오류 0. **swiftc/Apple 타입 검사와 다르다.**
- Xcode 프로젝트 2개 구조 파싱 성공. Apple compiler/package resolution 실행 아님.
- checksum regression Python 8개, Sudachi 리소스 fixture 5개, separator 자산/preflight fixture 13개 통과.
- 수정 Worker의 격리 contract 검사 13개 통과. 외부 요청/실제 저장 0회.
- 현재 작업 폴더 manifest LF 재생성 및 파일별 SHA256 확인. `#Uxxxx` 경로 0개. 현재 변경분은 이전 stage1 ZIP에 포함되지 않는다. 이번 로컬 구현 단계 전체 ZIP은 `JP-Live-local-stage7-20260921.zip`이며 모델/Apple 실행 검증 완료본은 아니다.
- CoreTests에 12개 회귀 테스트 추가: 부분/과도한 보정, 비유한 시각, Clear와 새 capture,
  이전 capture 화자 오염, 큐 시간/개수, 입력 in-flight 및 gap, timeline 보존 구간,
  준비 중 Stop/늦은 결과, 보정 overflow/늦은 결과. **XCTest는 여기서 실행하지 않았다.**
- Apple SDK compile / XCTest / iPad 실행 / 장시간 성능 검증: 모두 이번 수정본에서는 미실행.

첨부된 2026-09-20 실기 JSON은 **수정 전** 25.48초 1세션의 PCM 연속성과 same-stream screenshot 성공 근거다.
그 JSON에서 재시작은 미검증이며, live 이중 STT/동시발화 분리/이번 수정의 성공 근거로 사용하지 않는다.

## 사용자가 실행할 검증 순서

지금 당장 반복 전송을 요구하는 것은 아니다. 이 중간본을 검증할 때의 절차다.

1. 최종 ZIP을 반영할 때 아래 삭제 목록도 적용한다. ZIP 덮어쓰기는 기존 파일을 삭제하지 않는다.
2. 기존 Apple validation에서 Phase 1, Phase 2 각각 실행한다. 로컬 workflow에서 진단 전용 1-trace 선택지만 제거했다. 원격 실행/수정은 하지 않았다.
   macOS에서 직접 실행할 경우: `bash Tools/test-apple.sh 1`, `bash Tools/test-apple.sh 2`.
3. 각각 checksum → (Phase 2 package resolve) → compile → XCTest → unsigned device build 결과를 구분한다.
   오류가 있으면 해당 소스 checksum과 첫 실제 오류를 함께 보관한다. IPA 생성은 실기 성공이 아니다.
4. 설치 후 일반 발화 파일/시스템 오디오로 시작 → Clear → Stop → 재시작, 언어 변경, EOF를 확인한다.
   보정 중단 뒤에도 빠른 STT가 계속되는지, 옛 자막/번역 오류가 재등장하지 않는지 확인한다.
5. **앱의 실제 live 모드**에서 일본어 대화로 최소 30분 확인한다. 0/1/5/15/30분에 설정의 진단값을 공유한다.
   모델 활성 전후 입력 backlog가 계속 증가하는지, 보정 중단 뒤 회복하는지 기록한다.
   기기 검증 화면의 짧은 단일 STT 검사는 이 검사를 대신하지 않는다.
6. 저장 중 같은 stream screenshot, 영/일 popup 번역, 일본어만 저장을 확인한다.
7. 한 글자 인식은 backlog가 낮은 일반 대화에서도 재현되는지 분리 관찰한다. 원문 오디오 시각과 진단값을 남긴다.

## 다음 작업에 반드시 유지할 범위

1. 아래 ledger/요구사항 대조는 소스 수준의 상태다. 기존 Chat의 CI 성공 기록을 현재 수정본의 성공으로 승계하지 않는다. Worker/팝업 실제 의미 품질과 저장은 사용자 실행 검증 대상이다.
2. native Sudachi A/B/C(default C), 설정/재분석/캐시/팝업/range, 실제 framework·사전 연결.
   A/B/C 전달과 target 연결 소스는 구현했다. 실제 Rust 빌드·사전 생성·iOS 링크/리소스 로드는 미실행이다.
3. **동시발화 분리까지 필수**. 사용자는 모델 준비 및 실기 성능 검증만 별도 단계로 나누기로 결정했다.
   diarization만으로 완료 처리하지 않는다. live 연결 소스는 추가했지만 검증된 모델은 없고 실제 분리 성공은 미확인이다.
   아래 bounded live 스케줄링/긴 구간 연결/atomic merge를 구현했다. 모델 준비·분리 품질·Apple API/typecheck·실기 성능 검증은 남아 있다.
4. RAIL/DOCK 별도 pane와 caption ID 기반 scroll 동기화, 확정 문장 전용 action은 소스 반영. 실제 UI 검증은 미실행.
5. `[PCM_TRACE]`, `[PCM_ALIGN]`, `1-trace` 및 assertion 없는 probe는 제거. 오래된 root 문서 7개는 아래 목록대로 통합/삭제했다.
   SRC 보상과 의미 있는 회귀 테스트를 삭제하거나 예전 screenshot/문장 경계 설계를 부활시키지 않는다.
6. 본 문서와 전체 소스 ZIP, 수정 Worker ZIP을 이 단계의 기준으로 보관한다. 실제 모델/Apple 검증 결과가 나오면 같은 문서에 소스 해시와 함께 갱신한다.

## 기존 요구사항 0~39의 유지 범위

| 원문 번호 | 유지한 요구/현재 구분 |
|---|---|
| 0~3 | M4 iPad, 온디바이스 중심, Phase 1 파일/Phase 2 시스템 PCM. YouTube 마이크 대체 금지. 로컬 작업이며 외부 배포 없음. |
| 4~5 | RMS/peak, 역위상 보호, limiter, 시각에 맞는 음성 확률 및 DF gating. 전역 normalization은 저레벨 파일/볼륨 실측으로 필요성이 확인된 뒤 적용하며 미구현 상태를 유지. |
| 6~10 | SpeechTranscriber, 일본어/영어 선택, volatile 철회, Phase 2 diarization와 단일 화자 gain reset, 정확히 2명 분리. 3명 분리/가짜 VAD 없음. 전력/발열 목표는 미측정. |
| 11~13 | 최신 합의인 NLTokenizer 문장 분리와 rolling STT/번역/후행 보정. 과거 9초/화자전환 강제 분할은 폐기된 설계. Apple 번역 재시도 1초/3초 최대 2회 및 수동 재시도. DeepL은 선택한 문장/단어, 영어 단어는 caption context. |
| 14~19 | Sudachi A/B/C 기본 C, 원문 UTF-16 token range, 영어 NL 단어/lemma, 자연 본문/CoreText hit-test/ruby. 단어·확정 문장 popup, 일본어만 후리가나/한자/deck/학습 저장/AI 재구성. |
| 20~25 | 창 크기 대응, RAIL 상하/DOCK 좌우 pane, caption ID 스크롤 동기화, 3pt 표시/30pt 전체 행 터치 gutter, dark/light와 history 보존, 언어/단어장/후리가나/설정 메뉴. |
| 26~32 | 기존 logs.html 내장 WKWebView, 기존 Worker endpoint·일본어 DB, 이미지 없는 저장, UTF-16 범위/context group, 최근 세션·이름/URL resolve, Keychain과 log token 갱신. APP_TOKEN을 URL/웹 저장소로 보내지 않는다. 실패한 저장을 자동 재전송하지 않는다. 실제 DB 저장 미실행. |
| 33~39 | Phase 1 외부 패키지 0개. Phase 2 고정 FluidAudio/DF 및 기존 Package.resolved 보존. 모델 준비·실패·취소 격리, 작성/미완료/미검증 구분. 완성 앱/IPA/실기 성공이라고 주장하지 않는다. |

추가하지 않은 기능: 원문/읽기 수동 수정, 선택 범위 확대, 다시 듣기, 클라우드 STT, 자동 YouTube URL 추출, 영어 학습/저장, 새로운 단어장.
A/B/C는 사진/텍스트 앱의 기본값 C·같은 설정 key 개념을 따르지만 브라우저 localStorage와 iOS UserDefaults가 자동 동기화되는 것은 아니다. OCR 자체를 live STT에 복제하지 않았다. Translator/Cloud Run은 변경하지 않았고, 별도 Worker 사본만 context 및 async 오류 응답을 수정했다.

## v26/v26.1 변경 이력 대조

| 항목 | 현재 소스에서의 처리 |
|---|---|
| 1~4 | EOF/SRC 및 실제 primeInfo 보상·누적 output window 유지. 진단 print와 assertion 없는 probe만 정리. |
| 5~8 | SDK/시뮬레이터와 실기 SCK 분리, analyzer format 검사, Phase 2 test 조건 유지. |
| 9~10 | 초기 screenshot 저해상도/cursor 시도는 현재 기준 설계가 아님. |
| 11, 15~16 | Chat에 기록된 CI/실기 성공은 역사 기록. 제공된 직접 device JSON은 25.48초 1세션이며 재시작 미검증. 현재 패치의 빌드 성공 근거 아님. |
| 12~14 | 기기검증/unsigned IPA 생성, Unicode/checksum 처리, Phase 1 SDK guard 유지. |
| 17~19 | 저지연 번역·상태·popup/save parity 및 XCTest async 호출 구분 유지/보강. 실제 오류 의미·UI는 미검증. |
| 20~24 | updateConfiguration/두 번째 SCStream 기반 screenshot 시도는 되살리지 않음. |
| 25 | 하나의 실행 중 stream에 저장 시만 screen output을 붙이고 유효 frame 뒤 제거하는 현재 방식 유지. SCScreenshotManager/상시 screen output/두 번째 stream 없음. |
| 26 | NLTokenizer rolling 문장과 fast→quality 보정 유지. 이번에는 quality await를 primary 소비 루프에서 제거하고 안전한 결과 교체를 보강. |
| v26.1 | 한글 경로/manifest를 실제 파일명과 대조. literal #Uxxxx 경로 불허. 루트 한글 보고서는 이제 아래 목록대로 통합/삭제. |

## 유지한 실제 검증 체크리스트

- Apple 단계별 결과를 checksum → native assets/package resolve → compile → XCTest → unsigned device build로 구분한다. 현재 소스에서 첫 오류 원문/해시/도구 버전을 보관한다. 모델 미탑재 빌드 성공은 분리 성공이 아니다.
- 같은 영상 일반 발화 구간의 볼륨 10/50/100%, 원본/저레벨 파일에서 RMS/peak/clipping/STT를 비교한다. 마이크 대체 없이 YouTube 시스템 PCM, 다른 창 초점/창 크기/영상 전환/공유 취소/재시작을 검사한다.
- 깨끗한 음성/낮은 목소리/BGM만/효과음/큰·작은 화자 교대/2명 겹침/3명 겹침/역위상 stereo. gain이 무음/겹침/unknown에 남지 않는지 확인한다. 분리 모델은 합성 변환 오차 외에 일본어 정확도·오분리·화자 연결·처리 시간·원본 fallback을 비교한다.
- 모델 준비 중 Stop/Clear/언어 전환/재시작, 늦은 callback, EOF와 gap, 빈 volatile 철회, 번역 준비 실패와 메뉴 재연결, 번역 재시도/취소가 새 원문을 오염시키지 않는지 확인한다.
- UI는 RAIL/DOCK 전환과 history, 긴 영/일 문장·이모지/결합문자·글자 크기·dark/light·ruby 탭, 여러 줄 gutter 위/중간/아래, 원문/번역 scroll을 확인한다.
- A/B/C 변경 중 분석/AI/저장이 snapshot을 섞지 않는지, run/charge/issue가 문맥에 맞는 뜻인지, 일본어 AI 재구성의 원문·token 범위 보존, 영어 저장 UI 부재를 확인한다.
- 사용자가 고른 테스트 세션에서만 실제 저장. 세션 선택 취소 후 늦은 resolve 응답이 저장하지 않는지, 같은 문장/단어 group과 다른 capture group, screenshot·기존 단어장·토큰 만료/401 재발급·저장 오류 중복 방지를 확인한다.
- 실제 live 모드로 0/1/5/15/30분 진단을 기록하고 이후 1~3시간 history/메모리/스크롤/번역 지연/발열을 확인한다. 짧은 Device Validation과 일반 말소리 대신 노래만으로 통과 판정하지 않는다.

## 삭제/유지 안내

**반드시 삭제 권장 — 최신 소스 ZIP에서 제거한 옛 루트 보고서:**

- `검사결과.md`
- `검토보고서.md`
- `실기검증.md`
- `요구사항대장.md`
- `재검토결과.md`
- `추가검토결과.md`
- `현재상태.md`

예전 날짜의 “최신 상태”가 다음 작업을 오도하지 않도록 유지 요구사항과 절차를 위에 통합했다. 원문 보관이 필요하면 입력 기준 ZIP을 보관한다.

**삭제 가능:** 로컬/CI가 생성한 `BuildOutputs/`, `work/build/`의 오래된 산출물. 단 `BuildOutputs/Sudachi/`와 `BuildOutputs/Separation/`는 생성된 모델/사전이 들어갈 수 있으므로 백업 또는 재생성 가능 여부를 먼저 확인한다. 이번 작업에서 해당 생성 폴더를 삭제한 것은 아니다.

**유지 권장:** `HANDOFF.md`, `README.md`, `Shared/`, `Phase1/`, `Phase2/`, `Tests/`, `Tools/`, `Native/`, `Resources/`, `.github/workflows/apple-validation.yml`, `.gitattributes`, `SHA256SUMS.txt`, `DEPENDENCIES.json`, `Phase2/JPLive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## 이번 산출물

- `JP-Live-local-stage7-20260921.zip`: 전체 앱 소스. 구버전 stage1 ZIP 대신 이 로컬 구현본을 사용한다.
- `JP-Live-worker-stage3-20260921.zip`: Worker 전체 source-only. 원본 대비 변경은 `src/index.js`뿐이며 배포하지 않았다.
- 이 HANDOFF.md는 앱 ZIP에도 포함된다. Translator/Cloud Run은 변경/재포장하지 않았다.
- 최종 로컬 검사: Python 26 + Worker 13 통과, Swift40/Rust1/Python8 구문, Shared17 일치, 프로젝트2 구조 파싱. XCTest 소스는 총122개이며 실행0회. 모델 생성/Apple compile/실기/운영 API/배포는 실행하지 않았다. 공개 모델 카드와 공식 문서만 조회했다.

## stage8.3 로컬 검증 결과

- `Tools/source_checksums.py`: 80 source records generate + exact verify PASS.
- Python repository tests: 26/26 PASS.
- Python Tools/Tests compileall: PASS.
- Swift frontend parse: 40/40 files PASS.
- Linux Swift type-check: `Core.swift + SpeechTimeline.swift + TranscriptBuffer.swift` PASS.
- Shared ↔ Phase1 mirrored source comparison: PASS.
- Tools shell scripts `bash -n`: PASS.
- old 4-argument quality callback static scan: 0.
- manifest literal `#Uxxxx` Unicode-escape path scan: 0.
- randomized `TranscriptBuffer` invariant harness (1000×200 mixed events): PASS; no non-finite/regressing final-row time or multiple-draft invariant violation.

이 검증은 Apple SDK type-check/XCTest/physical-device runtime을 대체하지 않는다. 다음 단계는 Phase 1/2 Apple CI다.
