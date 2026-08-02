# ADR-0003: 지원 범위 (mac→Android 단방향 우선, 프로토콜은 양방향 대비)

> 상태: **확정**
> 작성: 2026-08-03

## Context

제품 본질은 "입력 브리지"다. 우선 방향(macOS 입력 → Android)은 CGEventTap 캡처 + UHID 주입으로 이미 실기기 검증 완료. 반대 방향(dex→mac)도 사용자 요청으로 검토했다. 아이패드(iPadOS)는 CGEventTap 동등 API가 없어 현재 아키텍처로 입력 캡처가 불가능하다.

## Decision

1. **v1 출시 범위는 mac → Android 단방향** (DeX 외부 화면 + 휴대폰 화면 모두). DeX 미사용 Android에서도 폰 화면 제어 동작.
2. **CXI 프로토콜은 메시지 타입 추가만으로 양방향 확장 가능하도록 설계** (방향 접두사 없이 메시지 타입 스페이스 분리, 추후 타입 추가).
3. 반대 방향 확장은 다음 경로로만 가능함을 명시:
   - Android 터치 캡처: **AccessibilityService** (루트 불필요, 터치 제한적)
   - Android 소프트웨어 키보드 캡처: **자체 IME 앱** (`InputMethodService`, 루트 불필요, 우리 키보드가 활성 IME여야 함)
   - macOS 주입: `CGEventPost`
4. **아이패드는 범위 제외** (기술적으로 불가능한 건 아니나 별도 설계 필요).

## Alternatives

- 처음부터 양방향 구현: v1 복잡도 증가, 출시 지연. Android 입력 캡처의 UX(키보드 전환 등)가 미검증.
- 아이패드 포함: iPadOS에 CGEventTap 없음 — 화면 공유/관리 프로필 등 전혀 다른 아키텍처 필요.

## Consequences

- 긍정: v1 검증 완료 범위로 빠른 출시. 프로토콜 확장 여지는 유지.
- 부정: 반대 방향은 별도 제품(폰 → Mac 무선 입력 장치)의 성격을 띠게 됨. Android 키보드 캡처는 GBoard 등 타 IME 입력을 받을 수 없음.

## Validation

- (완료) UHID 마우스: DeX 외부 화면 클릭/이동/커서 표시 실기기 검증 (SM-G977N)
- (대기) CXI 확장 설계: 확장 메시지 타입 정의 시 이 ADR 참조
