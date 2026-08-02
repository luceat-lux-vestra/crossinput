# Ampersand Testing Guide

> 실기기 검증 프로토콜. AGENTS.md 하드 룰 2(실기기 로그 없이 검증 선언 금지)와 연계.

## 일반 원칙

- 에뮬레이터/로컬 테스트 통과 ≠ 검증 완료.
- "동작한다"는 주장에는 다음 중 하나를 첨부:
  1. 실기기 `dumpsys display` 로그
  2. ADB `logcat` excerpt (payload/내용 제외 — 하드 룰 4)
  3. 영상/화면 캡처
  4. 검증 절차를 재현할 수 있는 명령 목록

## 검증 환경 (현재)

| 항목 | 값 |
|---|---|
| 기기 | Galaxy S10 5G (SM-G977N, beyondxks) |
| Android | 12, API 31 |
| ADB | 37.0.1, 무선 디버깅 (mDNS TLS) |
| DeX | 유선 HDMI 외부 화면 1920x1080 |

## DeX 입력 라우팅 검증 프로토콜

1. 사전 확인: `adb shell dumpsys display` — DeX 활성 확인 (Desktop display ON, 휴대폰 display DOZE)
2. 입력 주입 후 `adb shell getevent -lt` / `logcat`으로 포인터 이벤트 확인
3. 시각 확인: DeX 화면(외부 모니터)에 포인터가 보이는지, 휴대폰 화면에 입력이 가는지
4. 각 검증 항목에 대해 10회 이상 반복

### 검증 항목 (R1)

| # | 항목 | 통과 기준 |
|---|---|---|
| 1 | 상대 mouse | DeX 화면에 포인터 표시, 전체 해상도 이동 |
| 2 | 절대 mouse | 좌표-포인터 위치 일치 |
| 3 | 절대 stylus | hover 이동 |
| 4 | 복합 mouse (wheel) | 좌/우클릭, 드래그, 수직/수평 스크롤 |
| 5 | 앱 전환 후 입력 유지 | 포커스가 바뀌어도 DeX 화면으로 전달 |

## edge switching 안정성 (Phase 5)

- 100회 연속 edge 전환 반복 테스트 통과 전까지 완료 선언 금지.
- 실패 케이스마다 상태 머신 로그 + 복구 경로 검증.
