# Contributing to Ampersand

## 시작 전

1. [AGENTS.md](AGENTS.md) 읽기 — 하드 룰을 위반한 PR은 거절됩니다.
2. [docs/roadmap.md](docs/roadmap.md)에서 작업 중인 Phase 확인.
3. 관련 문서(docs/, protocol/)를 먼저 읽고 작업 시작.

## 작업 규칙

- **PR 병합 금지 조건**: 실기기(또는 명시된 검증 절차) 검증 기록이 없는 PR, docs/adr/ 없이 행한 결정.
- 프로토콜 변경은 `protocol/protocol.md` + `protocol/fixtures/` golden fixture 동시 갱신 필수.
- upstream 코드를 복사하면 `THIRD_PARTY_NOTICES.md` 갱신 필수.

## PR 체크리스트

- [ ] build + lint + 관련 테스트 통과
- [ ] 검증 기록 첨부 (실기기 로그, 화면 캡처, 또는 재현 가능한 명령 목록)
- [ ] 결정 사항이 있으면 `docs/adr/`에 ADR 작성
- [ ] 문서 갱신 (README / docs / protocol)

## 이슈 템플릿

- [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/) 참조.
