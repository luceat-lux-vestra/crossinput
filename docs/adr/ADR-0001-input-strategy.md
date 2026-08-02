# ADR-0001: DeX 입력 전달 방식 (UHID)

> 상태: **초안** — Phase 0 leap-scrcpy baseline 결과에 따라 확정.
> 작성: 2026-08-03

## Context

Samsung DeX 외부 화면에 포인터 입력을 전달해야 한다. 후보: (a) UHID 가상 HID 장치, (b) `input` 셸 명령 (root 필요, 속도 제한), (c) Accessibility API (focus/click 전용, 절대 좌표 이동 불가), (d) virtual display + InputManager.
UHID는 root 없이 shell 권한으로 `/dev/uhid`를 사용할 수 있고, 상대/절대 좌표, 버튼, 휠, stylus를 지원한다.

## Decision (초안)

UHID를 입력 전달의 기본 방식으로 사용한다. 단, Phase 0 검증에서 "입력이 DeX 외부 화면으로 전달되지 않음(분류 B)"이 확인되면 라우팅 원인을 먼저 규명한다.

## Alternatives

- `input tap/swipe`: root 없이는 셸에서 사용 가능하지만 상대 이동/휠 부족, 느림.
- Accessibility: move 없음.
- sendevent: 노드당 한 번에 한 장치, 불안정.

## Consequences

- 긍정: 상대/절대/stylus/wheel 전부 가능, 성능 좋음.
- 부정: `/dev/uhid` 접근 제한 환경(향후 Android 버전)에서 재평가 필요.

## Validation

- (완료) Phase 0: UHID 상대 마우스 실기기 검증 — DeX 외부 화면 클릭/이동/커서 표시 확인 (SM-G977N, Android 12)
- (완료) UHID 최소 CLI probe (relative mouse) 동작 확인
- (대기) 설치형 일반 앱에서 `/dev/uhid` 접근 가능 여부 (ADR-0006)

## Revisit 조건

- UHID가 DeX 화면으로 입력을 전달하지 못하면 재평가.
