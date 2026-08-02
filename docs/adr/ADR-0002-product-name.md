# ADR-0002: 제품명 / 브랜드 (Ampersand + CrossInput)

> 상태: **확정**
> 작성: 2026-08-03

## Context

기존 이름 "DeXCursor"는 (a) DeX(삼성 전용)에 제품을 한정하고, (b) 본질(기기 간 입력 연동 브리지)을 표현하지 못하며, (c) "InputBridge"는 상용 제품과 충돌한다. UHID 입력 주입은 DeX뿐 아니라 일반 Android 화면에도 동작하므로 이름을 기기/제조사 중립으로 바꾼다.

## Decision

| 영역 | 이름 |
|---|---|
| 제품/브랜드명 (사용자에게 보이는 이름) | **Ampersand** (`&` 로고) |
| 태그라인 | **CrossInput** — "Ampersand — cross-input between Mac and Android" |
| 기술 식별자 (저장소/폴더/패키지/프로토콜) | **crossinput**, 패키지 `com.crossinput.helper`, 프로토콜 접두사 **CXI** |

- 저장소명: `crossinput`
- Swift 패키지: `Ampersand` (라이브러리 `AmpersandCore`, 실행 파일 `AmpersandApp`)
- Android rootProject: `crossinput-helper`

## Alternatives

- DeXCursor 유지: DeX 한정, 확장 방향과 불일치.
- InputBridge: 상용 제품과 이름 충돌 (사용 불가).
- CrossInput 단독: 정확하지만 일반적이고 브랜딩이 약함.
- UniInput/DeXBridge/Shuttle 등: 의미는 좋으나 Ampersand(브랜딩)+CrossInput(설명) 조합이 역할 분리가 명확함.

## Consequences

- 긍정: 기기/제조사 중립, 확장(폰→Mac 키보드/터치) 커버, 브랜딩 요소(`&`) 확보.
- 부정: "DeX" 키워드가 이름에서 사라져 검색 발견성은 다소 낮아짐 (문서/태그라인에서 DeX 언급으로 보완).

## Validation

- (완료) 저장소 폴더명/패키지/프로토콜 접두사 일괄 리네임
- (대기) Android helper 빌드 (`./gradlew assembleDebug`) 통과
- (대기) macOS SPM 빌드 (`swift build`) 통과
