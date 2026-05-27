# Polylog — AI 여행 장소 추천 앱 기획서
### AWS AI 서비스 + Google Places API 기반 여행 비서 앱

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v1.0 PoC |
| 작성일 | 2026년 5월 25일 |
| 개발 난이도 | 중급 |
| 개발 기간 | 4주 (12~15주차) |
| 월 예상 비용 | $5 ~ $20 (PoC 기준) |
| 갱신 | 2026-05-27 — 관리자 IAM 발급 가이드(`polylog-iam-guide.md`) 반영: 인증 Cognito→소셜 OAuth(Google/Kakao)+`fn-authorizer`, 공용 `SafeRole-polylog`, `polylog` prefix·CloudShell 배포, CloudFront 미사용, Lambda 6종. 상세는 `ADR.md` 2.0.3 |

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
- **AWS AI 서비스 활용**: Bedrock, Textract, Translate 3종을 깊이 있게 통합
- **크로스 플랫폼**: Flutter로 Android + iOS 동시 지원
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
- Textract 신뢰도 80% 미만 필드는 사용자 확인 요청
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
| NFR-S3 | 소셜 OAuth(Google/Kakao) 기반 사용자 인증 — 클라이언트 직접 연동 (ADR-007) |
| NFR-S4 | API Gateway Lambda Authorizer(`fn-authorizer`)로 소셜 ID 토큰(JWKS) 검증, 인증된 요청만 허용 |

### 3.4 비용

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-C1 | 월 운영 비용 (무료 티어 적용) | ~$5 |
| NFR-C2 | 월 운영 비용 (무료 티어 종료 후) | $10~$20 이하 |
| NFR-C3 | AWS 결제 알람 설정 | Budgets $20 |

---

## 4. 구현 기술

### 4.1 AWS AI 서비스 (3종)

| 서비스 | 역할 | 사용 API | 사용 기능 |
|---|---|---|---|
| **Amazon Bedrock (Claude)** | 자연어 생성, 분석, 추천, 대화 | InvokeModel | 메인, 서브1, 서브2, 서브3 |
| **Amazon Textract** | 문서/영수증 OCR | DetectDocumentText, AnalyzeExpense | 서브1(메뉴판), 서브2(영수증) |
| **Amazon Translate** | 텍스트 번역 | TranslateText | 서브1(메뉴판 번역) |

### 4.2 AWS 인프라 서비스

| 서비스 | 역할 |
|---|---|
| **AWS Lambda** | 서버리스 백엔드 함수 실행 (6종: 핵심 5 + 인가 `fn-authorizer` 1) |
| **Amazon API Gateway** | REST API 엔드포인트 + Lambda Authorizer 인가 |
| **Amazon S3** | 사진·영수증 미디어 저장 (`polylog` prefix) |
| **Amazon DynamoDB** | 구조화 데이터 저장 (`polylog` prefix) |
| **소셜 OAuth (Google/Kakao)** | 사용자 인증 — 클라이언트 직접 연동 (Cognito 미사용, ADR-007) |
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
| **프레임워크** | Flutter (Dart) | 크로스 플랫폼 (Android + iOS) |
| **최소 버전** | Flutter 3.x, Dart 3.x | |
| **UI** | Flutter Widgets | Material Design 3 |
| **카메라** | camera / image_picker 패키지 | 메뉴판·영수증 촬영 |
| **위치** | geolocator 패키지 | GPS 좌표 수집 |
| **네트워크** | dio | REST API 통신 |
| **로컬 DB** | sqflite | 오프라인 큐잉 |
| **인증** | google_sign_in / kakao_flutter_sdk | 소셜 OAuth 연동 → ID 토큰 |

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
                        │ HTTPS (소셜 OAuth ID 토큰 첨부)
                        │ ※ 인증: Google/Kakao OAuth — 클라이언트 직접 연동
                        ▼
            ┌───────────────────────┐
            │  Amazon API Gateway   │
            │      (REST API)       │
            │ + Lambda Authorizer   │
            │   (fn-authorizer:     │
            │    ID 토큰 JWKS 검증)  │
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
  │ Google   │   │  Textract  │    │ Google   │
  │ Places   │   │+ Translate │    │ Places   │
  │+ Bedrock │   │+ Bedrock   │    │+ Bedrock │
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
     Textract AnalyzeExpense + Bedrock → DynamoDB
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

