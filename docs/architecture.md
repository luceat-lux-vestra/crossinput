# Ampersand Architecture

> 상태: 초안 (Phase 1 진행 중 — 확정 전 변경 가능)

## 목표

macOS 메뉴 막대 앱. 맥북 트랙패드 포인터를 화면 가장자리로 밀면 Samsung DeX 외부 화면(또는 일반 Android 화면)으로 전환되고, 다시 밀면 macOS로 복귀합니다.

> 범위: v1은 mac → Android 단방향 (ADR-0003). 확장(dex→mac 터치/키보드)은 v1 이후.

## 시스템 구성

```
┌───────────────────────────── macOS (Swift 6) ─────────────────────────────┐
│ Menu Bar UI  Edge Switch State Machine  CGEventTap (입력 캡처)            │
│ Connection Manager ──► adb subprocess (ADB over Wi-Fi)                    │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ ADB stdin/stdout framing (CXI protocol)
┌───────────────────────────────────▼──────────────────────────────────────┐
│                        Android helper (Kotlin)                           │
│  app_process entrypoint  │  display discovery (DisplayManager)           │
│  UHID 생성/주입  │  display/rotation/상태 보고                            │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ UHID (가상 HID 장치)
                              ┌─────▼─────┐
                              │ DeX 화면  │ (외부 display, 예: 1920x1080)
                              └───────────┘
```

## 기술 스택

| 계층 | 기술 | 제약 |
|---|---|---|
| macOS 앱 | Swift 6, SwiftUI, AppKit, CoreGraphics, Quartz Event Services, Swift Concurrency | Electron/Node/Python 금지 |
| 빌드 | SPM, XCTest, Xcode project | macOS 14+, Apple Silicon 우선 |
| Android helper | Kotlin, Java 17, Gradle Kotlin DSL, app_process 실행 | minSdk는 S10 5G 지원 범위 |
| 통신 | ADB over Wi-Fi (무선 디버깅), CXI 바이너리 프로토콜 | — |
| 라이선스 | Apache-2.0 + LICENSE, NOTICE, THIRD_PARTY_NOTICES.md | — |

## 핵심 컴포넌트 (macOS)

- **App**: 메뉴 막대 UI, 온보딩, 상태 표시
- **InputCapture**: CGEventTap — 입력 독점(suppression), delta 보존, 커서 숨김/표시, edge warp
- **EdgeSwitch**: 상태 머신 — DISABLED/DISCONNECTED/CONNECTING/MAC_ACTIVE/EDGE_ARMED/DEX_ACTIVE/RECOVERING/ERROR
- **AndroidBridge**: adb subprocess 관리, 프로토콜 직렬화/역직렬화
- **Protocol**: CXI 메시지 정의 (Swift, golden fixture 테스트)
- **Diagnostics**: 로그, 상태 보고
- **Settings**: 설정 저장 (UserDefaults)

## 핵심 컴포넌트 (Android helper)

- **Main**: app_process 진입점, stdin/stdout 이벤트 루프
- **DisplayDiscovery**: DisplayManager로 모든 display 발견/보고
- **HidDeviceManager**: UHID 생성/파괴/보고서 주입
- **Protocol**: CXI 메시지 정의 (Kotlin, golden fixture 테스트)

## 디자인 결정

확정된 결정은 [docs/adr/](adr/)에 ADR 형식으로 기록합니다.

## 검증 전략

- [docs/testing.md](testing.md)의 프로토콜 준수
- 실기기(SM-G977N) ADB 로그 + 화면 확인 없이 검증 선언 금지
