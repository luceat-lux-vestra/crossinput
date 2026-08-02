# AGENTS.md

Ampersand 작업 시 에이전트(및 개발자)가 반드시 따라야 하는 규칙.

## 절대 금지 (Hard rules)

1. **포인터 절대 가두지 말 것** — macOS 포인터를 잡아두는 코드는 어떤 경로로도 허용되지 않음. 예외: 사용자가 명시적으로 승인한 테스트 전용 스크립트.
2. **실기기 로그 없이 "검증 완료" 선언 금지** — 에뮬레이터, 로컬 테스트만으로 성공 주장 불가. 실기기(SM-G977N) ADB 로그 + 화면 확인이 필요.
3. **display ID 2 하드코딩 금지** — DeX display ID는 기기/설정에 따라 다름. helper는 `DisplayManager`로 모든 display를 발견하고 문서화된 선택 규칙으로 결정.
4. **키 입력 / 클립보드 / 입력 payload 로깅 금지** — 키코드·클립보드 내용·HID report payload를 로그에 남기지 않음. 디버그 시 메타데이터(타입, 길이, 방향)만.
5. **suppression 코드는 timeout + fail-safe 필수** — 입력 가로채기(suppression)에는 반드시 타임아웃과 해제 경로가 있어야 하며, 어떤 실패 경로에서도 포인터는 사용자에게 즉시 복귀.
6. **프로토콜 변경 시 fixture + protocol.md 갱신** — 프로토콜 메시지를 바꾸면 `protocol/protocol.md`와 `protocol/fixtures/`의 golden fixture를 함께 갱신해야 함.
7. **upstream 코드 복사 시 THIRD_PARTY_NOTICES.md 갱신** — 어떤 파일을 어느 upstream(저장소, commit, 라이선스)에서 복사/파생했는지 기록.
8. **Electron / Node / Python 런타임 최종 앱 금지** — macOS 앱은 Swift, Android helper는 Kotlin. (개발 도구는 제외 — 예: 문서 생성 등)
9. **클라우드 / root / Knox 우회 금지** — DeX 제어는 기기 로컬 공개 API(UHID, DisplayManager 등)만 사용.

## 검증 기준

- "동작한다"는 주장은 다음 중 하나를 첨부: 실기기 `dumpsys display` 로그, ADB `logcat` excerpt, 영상/화면 캡처, 또는 검증 절차를 재현할 수 있는 명령 목록.
- DeX 입력 라우팅 검증은 `docs/testing.md`의 프로토콜을 따름.
- 100회 edge 전환 반복 테스트 통과 전까지 edge switching 안정성 완료 선언 금지.

## 작업 흐름

1. 작업 전에 관련 문서(docs/, protocol/)부터 읽기
2. 코드 변경 후: build + lint + 관련 테스트 실행
3. 검증 결과를 `docs/research/` 또는 이슈/PR에 기록
4. PR은 검증 기록 없이 병합 금지

## 문서 요구 사항

- 결정 사항은 `docs/adr/`에 ADR 형식(맥락/결정/대안/영향/검증/재검토 조건)으로 기록
- 실행 명령과 버전은 재현 가능하게 기록 (문서에 명령 + 의존성 버전 포함)