#### 5.2.2 서브1: 메뉴판 번역

```
[메뉴판 사진 촬영]
    ↓
[S3 업로드]
    ↓
[API Gateway → fn-menu Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Textract DetectDocumentText           │
   │    (메뉴 항목별 텍스트 추출)              │
   │ 2. Translate (외국어 → 한국어)           │
   │ 3. Bedrock Claude                        │
   │    - 입력: 메뉴 목록 + 사용자 식이 제한   │
   │    - 출력: 추천 메뉴 + 설명              │
   └──────────────────────────────────────────┘
    ↓
[앱: 원문 / 번역 / 추천 카드 표시]
```

#### 5.2.3 서브2: 영수증 기록

```
[영수증 촬영]
    ↓
[S3 업로드]
    ↓
[API Gateway → fn-receipt Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Textract AnalyzeExpense               │
   │    (총액, 항목, 날짜, 통화 자동 추출)     │
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
[API Gateway → fn-schedule Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. 현재 GPS 위치 참조                     │
   │ 2. Google Places API (Text Search)       │
   │    - 사용자 요청 키워드로 장소 검색        │
   │ 3. Bedrock Claude (대화 컨텍스트 포함)    │
   │    - 이전 대화 + 기존 일정 + 장소 후보    │
   │    - 출력: 추천 일정 + 자연어 응답        │
   └──────────────────────────────────────────┘
    ↓
[사용자 확정 시 DynamoDB Schedule 저장]
    ↓
[앱: 타임라인/카드 프레임으로 일정 표시]
```

---

## 6. Lambda 함수

| 함수명 | 역할 | 트리거 | 목표 실행 시간 | AWS 서비스 | 외부 API |
|---|---|---|---|---|---|
| **fn-health** | 헬스체크 | API Gateway | <1초 | — | — |
| **fn-recommend** | AI 장소 추천 | API Gateway | 3~5초 | Bedrock | Google Places |
| **fn-menu** | 메뉴판 OCR + 번역 + 추천 | API Gateway | 4~6초 | Textract, Translate, Bedrock | — |
| **fn-receipt** | 영수증 OCR + 가계부 | API Gateway | 3~4초 | Textract, Bedrock | 환율 API |
| **fn-schedule** | 대화형 일정 관리 | API Gateway | 2~4초 | Bedrock | Google Places |

### IAM 역할 (최소 권한)

| 역할 | 핵심 권한 |
|---|---|
| **LambdaRecommendRole** | `bedrock:InvokeModel`, `dynamodb:PutItem`, `dynamodb:Query` |
| **LambdaMenuRole** | `textract:DetectDocumentText`, `translate:TranslateText`, `bedrock:InvokeModel`, `s3:GetObject` |
| **LambdaReceiptRole** | `textract:AnalyzeExpense`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| **LambdaScheduleRole** | `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem` |

---

## 7. ERD (Entity Relationship Diagram)

### 7.1 엔티티 개요

DynamoDB 기반 NoSQL 모델. 관계 이해를 위해 관계형 모델 관점으로 정리합니다.

### 7.2 엔티티 정의

#### User (사용자)

| 필드 | 타입 | 설명 |
|---|---|---|
| user_id (PK) | String | 소셜 OAuth Sub ID (Google sub / Kakao id) |
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

#### Recommendation (AI 추천)

| 필드 | 타입 | 설명 |
|---|---|---|
| recommendation_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| latitude | Number | 검색 위도 |
| longitude | Number | 검색 경도 |
| category | String | 검색 카테고리 |
| places | List\<Place\> | 추천 장소 목록 |
| ai_summary | String | Bedrock 추천 요약 |
| created_at | Timestamp | 시각 |

#### Place (추천 장소, 임베디드)

| 필드 | 타입 | 설명 |
|---|---|---|
| place_id | String | Google Places ID |
| name | String | 장소명 |
| rating | Number | 별점 |
| distance | Number | 거리 (m) |
| ai_reason | String | AI 추천 이유 |
| address | String | 주소 |

