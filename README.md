# Ampersand

macOS 메뉴 막대 앱: 맥북 트랙패드 포인터를 화면 가장자리로 밀어 macOS와 Samsung DeX 외부 화면 사이에서 전환합니다.

```
macOS (Swift) ──ADB over Wi-Fi──► Android helper (Kotlin) ──UHID──► DeX 외부 화면
```

## 상태

⚠️ **기술 실행 가능성 검증 단계 (Phase 0~3)** — 제품 UI는 아직 없습니다.

진행 상황: [docs/roadmap.md](docs/roadmap.md) / [docs/architecture.md](docs/architecture.md)

## 필수 규칙

이 저장소의 작업 규칙은 [AGENTS.md](AGENTS.md)에 있습니다. 핵심만 요약:

- **display ID 하드코딩 금지** — helper가 모든 display를 발견하고 선택 규칙으로 결정
- 최종 앱에 **Electron / Node / Python 런타임 금지** (macOS: Swift, Android helper: Kotlin)
- **실기기 로그 없이 "지원 완료" 선언 금지**
- 오류 시 macOS 포인터 제어 즉시 복구, 비상 복귀 단축키는 Android 연결과 무관하게 항상 동작

## 개발 환경 요구 사항

| 구성 요소 | 버전 | 비고 |
|---|---|---|
| macOS | 14+ | Apple Silicon 우선 |
| Xcode | 16+ | Swift 6 |
| JDK | 17 | sdkman: `17.0.18-amzn` |
| Android SDK | platforms;android-35, build-tools;35.0.0 | `~/Library/Android/sdk` |
| adb | 37.x | wireless debugging |
| 실기기 | Galaxy S10 5G (SM-G977N) | Android 12, API 31 |

## 빠른 시작 (개발)

```sh
# 저장소 셋업 (git hooks, gitignore, 로컬 설정)
./scripts/bootstrap.sh

# Android helper 빌드
./scripts/build-android-helper.sh

# 개발 실행 (메뉴 막대 앱)
./scripts/run-dev.sh
```

## 라이선스

Apache-2.0 — [LICENSE](LICENSE), [NOTICE](NOTICE) 참조.
업스트림 코드 재사용 내역은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
