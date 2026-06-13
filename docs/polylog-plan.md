# Polylog — AI 여행 장소 추천 앱 기획서
### AWS AI 서비스 + Google Places API 기반 여행 비서 앱

> *"여행의 모든 순간이, 하나의 이야기로 남는다."* — 전체 비전 선언은 `archive/vision.md` 참조

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v2.0 PoC |
| 작성일 | 2026년 5월 25일 |
| 개발 난이도 | 중급 |
| 개발 기간 | 약 3주 + 발표 (2026-05-25 ~ 06-16, 12~15주차) |
| 월 예상 비용 | $5 ~ $20 (PoC 기준) |
| 갱신 | 2026-05-27 — 관리자 IAM 발급 가이드(`polylog-iam-guide.md`) 반영: 인증 Cognito→소셜 OAuth+`fn-authorizer`, 공용 `SafeRole-polylog`, `polylog` prefix·CloudShell 배포, CloudFront 미사용. 상세는 `ADR.md` 2.0.3 |
| 갱신 | 2026-06-01 — 플랫폼 **Android 전용**·인증 **Google 단독** 확정(Kakao·iOS 보류, ADR-003/007). |
| 갱신 | 2026-06-06/07 — Lambda **6종→7종**(`fn-planner` 분리, ADR-017), **AWS AI 실사용=Bedrock 단독**(영수증 OCR을 Textract→Bedrock 비전 전환, Translate 철회, ADR-016), 인증 검증 JWKS→tokeninfo. |
| 갱신 | 2026-06-07(오후) — **메뉴 번역은 인앱 분석 폐지, 「구글 렌즈」 위임으로 단일화**(ADR-018). `fn-menu`/`POST /menu`는 배포만 잔존하는 미사용 — 앱 활성 백엔드는 6종. ADR-016 메뉴 부분 대체. |

---

## 1. 프로젝트 개요

### 1.1 프로젝트 소개

Polylog는 GPS 위치와 AI를 결합하여 여행자에게 **맞춤형 장소 추천, 메뉴판 번역, 영수증 기록, AI 일정 관리**를 제공하는 여행 비서 앱입니다.

기존 여행 앱이 지도, 번역, 가이드를 각각 분리해서 제공한다면, Polylog는 **AWS AI 서비스와 Google Places API를 유기적으로 결합**해 하나의 앱에서 여행의 핵심 불편함을 해결합니다.

### 1.2 해결하는 사용자 불편함

| 불편함 | 해결 방법 | 기능 |
|---|---|---|
| "근처에 뭐가 있지?" 매번 검색 피로 | GPS + AI 개인화 맞춤 추천 | 메인: AI 장소 추천 |
| 외국어 메뉴판 해독 곤란 | 사진 한 장으로 OCR + 번역 + 메뉴 추천 | 서브1: 메뉴판 번역 |
| 영수증·지출 관리 번거로움 | 영수증 촬영만으로 자동 가계부 작성 | 서브2: 영수증 기록 |
| 여행 일정 즉흥 변경의 번거로움 | AI 대화만으로 일정 추천·수정 | 서브3: AI 일정 관리 |

### 1.3 핵심 가치

- **AI 개인화 추천**: 단순 검색이 아닌, 사용자 선호도를 반영한 AI 큐레이션
- **AWS AI 서비스 활용**: Amazon Bedrock(Claude)을 텍스트 추론 + 비전 OCR(영수증) + 대화의 다양한 패턴으로 깊이 통합 (원안 3종 → 구현 시 Bedrock 단독으로 압축, ADR-016 / 메뉴 번역은 구글 렌즈 위임, ADR-018)
- **모바일**: Flutter 기반 Android 앱 (iOS 보류, ADR-003)
- **오프라인 친화**: 네트워크 약한 환경에서도 큐잉 후 동기화

### 1.4 앱 구조

```
┌─────────────────────────────────────────────────┐
│          메인: AI 장소 추천                       │
│  GPS + Google Places API + Bedrock 개인화 추천   │
│  (맛집 / 숙소 / 관광지 / 카페)                   │
└─────────────────────────────────────────────────┘
┌───────────────┬────────────────┬────────────────┐
│  서브1         │  서브2          │  서브3          │
│  메뉴판 번역   │  영수증 기록    │  AI 일정 관리   │
└───────────────┴────────────────┴────────────────┘
```

---

## 2. 기능 요구사항

### 2.1 메인: AI 장소 추천