#### Menu (메뉴판 분석)

| 필드 | 타입 | 설명 |
|---|---|---|
| menu_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| photo_s3_key | String | 사진 경로 |
| items | List\<MenuItem\> | 메뉴 항목 |
| recommended | List\<String\> | 추천 메뉴 ID |
| created_at | Timestamp | 시각 |

#### MenuItem (메뉴 항목, 임베디드)

| 필드 | 타입 | 설명 |
|---|---|---|
| item_id | String | UUID |
| original_name | String | 원문 메뉴명 |
| translated_name | String | 번역된 메뉴명 |
| price | Number | 가격 |
| description | String | AI 설명 |

#### Expense (지출)

| 필드 | 타입 | 설명 |
|---|---|---|
| expense_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| receipt_s3_key | String | 영수증 사진 |
| merchant | String | 상호명 |
| total_amount | Number | 현지 통화 금액 |
| currency | String | 통화 |
| krw_amount | Number | 원화 환산 |
| category | String | 카테고리 |
| occurred_at | Timestamp | 결제 시각 |

#### Schedule (일정)

| 필드 | 타입 | 설명 |
|---|---|---|
| schedule_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| title | String | 일정 제목 |
| location | String | 장소 |
| latitude | Number | 위도 |
| longitude | Number | 경도 |
| start_time | Timestamp | 시작 시각 |
| end_time | Timestamp | 종료 시각 |
| notes | String | 메모 |
| source | Enum | manual / ai_recommended |

#### ChatMessage (대화 이력)

| 필드 | 타입 | 설명 |
|---|---|---|
| message_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| role | Enum | user / assistant |
| content | String | 메시지 본문 |
| created_at | Timestamp | 시각 |

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
**사전 조건**: 사용자 프로필에 식이 제한 정보 입력됨
**주요 흐름**:

여행자가 식당에 자리를 잡고 일본어로만 적힌 메뉴판을 받습니다. 앱의 "메뉴판" 탭으로 사진을 촬영합니다. 사진은 S3에 업로드되고 fn-menu Lambda가 호출됩니다. Lambda는 Textract의 DetectDocumentText로 메뉴판 텍스트를 추출하고, 추출된 일본어 항목들을 Translate API로 한국어로 변환합니다. Bedrock Claude에 사용자의 식이 제한(예: "갑각류 알레르기") 정보와 번역된 메뉴 목록을 전달하면, Claude는 알레르기 유발 메뉴를 제외하고 맥락 있는 추천을 생성합니다. 앱은 원문/번역/추천을 카드 UI로 표시하며, 추천 메뉴가 하이라이트됩니다.

**예외 흐름**: 메뉴판 사진이 흐릿하거나 기울어진 경우 앱은 "사진을 다시 촬영해 주세요" 가이드를 표시하며 촬영 시 가이드라인 프레임을 오버레이합니다.

---

### UC-3: 영수증 자동 가계부

**행위자**: 여행자
**사전 조건**: 환율 API 가용
**주요 흐름**:

식사 후 받은 영수증을 앱의 "영수증" 탭에서 촬영합니다. S3에 업로드되고 fn-receipt Lambda가 호출됩니다. Textract AnalyzeExpense API로 총액, 항목별 금액, 결제 일시, 상호명, 통화를 구조화된 형태로 추출합니다. 환율 API로 원화 환산 금액을 계산하고, Bedrock Claude가 상호명과 항목을 보고 카테고리("식사")를 자동 분류합니다. 결과는 DynamoDB Expense에 저장되고, 앱의 지출 화면에 일별·카테고리별 목록이 표시됩니다. 분류가 잘못된 경우 수동으로 변경할 수 있습니다.

**예외 흐름**: 영수증 인쇄가 흐릿한 경우 Textract 결과의 신뢰도가 낮게 반환됩니다. 신뢰도 80% 미만 필드는 사용자에게 확인을 요청합니다.

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
| Bedrock Claude (Haiku 위주) | 500회 평균 1K tokens | $1.00 |
| Textract DetectDocumentText | 50회 | $0.08 |
| Textract AnalyzeExpense | 30회 | $0.30 |
| Translate | 30,000자 | $0.45 |
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
