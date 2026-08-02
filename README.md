# Ampersand — CrossInput

**맥북 트랙패드 하나로 macOS와 삼성 DeX(안드로이드)를 오가세요.**

포인터를 화면 가장자리로 밀면 macOS → DeX 외부 화면으로, 다시 밀면 macOS로 전환됩니다. 폰에 앱을 설치하거나 루팅할 필요가 없습니다 — 무선 디버깅 1회 설정 후 맥북 트랙패드가 DeX 화면의 마우스가 됩니다.

```
┌─ macOS 앱 (Swift, 메뉴 막대) ─┐   ┌─ Android helper (Kotlin) ─┐
│ 트랙패드 캡처 · 엣지 전환        │   │ UHID 가상 마우스 생성/주입   │
└───────────┬──────────────────┘   └────────────┬──────────────┘
            │  ADB over Wi-Fi (무선 디버깅)       │ UHID (루트 불필요)
            └───────────► ────────────► ────────┘
                                          ▼
                              DeX 외부 화면 / 안드로이드 화면
```

## 기능

- **엣지 전환**: 포인터를 화면 가장자리로 밀어 macOS ↔ DeX 전환
- **실제 마우스 동작**: 이동(포인터 가속 포함), 클릭, 휠 — UHID 커널 인터페이스로 네이티브하게 동작
- **폰 화면도 지원**: DeX 미사용 시 일반 안드로이드 화면 제어
- **설치형 앱 불필요**: helper는 ADB로 임시 실행 (scrcpy 방식) — 홈 화면 아이콘/다이얼로그 없음
- **범위**: v1은 mac → Android 단방향 (역방향·키보드는 로드맵 확장 — [ADR-0003](docs/adr/ADR-0003-scope.md))

## 상태

현재 초기 개발 단계입니다. Android 입력 주입(UHID)은 실기기(SM-G977N, Android 12)에서 검증 완료:
마우스 이동/클릭/커서 표시가 DeX 외부 화면에서 정상 동작 확인. macOS 입력 캡처와 앱 UI는 제작 중.

진행 상황: [docs/roadmap.md](docs/roadmap.md) · 설계: [docs/architecture.md](docs/architecture.md)

## 요구 사항

| 구성 요소 | 요구 사항 |
|---|---|
| macOS | 14+ (Apple Silicon 우선) |
| 삼성 갤럭시 | 안드로이드 10+ (DeX 지원 기기) |
| 폰 설정 | 개발자 옵션 → 무선 디버깅 (1회) |

## 개발 환경

| 구성 요소 | 버전 |
|---|---|
| Xcode | 16+ (Swift 6) |
| JDK | 17 |
| Android SDK | platforms;android-35, build-tools;35.0.0 |
| adb | 37.x |
| 실기기 | Galaxy S10 5G (SM-G977N), Android 12 |

## 빠른 시작 (개발)

```sh
# 저장소 셋업 (git hooks, gitignore, 로컬 설정)
./scripts/bootstrap.sh

# Android helper 빌드
./scripts/build-android-helper.sh

# 개발 실행 (메뉴 막대 앱)
./scripts/run-dev.sh
```

## 규칙

이 저장소의 작업 규칙은 [AGENTS.md](AGENTS.md)에 있습니다. 핵심:

- **display ID 하드코딩 금지** — helper가 모든 display를 발견하고 선택 규칙으로 결정
- 최종 앱에 **Electron / Node / Python 런타임 금지** (macOS: Swift, Android helper: Kotlin)
- **실기기 로그 없이 "지원 완료" 선언 금지**
- 오류 시 macOS 포인터 제어 즉시 복구, 비상 복귀 단축키는 Android 연결과 무관하게 항상 동작

## 라이선스

Apache-2.0 — [LICENSE](LICENSE), [NOTICE](NOTICE) 참조.
업스트림 코드 재사용 내역은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