| ID | 요구사항 | 우선순위 |
|---|---|---|
| M-1 | 사용자가 GPS 위치 권한을 허용하면 현재 위치를 자동 수집한다 | 필수 |
| M-2 | 카테고리(맛집, 숙소, 관광지, 카페 등)를 선택하거나 자연어로 입력한다 | 필수 |
| M-3 | Google Places API로 반경 N km 내 장소 후보를 검색한다 | 필수 |
| M-4 | Bedrock Claude가 장소 후보를 분석하여 개인화 추천과 추천 이유를 생성한다 | 필수 |
| M-5 | 추천 결과를 카드 UI(이름, 별점, 거리, AI 추천 이유)로 표시한다 | 필수 |
| M-6 | 추천 이력을 DynamoDB에 저장하고 조회할 수 있다 | 필수 |

**수용 기준**
- GPS 위치 수집 → 추천 결과 표시까지 5초 이내
- 추천 결과에 별점, 거리, AI 추천 이유가 포함
- GPS 권한 미허용 시 수동 위치 입력 대안 제공

---

### 2.2 서브1: 메뉴판 번역

| ID | 요구사항 | 우선순위 |
|---|---|---|
| S1-1 | 메뉴판 사진 촬영 후 텍스트를 추출한다 | 필수 |
| S1-2 | 외국어 메뉴를 한국어로 번역한다 | 필수 |
| S1-3 | 사용자 선호도·알레르기 기반 추천 메뉴를 제시한다 | 필수 |
| S1-4 | 메뉴별 간단한 설명을 제공한다 | 선택 |

**수용 기준**
- 메뉴판 텍스트 추출 정확도 90% 이상 (명확한 인쇄물 기준)
- 알레르기 유발 가능 메뉴 필터링
- 사진 품질 불량 시 재촬영 가이드라인(프레임 오버레이) 표시
- 응답 시간 6초 이내

---

### 2.3 서브2: 영수증 기록

| ID | 요구사항 | 우선순위 |
|---|---|---|
| S2-1 | 영수증 사진 촬영 시 금액·항목·날짜를 자동 추출한다 | 필수 |
| S2-2 | 지출을 카테고리(식사, 교통, 숙박, 쇼핑 등)로 자동 분류한다 | 필수 |
| S2-3 | 현지 통화를 원화로 자동 환산한다 | 필수 |
| S2-4 | 일별·카테고리별 지출 목록을 제공한다 | 필수 |

**수용 기준**
- OCR(Bedrock 비전) 추출 결과는 사용자가 직접 보정(update) 가능
- 카테고리 자동 분류 오류 시 수동 변경 가능
- 환율은 실시간 조회 + 캐싱 적용
- 응답 시간 4초 이내

---

### 2.4 서브3: AI 일정 관리

| ID | 요구사항 | 우선순위 |
|---|---|---|
| S3-1 | AI와 대화형으로 일정을 계획한다 | 필수 |
| S3-2 | AI가 GPS + Google Places API로 근처 장소를 검색하여 일정을 추천한다 | 필수 |
| S3-3 | 추천 결과를 일정에 추가·수정·삭제한다 | 필수 |
| S3-4 | 일정을 타임라인/카드 프레임으로 표시한다 | 필수 |
| S3-5 | 일정 변경 시 자동으로 근처를 재검색하여 대안을 추천한다 | 필수 |

**수용 기준**
- 대화 컨텍스트(이전 대화 이력 + 기존 일정) 유지
- 모호한 요청 시 확인 질문 반환
- 메인 추천 결과를 일정에 바로 추가 가능
- 응답 시간 4초 이내

---

## 3. 비기능 요구사항

### 3.1 성능

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-P1 | AI 장소 추천 응답 시간 | 5초 이내 |
| NFR-P2 | 메뉴판 OCR + 번역 + 추천 응답 시간 | 6초 이내 |
| NFR-P3 | 영수증 분석 응답 시간 | 4초 이내 |
| NFR-P4 | 채팅 일정 추천 응답 시간 | 4초 이내 |

### 3.2 가용성

| ID | 요구사항 |
|---|---|
| NFR-A1 | 서비스 가용성 99% 이상 (PoC 기준) |
| NFR-A2 | 네트워크 단절 시 로컬 큐잉으로 데이터 유실 0% |

### 3.3 보안

