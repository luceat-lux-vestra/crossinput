# ADR-0004: ADB 번들링 (릴리스 배포물에 최신 platform-tools 포함)

> 상태: **확정**
> 작성: 2026-08-03

## Context

v1은 ADB over Wi-Fi (무선 디버깅)로 helper를 실행한다. 사용자에게 adb 설치를 강제할 수 없으므로 제품 바이너리에 adb를 포함한다. 선례: scrcpy가 자체 adb 번들 배포.

## Decision

1. **릴리스 시 최신 platform-tools의 adb 바이너리를 배포물에 포함** (CI에서 다운로드/검증 자동화).
   - macOS: Apple Silicon/Intel용 선택 (또는 universal 바이너리 사용 시 단일)
   - Windows/Linux는 범위 외 (macOS 앱이므로)
2. **adb 해석 우선순위 (fallback 체인)**:
   - 환경변수 오버라이드 (`AMPERSAND_ADB`)
   - 번들 adb (기본)
   - 시스템 adb (`ANDROID_HOME`/PATH) — 사용자 설정 시
3. **라이선스**: adb는 Apache-2.0 — `THIRD_PARTY_NOTICES.md`에 버전 명시 기록 (AGENTS.md 규칙 7).
4. **무선 디버깅 페어링**: Mac 앱이 온보딩에서 가이드 (개발자 옵션 → 무선 디버깅 → 페어링 코드). 1회성.

## Alternatives

- 시스템 adb 의존: 대다수 사용자가 설치 안 함 — 배포 실패.
- 일반 설치형 앱 + TCP 직접 연결 (adb 불필요): `/dev/uhid`가 app uid에서 접근 가능해야 함 — **실험으로 검증 예정 (ADR-0006 참조)**, 성공 시 adb 대체 경로 가능.

## Consequences

- 긍정: 사용자 환경과 무관하게 동작 보장. scrcpy 선례.
- 부정: 배포물 크기 증가 (~4MB), 릴리스마다 platform-tools 동기화 필요 (CI로 자동화).

## Validation

- (대기) CI 릴리스 파이프라인: platform-tools 다운로드 → adb 버전 확인 → 번들 → notarization 파이프라인과 연동
