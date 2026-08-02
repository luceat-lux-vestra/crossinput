# Ampersand Troubleshooting

문제 해결 가이드 (작성 중 — 검증 중 발견되는 문제를 여기에 기록)

## ADB

| 증상 | 원인/해결 |
|---|---|
| `adb devices`에 기기 없음 | 무선 디버깅 페어링 갱신 필요. 설정 → 개발자 옵션 → 무선 디버깅에서 페어링 코드 재등록 |
| transport 연결 끊김 | Wi-Fi 변경, 절전. `adb reconnect` 시도 |
| `no devices/emulators found` (Node 클라이언트) | adb server(5037)가 실행 중인지 확인: `adb start-server` |

## DeX

| 증상 | 원인/해결 |
|---|---|
| DeX 화면이 안 켜짐 | HDMI 케이블/어댑터 확인, 설정 → Samsung DeX 실행 |
| 입력이 휴대폰 화면으로 전달됨 | Phase 0 분류 B — display 라우팅 문제. `docs/research/leap-scrcpy-baseline.md` 참조 |