| ID | 요구사항 |
|---|---|
| NFR-S1 | 사진·영수증 파일 S3 SSE 암호화 |
| NFR-S2 | IAM 권한 격리 — 공용 실행 역할 `SafeRole-polylog` + `polylog` prefix·`group` 태그 격리 (함수별 분리는 운영 단계 재검토, ADR-012) |
| NFR-S3 | 소셜 OAuth(Google 단독) 기반 사용자 인증 — 클라이언트 직접 연동 (ADR-007, 2026-06-01 Kakao 보류) |
| NFR-S4 | API Gateway Lambda Authorizer(`fn-authorizer`)로 Google ID 토큰을 Google tokeninfo로 검증, 인증된 요청만 허용 (ADR-007 2026-06-07 갱신) |

### 3.4 비용

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-C1 | 월 운영 비용 (무료 티어 적용) | ~$5 |
| NFR-C2 | 월 운영 비용 (무료 티어 종료 후) | $10~$20 이하 |
| NFR-C3 | AWS 결제 알람 설정 | Budgets $20 |

---

## 4. 구현 기술

### 4.1 AWS AI 서비스 (실사용 Bedrock 단독 — 원안 3종에서 Textract·Translate 철회, ADR-016)

| 서비스 | 역할 | 사용 API | 사용 기능 |
|---|---|---|---|
| **Amazon Bedrock (Claude Haiku·Sonnet)** | 자연어 생성·분석·추천·대화 + **비전 OCR**(영수증 사진 직접 판독) | InvokeModel | 메인, 서브2, 서브3 (서브1 메뉴는 구글 렌즈 위임 — ADR-018) |
| ~~Amazon Textract~~ | **철회** — CJK(한/일) 미인식으로 비라틴 메뉴판·영수증 실패 → Bedrock 비전 대체 (ADR-016) | — | — |
| ~~Amazon Translate~~ | **철회** — Bedrock가 OCR·번역을 1콜로 처리 (ADR-016) | — | — |

### 4.2 AWS 인프라 서비스

| 서비스 | 역할 |
|---|---|
| **AWS Lambda** | 서버리스 백엔드 함수 실행 (배포 7종: 핵심 6 + 인가 1 — `fn-planner` 분리 ADR-017 / 앱 활성 호출은 6종, `fn-menu`는 메뉴 렌즈 위임으로 미사용 ADR-018) |
| **Amazon API Gateway** | REST API 엔드포인트 + Lambda Authorizer 인가 |
| **Amazon S3** | 사진·영수증 미디어 저장 (`polylog` prefix) |
| **Amazon DynamoDB** | 구조화 데이터 저장 (`polylog` prefix) |
| **소셜 OAuth (Google 단독)** | 사용자 인증 — 클라이언트 직접 연동 (Cognito 미사용, ADR-007 / Kakao 보류) |
| ~~**Amazon CloudFront**~~ | 미사용·플랫폼 차단 — S3 Presigned URL로 대체 (ADR-008) |
| **Amazon CloudWatch** | 로그·메트릭 모니터링 |

### 4.3 외부 서비스

| 서비스 | 역할 | 사용 기능 |
|---|---|---|
| **Google Places API** | 주변 장소 검색 (POI 데이터) | 메인(Nearby Search), 서브3(Text Search) |
| **ExchangeRate-API** | 실시간 환율 조회 | 서브2(원화 환산) |

### 4.4 클라이언트 기술 스택

| 분류 | 기술 | 비고 |
|---|---|---|
| **프레임워크** | Flutter (Dart) | Android 전용 (iOS 보류, ADR-003) |
| **최소 버전** | Flutter 3.x, Dart 3.x | |
| **UI** | Flutter Widgets | Material Design 3 |
| **카메라** | camera / image_picker 패키지 | 메뉴판·영수증 촬영 |
| **위치** | geolocator 패키지 | GPS 좌표 수집 |
| **네트워크** | dio | REST API 통신 |
| **로컬 DB** | sqflite | 오프라인 큐잉 |
| **인증** | google_sign_in | 소셜 OAuth(Google) 연동 → ID 토큰 (Kakao 보류) |

### 4.5 개발·운영 도구

| 분류 | 도구 |
|---|---|
| **IaC** | AWS SAM |
| **CI/CD** | GitHub Actions |
| **배포·테스트** | 콘솔 CloudShell `sam deploy` (Access Key 미발급 → 로컬 SAM 제약, ADR-013) |
| **버전 관리** | Git / GitHub |

---

## 5. 시스템 구조

