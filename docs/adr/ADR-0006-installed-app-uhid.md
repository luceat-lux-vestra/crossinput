# ADR-0006: 설치형 일반 앱 UHID 접근 실험

> 상태: **보류** — v1은 adb push + 실행 방식으로 확정. 설치형 앱은 v2 후보로 유지.
> 작성: 2026-08-03

## Context

무선 디버깅(개발자 옵션)은 일반 사용자 진입장벽이다. helper를 **설치형 일반 APK**(Play 스토어/사이드로드)로 만들어 UHID를 직접 주입할 수 있다면 wireless debugging과 adb 번들(ADR-0004)이 모두 불필요해진다 (Mac은 TCP로 직접 연결).

미지수: `/dev/uhid` 접근이 app uid에서 허용되는가 (SELinux 정책, 장치 권한). 기존 검증은 모두 adb shell(app_process) 실행 — 즉 shell uid 기준. app uid(예: u0_aXXX)의 접근은 한 번도 시험하지 않음.

## Decision (확정: v1은 adb push + 실행)

루팅 불가 전제 하에, **v1의 배포/실행 방식은 "adb push + app_process 실행"으로 확정** (scrcpy와 동일 패턴).

- 사용자는 폰에 아무것도 설치하지 않음 (홈 화면 아이콘/다이얼로그 없음).
- 사용자가 하는 유일한 수동 단계: 무선 디버깅 페어링 1회 (개발자 옵션 → 무선 디버깅 → 페어링 코드).
- adb는 릴리스 배포물에 번들 (ADR-0004).

설치형 일반 APK 방식(`/dev/uhid` app uid 접근)은 **v2 후보로 보류**:
- v1의 adb push 방식이 "사용자가 폰에서 아무것도 안 한다"는 점에서 UX가 오히려 우수.
- Play 스토어 검수 리스크, SELinux 기기별 상이성 등 검증 비용 대비 이득이 현재 단계에서 제한적.

## Alternatives

- 무선 디버깅 1회 페어링 수용: 검증 완료 상태 그대로, 진입장벽만 높음.
- 루팅/시스템 앱: 범위 외.

## Consequences

- 긍정(결과 A): 일반 사용자 진입장벽 제거, adb 번들 불필요, 배포가 Play/사이드로드로 확장됨.
- 부정: SELinux는 Android 버전/기기별로 상이 — 기기 커버리지 확인 필요 (삼성/안드로이드 12 기준 우선).
- 부정(결과 B): v1은 무선 디버깅 유지 — 타겟을 파워유저로 명확히 설정.

## Validation

- (대기) 실기기에서 `/dev/uhid` open 성공 여부 + `dumpsys deviceidle`/SELinux avc 확인
- (대기) 설치형 앱에서 UHID 마우스 생성/클릭 실기기 검증
