# ADR-0005: 배포 전략 (ad-hoc 서명 + GitHub Releases + Homebrew tap)

> 상태: **확정** (계정/수익화 판단 시점에 재평가)
> 작성: 2026-08-03

## Context

Apple Developer 계정($99/년) 없이 일반 사용자가 사용할 수 있는 배포 경로가 필요하다. 서명 없는 앱은 Gatekeeper에서 "손상됨"으로 열리지 않으므로 최소한 ad-hoc 서명이 필요하다.

## Decision

1. **배포 경로 2개 병행**:
   - **GitHub Releases**: ad-hoc 서명(`codesign -s -`)된 `.app` zip 배포. 사용자는 "우클릭 → 열기" 1회 수행.
   - **Homebrew tap** (`brew install`): brew가 quarantine을 자동 제거하므로 계정 없이 무마찰 설치. 업데이트 자동화 가능.
2. **CI 자동화**: 릴리스 파이프라인에서 ad-hoc 서명 + zip 패키징 + Homebrew tap 저장소 갱신(버전/해시)까지 자동화.
3. **완전 무마찰(더블클릭 설치)은 유료 계정 + notarization 필요** — 제품이 보급 단계에 도달하면 재평가 (이 결정을 리버스하지 않고 확장).

## Alternatives

- 개발자 계정 즉시 취득: 비용 + 아직 제품 미완성 상태에서 조기 확정.
- 서명 없이 배포: Gatekeeper "손상됨" — 사실상 사용 불가.
- TestFlight/App Store: 계정 필요, DeX 입력 캡처(접근성 권한) 성격상 스토어 검수 리스크 있음.

## Consequences

- 긍정: 계정 없이 즉시 배포 가능. 기술 유저에게 표준적인 경로.
- 부정: 일반 사용자는 "우클릭 → 열기" 마찰 (Homebrew 사용자는 거의 없음).
- 부정: Homebrew tap은 초기에는 무료 GitHub 저장소로 운영 가능.

## Validation

- (대기) CI 릴리스 파이프라인에서 ad-hoc 서명된 앱의 Gatekeeper 동작 확인 (다운로드 → 우클릭 열기)
- (대기) Homebrew tap 설치/업그레이드 e2e 확인