### 5.1 전체 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter App (Dart)                        │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐  │
│  │ Camera   │ GPS      │ Text     │ Chat     │ Storage  │  │
│  └────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┘  │
└───────┼──────────┼──────────┼──────────┼──────────┼─────────┘
        │          │          │          │          │
        └──────────┴────┬─────┴──────────┴──────────┘
                        │ HTTPS (Google OAuth ID 토큰 첨부)
                        │ ※ 인증: Google OAuth — 클라이언트 직접 연동 (Kakao 보류)
                        ▼
            ┌───────────────────────┐
            │  Amazon API Gateway   │
            │      (REST API)       │
            │ + Lambda Authorizer   │
            │   (fn-authorizer:     │
            │  tokeninfo 토큰 검증)  │
            └───────────┬───────────┘
                        │
        ┌───────────────┼───────────────────┐
        │               │                   │
        ▼               ▼                   ▼
  ┌────────────┐  ┌────────────┐    ┌────────────┐
  │fn-recommend│  │  fn-menu   │    │fn-schedule │
  │ (장소 추천) │  │ (메뉴판)   │    │ (일정 관리) │
  └─────┬──────┘  └─────┬──────┘    └─────┬──────┘
        │               │                 │
        ▼               ▼                 ▼
  ┌──────────┐   ┌────────────┐    ┌──────────┐
  │ Google   │   │  Bedrock   │    │ Google   │
  │ Places   │   │  비전 OCR  │    │ Places   │
  │+ Bedrock │   │ (1콜 처리) │    │+ Bedrock │
  └─────┬────┘   └─────┬──────┘    └─────┬────┘
        │               │                 │
        └───────────────┼─────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
  ┌──────────┐                  ┌──────────────┐
  │    S3    │                  │  DynamoDB    │
  │ (미디어)  │                  │ (구조 데이터) │
  └──────────┘                  └──────────────┘

  ※ fn-receipt (영수증) 흐름도 동일 구조:
     Bedrock 비전 OCR + 환율 API + Bedrock 분류 → DynamoDB
  ※ fn-planner (대화형 플래너) = fn-schedule에서 분리 (ADR-017):
     Google Places + Bedrock(Haiku 두뇌 + Sonnet 큐레이터) → 동선 제안
```

### 5.2 기능별 처리 흐름

#### 5.2.1 메인: AI 장소 추천

```
[사용자: 카테고리 선택 + GPS 위치]
    ↓
[API Gateway → fn-recommend Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Google Places API (Nearby Search)     │
   │    - 반경 N km, 카테고리, 장소 후보 수집  │
   │    - 이름, 별점, 리뷰, 사진, 영업시간     │
   │ 2. Bedrock Claude                        │
   │    - 입력: 장소 후보 + 사용자 선호도      │
   │    - 출력: 개인화 추천 + 추천 이유        │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB Recommendation 저장 + 앱 카드 UI 표시]
```

#### 5.2.2 서브1: 메뉴판 번역 (구글 렌즈 위임 — ADR-018)

```
[메뉴 화면: 「구글 렌즈 열기」 버튼]
    ↓
