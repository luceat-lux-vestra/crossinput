# Upstream 조사 Inventory (Phase 0 전초)

> 목적: Ampersand의 기술 기반을 결정하기 위한 후보 조사.
> 조사일: 2026-08-03. 버전/커밋은 조사 시점 기준.

## 1. leap-scrcpy (yume-chan) — Phase 0 검증 기반으로 채택

- 저장소: https://github.com/yume-chan/leap-scrcpy
- 커밋: `f9aaf1b05118261d75b82ba88b462f08e37eecdc` ("chore: cache gradle packages")
- 라이선스: ISC
- 구조:
  - `server/` — Android side. Kotlin, app_process 실행, `/dev/uhid` 직접 조작 (root 불필요). `DisplayManagerGlobal.getDisplayInfo(0)` — **display 0 하드코딩**.
  - `src/` — TypeScript 클라이언트. `@yume-chan/adb`로 ADB 연결, APK 푸시, app_process spawn, stdin/stdout 프로토콜.
- 동작: Deskflow(Input Leap 계열) 서버에 "Android"라는 이름의 클라이언트로 접속. 포인터는 절대 좌표 stylus UHID로 전송. 회전 매핑(RotationMapper) 포함.
- 이슈: 데스크톱 display를 전혀 모름 — DeX 외부 화면 라우팅은 미검증.
- 재사용 후보: UHID 생성/주입 방식, HID descriptor, 프로토콜 framing 아이디어.

## 2. deskflow-android (jglanz) — 참고만 (기반 채택 안 함)

- 저장소: https://github.com/jglanz/deskflow-android
- 문제: DeX 외부 화면으로 입력이 전달되지 않는 공개 이슈 존재 (휴대폰 화면으로만 전달, 포인터 안 뜸).
- 결론: 참고 자료로만 사용.

## 3. InputShare-mac (wafflexyzz) — 기반 채택 안 함

- 저장소: https://github.com/wafflexyzz/InputShare-mac
- 문제: Windows 중심, 빌드 불가 확인. 사용 금지.

## 4. Deskflow (deskflow) — 검증용 서버로 사용

- 저장소: https://github.com/deskflow/deskflow
- 버전: 1.26.0 (macOS arm64)
- 라이선스: GPL-3.0 — **최종 배포물에 포함 금지**, 개발/검증 도구로만 사용.
- 용도: Phase 0에서 Mac을 Deskflow 서버로, leap-scrcpy 클라이언트의 입력 소스로 사용.

## 5. scrcpy (Genymobile) — 참고

- UHID 입력 방식의 원조. leap-scrcpy가 파생한 구조의 근원.
- 라이선스: Apache-2.0. 필요 시 참고 (복사 시 THIRD_PARTY_NOTICES.md 갱신).

## 재사용 판정

| 후보 | 판정 | 사유 |
|---|---|---|
| leap-scrcpy | Phase 0 재현 + 아이디어 참고 | 수정 없이 빌드 가능, ADB 기반, UHID 방식 |
| deskflow-android | 참고만 | DeX 라우팅 미해결 |
| InputShare-mac | 사용 금지 | 빌드 불가, Windows 중심 |
| Deskflow | 검증 도구로만 | GPL-3.0 배포 제약 |
| scrcpy | 참고 | UHID 방식의 원조 |
