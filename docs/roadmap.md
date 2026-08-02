# Ampersand Roadmap

> 업데이트: 2026-08-03 (Phase 0 완료, 이름/범위/배포 결정 반영)
> 원본 계획: `DEXCURSOR_IMPLEMENTATION_PLAN.md` (1221줄, 로컬 Downloads에 보관 — 역사적 문서)

## Phase 개요

| Phase | 내용 | 완료 조건 | 상태 |
|---|---|---|---|
| 0 | UHID 입력 검증 (DeX 외부 화면 전달) | 실기기 클릭/이동/커서 표시 확인 | ✅ 완료 (분류 A) |
| 0.5 | 실행 방식 확정 (ADR-0006) | v1은 adb push + 실행 확정, 설치형 앱은 v2 보류 | ✅ 완료 |
| 1 | 저장소 초기화 | bootstrap.sh / build-android-helper.sh / xcodebuild / CI green | 🔄 진행 중 |
| 2 | Android helper 최소 구현 | display discovery + UHID + CXI 프로토콜 | ⏳ |
| 3 | DeX 입력 라우팅 | UHID 입력이 DeX 외부 화면으로 전달 (Phase 0 검증분 활용) | ⏳ |
| 4 | CGEventTap 프로토타입 | fake sink로 입력 캡처 검증 | ⏳ |
| 5 | Edge switching | macOS↔DeX 전환, 100회 반복 통과 | ⏳ |
| 6 | 메뉴 바 앱 + 온보딩 | 설정/상태 UI + 무선 디버깅 페어링 가이드 | ⏳ |
| 7 | 복구·성능 | sleep/wake, 권한 해제, 에러 복구 | ⏳ |
| 8 | 배포 | ad-hoc 서명 + GitHub Releases + Homebrew tap (ADR-0005), adb 번들 (ADR-0004) | ⏳ |

## Phase 0: UHID 입력 검증 — 완료

**결과: 분류 A — UHID 상대 마우스가 DeX 외부 화면을 정상 제어.** (SM-G977N, Android 12)

- 마우스 이동: 1:1 매핑 + 포인터 가속 (실제 마우스와 동일)
- 클릭: DeX(display 2) 윈도우에 배달, 포커스 전환 확인
- 커서 표시: 이동 중 화살표 표시, 유휴 ~3.5초 후 페이드(삼성 기본 UX)
- 입력 경로: app_process (shell uid) UHID — 루트 불필요

## 이슈 분해

- Epic A (Feasibility): A-01~A-07 — Phase 0 완료
- Epic B (Android helper): B-01~B-07
- Epic C (macOS input): C-01~C-07
- Epic D (edge switching): D-01~D-07
- Epic E (productization): E-01~E-07
- Epic F (확장 — dex→mac): F-01~F-07 (ADR-0003 참조: 접근성 터치 + 자체 IME 키보드, v1 이후)

## 확장 범위 (v1 이후, ADR-0003)

- dex→mac 터치: AccessibilityService 캡처 + CGEventPost 주입
- dex→mac 키보드: 자체 IME 앱 (우리 키보드가 활성 IME여야 함), 한글은 텍스트 전송
- 아이패드: 범위 제외 (iPadOS에 CGEventTap 동등 API 없음)

## 진행 로그

- 2026-08-03: 환경 점검 완료 (SM-G977N, Android 12, 무선 ADB 연결됨, DeX 활성 — display 0 휴대폰/2 Desktop/6 HDMI)
- 2026-08-03: leap-scrcpy 서버 APK 빌드 성공 (`app-debug.apk` 5.8MB), 클라이언트 빌드 성공 (`pnpm build`)
- 2026-08-03: UHID 마우스 실기기 검증 완료 — 이동/클릭/커서 표시 (분류 A)
- 2026-08-03: 제품명 Ampersand / 태그라인 CrossInput / 저장소 crossinput (ADR-0002), 범위(ADR-0003), adb 번들(ADR-0004), 배포(ADR-0005), 실행 방식 확정(ADR-0006: v1 = adb push + 실행, 설치형 앱은 v2 보류)