[네이티브 채널 polylog/lens → 구글 렌즈 앱 직행]
    ↓ (미설치 시 market:// → 플레이스토어 폴백)
[구글 렌즈: 실시간 카메라 번역 (전 언어 안정)]
```

> ⚠️ **변경(ADR-018, 2026-06-07)**: 인앱 비전 분석(촬영·`fn-menu` 호출·Bedrock 비전 1콜)을 **폐지**하고 구글 렌즈로 단일화했다. 작은 비전 모델 한 콜에 판독·번역·추천을 몰면 품질이 불안정하고, 알레르기는 사진에 정보가 없어 추측일 수밖에 없으며, 환경 제약으로 더 나은 도구를 붙이기 어려웠기 때문이다. `fn-menu`/`POST /menu`는 배포만 잔존하는 **미사용** 엔드포인트다. (원래의 Bedrock 비전 1콜 설계는 ADR-016 이력으로 보존)

#### 5.2.3 서브2: 영수증 기록

```
[영수증 촬영]
    ↓
[S3 업로드]
    ↓
[API Gateway → fn-receipt Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Bedrock Claude 비전 (ADR-016)         │
   │    (총액, 항목, 날짜, 통화 직접 판독)     │
   │ 2. 환율 API → 원화 환산                  │
   │ 3. Bedrock Claude → 카테고리 자동 분류   │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB Expense 저장 + 앱: 일별·카테고리 통계]
```

#### 5.2.4 서브3: AI 일정 관리

```
[사용자 채팅 입력: "내일 관광지 추천해줘"]
    ↓
[API Gateway → fn-planner Lambda]  ※ 대화형 플래너 = fn-schedule에서 분리 (ADR-017)
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. 이전 대화(chats) + 현재 일정(schedules) 로드 │
   │ 2. Bedrock #1 (두뇌, Haiku): 의도 판단·편집  │
   │ 3. Google Places API (Text Search)       │
   │    - 사용자 요청 키워드로 장소 검색        │
   │ 4. Bedrock #2 (큐레이터, Sonnet)          │
   │    - 관광·식사·카페 섞어 방문 순서 동선 제안 │
   └──────────────────────────────────────────┘
    ↓
[사용자 '담기' 시 → fn-schedule이 DynamoDB Schedule 저장]
    ↓
[앱: 타임라인/카드 프레임으로 일정 표시]
```

---

## 6. Lambda 함수

| 함수명 | 역할 | 트리거 | 목표 실행 시간 | AWS 서비스 | 외부 API |
|---|---|---|---|---|---|
| **fn-health** | 헬스체크 | API Gateway | <1초 | — | — |
| **fn-recommend** | AI 장소 추천 | API Gateway | 3~5초 | Bedrock | Google Places |
| ~~**fn-menu**~~ | ~~메뉴판 비전 OCR + 번역 + 추천~~ → **미사용**(메뉴는 구글 렌즈 위임, ADR-018) | API Gateway | — | — | — |
| **fn-receipt** | 영수증 비전 OCR + 가계부 | API Gateway | 3~4초 | Bedrock 비전 (ADR-016) | 환율 API |
| **fn-schedule** | 일정 CRUD + 여행 CRUD | API Gateway | 2~4초 | Bedrock | Google Places |
| **fn-planner** | 대화형 일정 플래너 (fn-schedule 분리, ADR-017) | API Gateway | ~30초 | Bedrock (Haiku·Sonnet) | Google Places |
| **fn-authorizer** | Google ID 토큰 tokeninfo 검증 (무상태) | API Gateway Authorizer | <1초 | — | Google tokeninfo |

### IAM 실행 역할 — 공용 `SafeRole-polylog` (ADR-012)

`iam:CreateRole`이 차단되어 함수별 역할을 만들 수 없으므로, 모든 함수(배포 7종, 앱 활성 호출 6종 — `fn-menu`는 ADR-018로 미사용)가 관리자 사전 생성 공용 역할 `SafeRole-polylog`를 공유한다. SAM `Globals.Function.Role`로 일괄 지정.

| 역할 | 적용 함수 | 포함 권한 |
|---|---|---|
| **SafeRole-polylog** | fn-* 전체 (7종) | `bedrock:InvokeModel`(us-east-1), `dynamodb:*`(polylog*), `s3:*`(polylog*), CloudWatch Logs (textract·translate는 미사용 — ADR-016) |

> 함수별 최소권한 분리는 운영 단계 재검토. `polylog` prefix·`group` 태그로 blast radius를 그룹 내부로 한정(ADR-012).

---

## 7. ERD (Entity Relationship Diagram)

### 7.1 엔티티 개요

DynamoDB 기반 NoSQL 모델. 관계 이해를 위해 관계형 모델 관점으로 정리합니다.

### 7.2 엔티티 정의

#### User (사용자)

| 필드 | 타입 | 설명 |
|---|---|---|
| user_id (PK) | String | 소셜 OAuth Sub ID (Google sub) |
| email | String | 이메일 |
| nickname | String | 닉네임 |
| preferred_language | String | 모국어 (예: ko) |
| dietary_restrictions | List\<String\> | 알레르기·식이 제한 |
| created_at | Timestamp | 가입일 |

#### Trip (여행)

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | UUID |
| user_id (FK) | String | 소유자 |
| title | String | 여행명 |
| destination | String | 목적지 |
| start_date | Date | 시작일 |
| end_date | Date | 종료일 |
| currency | String | 현지 통화 |
| status | Enum | planning / ongoing / completed |

#### Recommendation (AI 추천) — ADR-015

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | 소속 여행 — 파티션 키 |
| created_at (SK) | String | 추천 발생 시각(ISO 8601) — 정렬 키, 누적 이력 시간순 |
| recommendation_id | String | UUID — 외부 참조용(일정에 추가될 때 출처 링크 등) |
| latitude | Number | 검색 위도 |
| longitude | Number | 검색 경도 |
| category | String | 검색 카테고리 |
| places | List\<Place\> | 추천 장소 목록(임베디드) |
| ai_summary | String | Bedrock 추천 요약 |

> **액세스 패턴**: 여행 추천 이력 보기(FR-M.6) = `Query PK=trip_id` 시간순. 동일 좌표·카테고리 재추천 회피는 PoC 범위 외(필요 시 GSI 후속 결정).

#### Place (추천 장소, 임베디드)

| 필드 | 타입 | 설명 |
|---|---|---|
| place_id | String | Google Places ID |
| name | String | 장소명 |
| rating | Number | 별점 |
| distance | Number | 거리 (m) |
| ai_reason | String | AI 추천 이유 |
| address | String | 주소 |

#### Menu (메뉴판 분석) — ADR-015

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | 소속 여행 — 파티션 키 |
| created_at (SK) | String | 촬영 시점(ISO 8601) — 정렬 키 |
| menu_id | String | UUID — 외부 참조용 |
| photo_s3_key | String | 사진 경로 |
| items | List\<MenuItem\> | 메뉴 항목(임베디드) |
| recommended | List\<String\> | 추천 메뉴 item_id 목록 |

> **액세스 패턴**: 여행 중 메뉴판 이력(FR-S1) = `Query PK=trip_id` 시간순. 단건 표시 = 방금 PutItem한 (trip_id, created_at) 키로 GetItem.

#### MenuItem (메뉴 항목, 임베디드)

| 필드 | 타입 | 설명 |
|---|---|---|
| item_id | String | UUID |
| original_name | String | 원문 메뉴명 |
| translated_name | String | 번역된 메뉴명 |
| price | Number | 가격 |
| description | String | AI 설명 |

#### Expense (지출) — ADR-015 (DynamoDB 테이블명: `polylog-receipts`)

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | 소속 여행 — 파티션 키 |
| occurred_at (SK) | String | 결제 시각(ISO 8601) — 정렬 키, "일별 지출" 정렬 자동화 |
| expense_id | String | UUID — 외부 참조용 (테이블의 receipt_id 속성과 동의어) |
| receipt_s3_key | String | 영수증 사진 |
| merchant | String | 상호명 |
| total_amount | Number | 현지 통화 금액 |
| currency | String | 통화 |
| krw_amount | Number | 원화 환산 |
| category | String | 카테고리 (식사/교통/숙박/쇼핑 등) |

> **액세스 패턴**: 일별 지출 목록(FR-S2.4) = `Query PK=trip_id` (자동 시간순) 또는 `SK begins_with "YYYY-MM-DD"`. 카테고리별 집계는 PoC 규모(여행당 30~70건)에서 클라이언트 그룹화로 충분 — 데이터 증가 시 `category-index` GSI 추가 결정.

#### Schedule (일정) — ADR-014 단일 테이블

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | 소속 여행 — 파티션 키 |
| start_time (SK) | String | 시작 시각(ISO 8601) — 정렬 키, 타임라인 자동 정렬 |
| schedule_id | String | UUID — 외부 참조용(채팅 메시지 ↔ 일정 연결 등) |
| title | String | 일정 제목 |
| place_name | String | 장소명 |
| place_id | String | Google Places ID — FR-S3.5 재추천 키 |
| latitude | Number | 위도 |
| longitude | Number | 경도 |
| end_time | String | 종료 시각(ISO 8601) |
| duration_min | Number | 체류 시간(분) |
| notes | String | 메모 |
| source | Enum | manual / ai_recommended |
| chat_message_id | String | (선택) 만든 대화 메시지 id |
| created_at, updated_at | String | ISO 8601 |

> **액세스 패턴**: 타임라인 뷰(FR-S3.4) = `Query PK=trip_id` 한 번에 시간순 정렬. 일별 보기 = `Query PK=trip_id, SK begins_with "YYYY-MM-DD"`. 단건 수정/삭제 = `Update/DeleteItem` with (trip_id, start_time).

#### ChatMessage (대화 이력) — ADR-015 (DynamoDB 테이블명: `polylog-chats`)

| 필드 | 타입 | 설명 |
|---|---|---|
| trip_id (PK) | String | 소속 여행 — 파티션 키 |
| created_at (SK) | String | 메시지 시각(ISO 8601) — 정렬 키, 컨텍스트 로드 순서 보장 |
| message_id | String | UUID — 외부 참조용 (schedule.chat_message_id가 이 값을 가리킴) |
| role | Enum | user / assistant |
| content | String | 메시지 본문 |

> **액세스 패턴**: Bedrock 대화 컨텍스트 로드(FR-S3.1 수용 기준) = `Query PK=trip_id` 한 번으로 시간순 전체 로드 후 프롬프트에 주입. 메시지→일정 역추적은 단방향(Schedule.chat_message_id)만 보장, 일정→메시지 역참조는 PoC 범위 외.

### 7.3 관계 정의

```
User (1) ─────────── (N) Trip
                       │
        ┌──────────────┼──────────────┬──────────────┐
        │              │              │              │
       (N)            (N)            (N)            (N)
  Recommendation     Menu         Expense        Schedule
        │              │
       (N)            (N)
      Place        MenuItem
     (embedded)    (embedded)

Trip (1) ─────────── (N) ChatMessage
```

### 7.4 ERD 다이어그램

```
┌───────────────┐         ┌────────────────┐
│     User      │ 1     N │      Trip      │
│───────────────│─────────│────────────────│
│ user_id (PK)  │         │ trip_id (PK)   │
│ email         │         │ user_id (FK)   │
│ nickname      │         │ title          │
│ preferred_lang│         │ destination    │
│ diet_restrict │         │ start_date     │
└───────────────┘         │ end_date       │
                          │ currency       │
                          │ status         │
                          └───────┬────────┘
                                  │ 1
        ┌─────────────────────────┼────────────────────────┐
        │                         │                        │
        │ N                       │ N                      │ N
┌───────▼───────┐         ┌──────▼──────┐         ┌───────▼───────┐
│Recommendation │         │    Menu     │         │   Expense     │
│───────────────│         │─────────────│         │───────────────│
│ rec_id (PK)   │         │ menu_id(PK) │         │expense_id(PK) │
│ trip_id (FK)  │         │ trip_id(FK) │         │ trip_id (FK)  │
│ latitude      │         │photo_s3_key │         │receipt_s3_key │
│ longitude     │         │ items[]     │         │ merchant      │
│ category      │         │recommended[]│         │ total_amount  │
│ places[]      │         └─────────────┘         │ krw_amount    │
│ ai_summary    │                                 │ category      │
└───────────────┘                                 └───────────────┘

        ┌─────────────────────────┐
        │ N                       │ N
┌───────▼───────┐         ┌──────▼──────┐
│   Schedule    │         │ ChatMessage │
│───────────────│         │─────────────│
│ sched_id (PK) │         │ msg_id (PK) │
│ trip_id (FK)  │         │ trip_id(FK) │
│ title         │         │ role        │
│ location      │         │ content     │
│ start_time    │         └─────────────┘
│ end_time      │
│ source        │
└───────────────┘
```

---

## 8. Use Case

### UC-1: 근처 맛집 AI 추천

**행위자**: 여행자
**사전 조건**: 앱 로그인 상태, 위치 권한 허용
**주요 흐름**:

여행자가 도쿄에서 점심을 먹으려고 합니다. 앱을 열면 메인 화면에 현재 GPS 위치가 표시됩니다. "맛집" 카테고리를 탭하면 fn-recommend Lambda가 호출됩니다. Lambda는 현재 좌표로 Google Places API의 Nearby Search를 호출하여 반경 1km 내 음식점 후보(이름, 별점, 리뷰 수, 가격대, 영업시간)를 수집합니다. 이 후보 목록을 Bedrock Claude에 전달하면, Claude는 단순 나열이 아닌 "평점 4.5의 이 라멘집은 점심 시간에 대기가 짧고 가격대도 합리적입니다. 채식 옵션이 없으니 식이 제한을 확인하세요"와 같은 개인화 큐레이션을 생성합니다. 결과는 카드 UI로 표시되며, 각 카드에 이름, 별점, 거리, AI 추천 이유가 포함됩니다. 사용자가 마음에 드는 장소의 "일정에 추가" 버튼을 누르면 서브3(AI 일정 관리)의 Schedule에 자동 저장됩니다.

**예외 흐름**: GPS 신호가 약한 실내에서는 정확도가 떨어질 수 있으며, 이때 사용자가 수동으로 위치를 검색하여 입력할 수 있습니다. 네트워크 단절 시 로컬 큐에 저장 후 복구 시 재시도합니다.

---

### UC-2: 외국어 메뉴판 해독 및 추천

**행위자**: 여행자
**사전 조건**: 안드로이드 기기에 구글 렌즈(구글 앱) 설치
**주요 흐름**:

여행자가 식당에 자리를 잡고 외국어로 적힌 메뉴판을 받습니다. 앱의 "메뉴판" 탭에서 **「구글 렌즈 열기」 버튼**을 누르면, 네이티브 채널(`polylog/lens`)이 설치된 **구글 렌즈를 선택창 없이 곧장** 엽니다. 여행자는 렌즈의 실시간 카메라 번역으로 메뉴판을 비춰 라틴·CJK 가리지 않고 즉시 번역을 봅니다(ADR-018 — 인앱 비전 분석은 품질·환경 제약으로 폐지하고 렌즈로 단일화). 렌즈가 미설치면 앱이 플레이스토어 설치 페이지로 안내합니다.

**예외 흐름**: 구글 렌즈가 설치돼 있지 않으면 `market://`(없으면 https)로 'Google Lens' 설치 페이지를 열어 설치를 유도합니다.

---

### UC-3: 영수증 자동 가계부

**행위자**: 여행자
**사전 조건**: 환율 API 가용
**주요 흐름**:

식사 후 받은 영수증을 앱의 "영수증" 탭에서 촬영합니다. fn-receipt Lambda가 호출되면 **Bedrock Claude 비전**이 사진을 직접 읽어 총액·항목별 금액·결제 일시·상호명·통화를 구조화 추출합니다(ADR-016 — 한국 영수증의 한글을 Textract가 못 읽어 비전으로 전환). 환율 API로 원화 환산 금액을 계산하고, Bedrock Claude가 상호명과 항목을 보고 카테고리("식사")를 자동 분류합니다. 결과는 DynamoDB Expense에 저장되고, 앱의 지출 화면에 일별·카테고리별 목록이 표시됩니다. 분류가 잘못된 경우 수동으로 변경할 수 있습니다.

**예외 흐름**: 영수증 인쇄가 흐릿한 경우 추출 결과가 부정확할 수 있으며, 사용자가 항목을 직접 보정(update)할 수 있습니다.

---

### UC-4: AI 대화형 일정 추천

**행위자**: 여행자
**사전 조건**: 여행 활성 상태
**주요 흐름**:

여행자가 자유 시간이 생겨 "일정" 탭을 열고 "지금 근처에 가성비 좋은 카페 추천해줘. 분위기 조용한 곳으로"라고 입력합니다. fn-schedule Lambda는 현재 GPS 좌표로 Google Places API의 Text Search에 "cafe"와 위치 바이어스를 전달해 카페 후보를 가져옵니다. 이 후보군과 사용자의 요청 의도("가성비", "조용한 분위기"), 이전 대화 이력, 기존 일정을 Bedrock Claude에 전달하면, Claude는 "도보 7분 거리의 X 카페가 평점 4.5에 가격대도 합리적입니다"와 같은 큐레이션을 제공합니다. 사용자가 확정하면 DynamoDB Schedule에 저장되고 타임라인 UI에 추가됩니다. 이후 "아까 카페 대신 다른 곳 없어?"라고 하면 Lambda는 이전 대화 컨텍스트를 유지하며 근처를 재검색하여 대안을 추천합니다.

**예외 흐름**: 사용자의 요청이 모호한 경우("뭐 할까") Claude는 즉답 대신 "어떤 분위기를 원하세요?"와 같은 확인 질문을 반환합니다.

---

## 9. 예상 비용 (월 1인 PoC 기준)

| 서비스 | 가정 사용량 | 월 비용 |
|---|---|---|
| Bedrock Claude (Haiku 위주 + 비전 OCR, 일부 Sonnet) | ~600회 평균 1K tokens + 이미지 토큰 | ~$1.50 |
| ~~Textract / Translate~~ | 철회 — Bedrock 비전으로 대체 (ADR-016) | $0 |
| Google Places API | 300회 | $0 (월 $200 크레딧 내) |
| Lambda + API Gateway + DynamoDB + S3 | 무료 티어 내 | $0.00 |
| CloudWatch Logs | 1GB | $0.50 |
| **합계 (무료 티어 적용)** | | **약 $2~3** |
| **무료 티어 종료 후** | | **약 $10~15** |

---

## 10. 확장 가능성 (v2.0)

PoC 이후 다음 기능을 확장 가능:

| 기능 | 핵심 기술 | 설명 |
|---|---|---|
| 실시간 통역 | Transcribe Streaming, Polly | 양방향 음성 통역 |
| 자동 여행기 | Step Functions, Bedrock | 하루 데이터 자동 수집 → AI 여행기 생성 |
| 날씨 기반 일정 | OpenWeatherMap API | 날씨 변화에 따른 일정 자동 재추천 |
| 일정 알림 | EventBridge, SNS | 일정 시작 전 푸시 알림 |
| Bedrock Agents | Bedrock Agent API | 능동적 AI 비서 모드 |
| 다국어 UI | Flutter i18n | 한국어 외 UI 지원 |
