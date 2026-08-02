# THIRD_PARTY_NOTICES.md

Ampersand가 재사용/파생한 모든 업스트림 코드와 자산의 출처를 기록합니다.
AGENTS.md 하드 룰 7: **upstream 코드를 복사하거나 파생하면 반드시 이 파일을 갱신**합니다.

| 구성 요소 | 출처 | 버전/커밋 | 라이선스 | 사용 방식 | 이 저장소 내 위치 |
|---|---|---|---|---|---|
| leap-scrcpy | https://github.com/yume-chan/leap-scrcpy | `f9aaf1b05118261d75b82ba88b462f08e37eecdc` | ISC | Phase 0 baseline 재현(수정 없음) 및 UHID/HID 아이디어 참고 | `leap-scrcpy/` (gitignored checkout), `docs/research/` |
| Deskflow | https://github.com/deskflow/deskflow | 1.26.0 (macOS arm64) | GPL-3.0 | Phase 0 검증용 Deskflow 서버 (개발 도구, 배포물에 미포함) | 별도 설치 `/Applications/Deskflow.app` |

## 사용 규칙

- 위 표는 조사(inventory) 목적이며, 아직 코드가 복사되지는 않았습니다.
- 코드를 복사/파생하기 시작하면 항목을 세분화: 개별 파일마다 출처 커밋과 라이선스를 명시하고, 파일 상단에 원본 저작권 고지를 유지합니다.
- 라이선스 호환성 문제가 있는 구성 요소(GPL 등)는 최종 배포물에 포함하지 않습니다.
