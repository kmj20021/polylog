# AI 여행 동행자 (AI Travel Companion)
### AWS AI 서비스 기반 종합 여행 비서 앱 기획서

| 항목 | 내용 |
|---|---|
| 프로젝트명 | AI 여행 동행자 |
| 버전 | v1.0 |
| 작성일 | 2026년 5월 19일 |
| 개발 난이도 | 중상급 |
| 예상 개발 기간 | 7 ~ 10주 |
| 월 예상 비용 | $10 ~ $30 (PoC 기준) |

---

## 1. 프로젝트 개요

### 1.1 프로젝트 소개

AI 여행 동행자는 카메라, 음성, 텍스트 등 다양한 입력을 통해 여행자에게 실시간으로 도움을 제공하는 멀티모달 AI 비서 앱입니다. 여행지에서 마주치는 모든 상황 — 낯선 건물 앞에서의 호기심, 외국인과의 대화, 메뉴판 해독, 일정 관리, 가계부 정리 — 을 하나의 앱이 끊김 없이 해결합니다.

기존 여행 앱이 지도, 번역, 가이드를 각각 분리해서 제공한다면, 이 프로젝트는 **AWS의 다양한 AI 서비스를 유기적으로 결합**해 사용자가 앱을 전환하지 않고도 모든 여행 컨텍스트를 처리할 수 있게 합니다.

### 1.2 해결하는 사용자 불편함

| 불편함 | 해결 방법 |
|---|---|
| 낯선 장소·건물에 대한 정보 부재 | 카메라로 비추면 위치 정보와 AI 분석으로 즉시 설명 제공 |
| 외국인과의 의사소통 장벽 | 실시간 음성 통역 (양방향) |
| 외국어 메뉴판 해독 곤란 | 사진 한 장으로 OCR + 번역 + 메뉴 추천 |
| 여행 일정 즉흥 변경의 번거로움 | 텍스트 대화만으로 일정 추천·수정 |
| 영수증·지출 관리 번거로움 | 영수증 촬영만으로 자동 가계부 작성 |
| 여행 기록의 부담 | 하루 데이터를 모아 자동 여행기 생성 |
| 날씨에 따른 일정 차질 | 실시간 날씨 기반 일정 추천 |

### 1.3 핵심 가치

- **멀티모달 입력**: 카메라, 음성, 텍스트, 위치를 모두 활용
- **AWS AI 서비스 종합 활용**: 7개 이상의 AWS AI 서비스를 유기적으로 결합
- **컨텍스트 연속성**: 하루의 모든 활동이 자동으로 연결되어 여행기로 정리
- **오프라인 친화**: 기본 기능은 네트워크 약한 환경에서도 큐잉 후 동기화

---

## 2. 요구사항 정리

### 2.1 기능 요구사항 (Functional Requirements)

#### FR-1: 카메라 기반 장소 인식 및 설명
- **FR-1.1** 사용자가 카메라로 건물·풍경을 비추면 사진 캡처
- **FR-1.2** GPS 좌표와 함께 사진 분석 요청
- **FR-1.3** AI가 장소명, 역사, 특징을 한국어로 설명
- **FR-1.4** 설명을 음성으로도 재생 가능

#### FR-2: 실시간 음성 통역
- **FR-2.1** 마이크 입력을 실시간 텍스트로 변환
- **FR-2.2** 사용자 설정 언어 ↔ 대상 언어 양방향 번역
- **FR-2.3** 번역된 텍스트를 자연스러운 음성으로 출력
- **FR-2.4** 통역 이력 저장 및 재조회

#### FR-3: 메뉴판 OCR 및 추천
- **FR-3.1** 메뉴판 사진 촬영 후 텍스트 추출
- **FR-3.2** 외국어 메뉴를 한국어로 번역
- **FR-3.3** 사용자 선호도·알레르기 기반 추천 메뉴 제시
- **FR-3.4** 메뉴별 간단한 설명 제공

#### FR-4: 자동 여행기 작성
- **FR-4.1** 하루 동안 촬영한 사진, 음성 메모, 위치 데이터 수집
- **FR-4.2** 시간 순으로 정렬 후 AI가 여행기 초안 생성
- **FR-4.3** 사용자가 수정 후 저장 가능
- **FR-4.4** 월별·여행별 아카이브 조회

#### FR-5: 영수증 자동 가계부
- **FR-5.1** 영수증 사진 촬영 시 금액·항목·날짜 자동 추출
- **FR-5.2** 카테고리 자동 분류 (식사, 교통, 숙박, 쇼핑 등)
- **FR-5.3** 환율 자동 적용 (현지 통화 → 원화)
- **FR-5.4** 일별·카테고리별 지출 통계

#### FR-6: 날씨 기반 일정 추천
- **FR-6.1** 현재 위치의 실시간 날씨 조회
- **FR-6.2** 시간대별 날씨 예보 제공
- **FR-6.3** 날씨에 따라 실내·실외 활동 추천

#### FR-7: 대화형 일정 관리
- **FR-7.1** 텍스트 채팅으로 자연어 일정 추천 요청
- **FR-7.2** 위치·날씨·시간을 고려한 맛집·관광지 추천
- **FR-7.3** 추천 결과를 일정에 추가·수정·삭제
- **FR-7.4** 일정 변경 시 알림

### 2.2 비기능 요구사항 (Non-Functional Requirements)

| 분류 | 요구사항 |
|---|---|
| **성능** | 카메라 분석 응답 5초 이내, 통역 지연 2초 이내 |
| **가용성** | 99% 이상 (PoC 기준), 네트워크 단절 시 로컬 큐잉 |
| **보안** | 사진·음성 S3 SSE 암호화, IAM 최소 권한 원칙 |
| **확장성** | Lambda 서버리스 구조로 사용량 기반 자동 확장 |
| **비용** | 월 PoC 기준 $30 이하 |
| **사용성** | 한 화면에서 카메라·음성·텍스트 모든 입력 가능 |
| **접근성** | 음성 출력 옵션으로 시각적 정보 음성화 가능 |
| **다국어** | UI 한국어, 통역은 영어·일본어·중국어·스페인어 지원 |

### 2.3 제약사항

- **PoC 범위**: Android 앱 우선 개발, iOS는 차후 검토
- **개인 학습 프로젝트**: 상용 출시 아닌 포트폴리오 목적
- **AWS 서울 리전 우선 사용**: 단, Bedrock·Location Service는 가용 리전 따름
- **무료 티어 활용**: 신규 AWS 계정 12개월 무료 티어 적극 활용

---

## 3. 구현 기술

### 3.1 AWS AI 서비스

| 서비스 | 역할 | 사용 기능 |
|---|---|---|
| **Amazon Rekognition** | 이미지 내 객체·랜드마크·텍스트 1차 인식 | DetectLabels, DetectText, RecognizeCelebrities (옵션) |
| **Amazon Bedrock (Claude)** | 종합 분석 및 자연어 생성 | 장소 설명, 메뉴 추천, 여행기 작성, 채팅 |
| **Amazon Transcribe** | 음성 → 텍스트 변환 | Streaming (실시간 통역), Batch (음성 메모) |
| **Amazon Translate** | 텍스트 번역 | 양방향 번역, 메뉴판 번역 |
| **Amazon Polly** | 텍스트 → 음성 변환 | Neural TTS, 다국어 음성 |
| **Amazon Textract** | 영수증·문서 정밀 OCR | AnalyzeExpense (영수증 특화 API) |
| **Amazon Location Service** | 지도·역지오코딩·POI 검색 | Places, Maps, Geocoding |

### 3.2 AWS 인프라 서비스

| 서비스 | 역할 |
|---|---|
| **AWS Lambda** | 서버리스 백엔드 함수 실행 |
| **Amazon API Gateway** | 모바일 앱 ↔ Lambda REST API 엔드포인트 |
| **Amazon S3** | 사진·음성 파일 저장 |
| **Amazon DynamoDB** | 일정·여행기·지출·통역기록 DB |
| **Amazon Cognito** | 사용자 인증 및 권한 관리 |
| **Amazon CloudFront** | 사진 CDN 배포 |
| **Amazon EventBridge** | 일정 알림 스케줄링 |
| **Amazon SNS** | 모바일 푸시 알림 |
| **AWS Step Functions** | 여행기 자동 생성 워크플로우 |
| **Amazon CloudWatch** | 로그·메트릭 모니터링 |

### 3.3 외부 서비스 / API

| 서비스 | 역할 |
|---|---|
| **OpenWeatherMap API** | 날씨 정보 (또는 AWS Forecast 대안 검토) |
| **환율 API (예: ExchangeRate-API)** | 실시간 환율 조회 |

### 3.4 클라이언트 기술 스택

| 분류 | 기술 |
|---|---|
| **플랫폼** | Android (Kotlin) |
| **최소 API 레벨** | API 26 (Android 8.0) |
| **UI 프레임워크** | Jetpack Compose |
| **카메라** | CameraX |
| **위치** | FusedLocationProviderClient |
| **네트워크** | Retrofit + OkHttp |
| **로컬 DB** | Room (오프라인 큐) |
| **인증** | AWS Amplify Android SDK |

### 3.5 개발·운영 도구

| 분류 | 도구 |
|---|---|
| **IaC** | AWS SAM 또는 Terraform |
| **CI/CD** | GitHub Actions |
| **로컬 테스트** | AWS SAM Local |
| **로깅** | CloudWatch Logs + Logs Insights |
| **분산 추적** | AWS X-Ray |
| **버전 관리** | Git / GitHub |

---

## 4. 시스템 구조

### 4.1 전체 아키텍처 개요

시스템은 크게 다섯 개의 계층으로 구성됩니다.

1. **클라이언트 계층 (Android 앱)**: 카메라·마이크·GPS·텍스트 입력을 수집하고 결과를 표시
2. **API 게이트웨이 계층**: 인증 및 라우팅 담당
3. **서비스 계층 (Lambda 함수 그룹)**: 기능별로 분리된 비즈니스 로직
4. **AI 처리 계층 (AWS AI 서비스)**: 실제 AI 분석 수행
5. **데이터 계층 (S3 + DynamoDB)**: 미디어 파일과 구조화 데이터 저장

### 4.2 전체 데이터 흐름도

```
┌─────────────────────────────────────────────────────────────┐
│                  Android App (Kotlin + Compose)             │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐  │
│  │ Camera   │ Mic      │ GPS      │ Text     │ Storage  │  │
│  └────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┘  │
└───────┼──────────┼──────────┼──────────┼──────────┼─────────┘
        │          │          │          │          │
        └──────────┴────┬─────┴──────────┴──────────┘
                        │ HTTPS
                        ▼
            ┌───────────────────────┐
            │ Amazon Cognito (Auth) │
            └───────────┬───────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │  Amazon API Gateway   │
            └───────────┬───────────┘
                        │
        ┌───────────────┼─────────────────────────────┐
        │               │                             │
        ▼               ▼                             ▼
  ┌──────────┐   ┌──────────────┐            ┌──────────────┐
  │ fn-place │   │ fn-translate │            │ fn-receipt   │
  │ (장소)    │   │ (통역)        │   ...     │ (영수증)      │
  └────┬─────┘   └──────┬───────┘            └──────┬───────┘
       │                │                            │
       ▼                ▼                            ▼
 ┌────────────┐  ┌────────────┐              ┌────────────┐
 │Rekognition │  │ Transcribe │              │  Textract  │
 │+ Location  │  │+ Translate │              │ + Bedrock  │
 │+ Bedrock   │  │+ Polly     │              │            │
 └─────┬──────┘  └──────┬─────┘              └──────┬─────┘
       │                │                            │
       └────────────────┼────────────────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
  ┌──────────┐                  ┌──────────────┐
  │    S3    │                  │  DynamoDB    │
  │ (미디어)  │                  │ (구조 데이터) │
  └──────────┘                  └──────────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │   Step Functions      │
            │ (자동 여행기 생성)      │
            └───────────────────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │      SNS (Push)       │
            └───────────────────────┘
```

### 4.3 기능별 처리 흐름

#### 4.3.1 장소 인식 흐름

```
[카메라 촬영]
    ↓
[GPS 좌표 + 이미지 → S3 업로드]
    ↓
[API Gateway → fn-place Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Rekognition DetectLabels (객체 인식)   │
   │ 2. Location Service (좌표 → 장소명)       │
   │ 3. Bedrock Claude (종합 설명 생성)        │
   │    - 입력: 라벨 + 장소명 + 좌표           │
   │    - 출력: 자연어 설명                    │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB 저장 + 앱 응답]
    ↓
[(선택) Polly로 음성 변환 → 앱 재생]
```

#### 4.3.2 실시간 통역 흐름

```
[마이크 입력 시작]
    ↓
[Transcribe Streaming WebSocket 연결]
    ↓
[음성 청크 전송 → 실시간 텍스트 수신]
    ↓
[발화 구간 종료 감지]
    ↓
[Translate API → 대상 언어 변환]
    ↓
[Polly Neural TTS → 음성 합성]
    ↓
[앱 스피커로 출력 + DynamoDB 이력 저장]
```

#### 4.3.3 메뉴판 분석 흐름

```
[메뉴판 사진 촬영]
    ↓
[S3 업로드]
    ↓
[fn-menu Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Textract DetectDocumentText           │
   │    (메뉴 항목별 텍스트 추출)              │
   │ 2. Translate (외국어 → 한국어)           │
   │ 3. Bedrock Claude                        │
   │    - 입력: 메뉴 목록 + 사용자 선호도     │
   │    - 출력: 추천 메뉴 + 설명              │
   └──────────────────────────────────────────┘
    ↓
[앱 응답 (원문/번역/추천 카드 표시)]
```

#### 4.3.4 영수증 가계부 흐름

```
[영수증 촬영]
    ↓
[S3 업로드]
    ↓
[fn-receipt Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Textract AnalyzeExpense               │
   │    (총액, 항목, 날짜, 통화 자동 추출)     │
   │ 2. 환율 API → 원화 환산                  │
   │ 3. Bedrock Claude → 카테고리 자동 분류   │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB Expenses 테이블 저장]
    ↓
[앱: 일별·카테고리별 통계 갱신]
```

#### 4.3.5 자동 여행기 생성 흐름 (Step Functions)

```
[하루 종료 트리거 (사용자 액션 또는 EventBridge 스케줄)]
    ↓
[Step Functions State Machine 시작]
    ↓
   ┌──────────────────────────────────────────┐
   │ State 1: 데이터 수집                      │
   │  - 오늘 사진 목록 (S3)                    │
   │  - 위치 이력 (DynamoDB Locations)         │
   │  - 음성 메모 텍스트 (DynamoDB Notes)      │
   │  - 영수증 데이터 (DynamoDB Expenses)      │
   └──────────────────────────────────────────┘
    ↓
   ┌──────────────────────────────────────────┐
   │ State 2: 사진 일괄 분석 (Map State 병렬)  │
   │  - Rekognition으로 사진별 태그 추출       │
   └──────────────────────────────────────────┘
    ↓
   ┌──────────────────────────────────────────┐
   │ State 3: 시간순 정렬 및 컨텍스트 통합     │
   └──────────────────────────────────────────┘
    ↓
   ┌──────────────────────────────────────────┐
   │ State 4: Bedrock 여행기 작성              │
   │  - 입력: 통합 컨텍스트                    │
   │  - 출력: 자연스러운 여행 일지             │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB Diaries 테이블 저장]
    ↓
[SNS 푸시: "오늘의 여행기가 완성되었습니다"]
```

#### 4.3.6 대화형 일정 추천 흐름

```
[사용자 채팅 입력: "내일 비 온대. 실내 활동 추천해줘"]
    ↓
[fn-chat Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. 현재 위치·날씨 조회                    │
   │ 2. Location Service Places                │
   │    (반경 N km 내 실내 POI 검색)           │
   │ 3. Bedrock Claude (대화 컨텍스트 포함)    │
   │    - 사용자 이전 대화 + 일정 + POI 후보   │
   │    - 출력: 추천 리스트 + 자연어 응답      │
   └──────────────────────────────────────────┘
    ↓
[앱: 추천 카드 + 일정 추가 버튼 표시]
    ↓
[사용자 확정 시 DynamoDB Schedules 저장]
    ↓
[EventBridge 일정 알림 스케줄 등록]
```

### 4.4 Lambda 함수 역할 분리

| 함수명 | 역할 | 트리거 | 평균 실행 시간 |
|---|---|---|---|
| **fn-place** | 카메라 사진 → 장소 설명 생성 | API Gateway | 3~5초 |
| **fn-translate** | 실시간 통역 처리 | API Gateway (WebSocket) | 1~2초/청크 |
| **fn-menu** | 메뉴판 OCR + 번역 + 추천 | API Gateway | 4~6초 |
| **fn-receipt** | 영수증 OCR + 가계부 등록 | API Gateway | 3~4초 |
| **fn-chat** | 대화형 일정 추천 | API Gateway | 2~4초 |
| **fn-weather** | 날씨 조회 (캐시 포함) | API Gateway | <1초 |
| **fn-diary-orchestrator** | Step Functions 트리거 | EventBridge / 사용자 | <1초 |
| **fn-diary-collector** | 하루 데이터 수집 | Step Functions | 1~2초 |
| **fn-diary-photo-analyzer** | 사진 일괄 태깅 | Step Functions Map | 5~30초 |
| **fn-diary-writer** | Bedrock 여행기 작성 | Step Functions | 10~20초 |
| **fn-notify** | SNS 푸시 발송 | EventBridge / Step Functions | <1초 |

### 4.5 IAM 최소 권한 (요약)

| 역할 | 핵심 권한 |
|---|---|
| **LambdaPlaceRole** | `rekognition:DetectLabels`, `geo:SearchPlaceIndexForPosition`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| **LambdaTranslateRole** | `transcribe:StartStreamTranscription`, `translate:TranslateText`, `polly:SynthesizeSpeech`, `s3:PutObject`, `dynamodb:PutItem` |
| **LambdaMenuRole** | `textract:DetectDocumentText`, `translate:TranslateText`, `bedrock:InvokeModel`, `s3:GetObject` |
| **LambdaReceiptRole** | `textract:AnalyzeExpense`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| **LambdaChatRole** | `geo:SearchPlaceIndexForText`, `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem` |
| **LambdaDiaryRole** | `s3:ListBucket`, `s3:GetObject`, `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem`, `sns:Publish` |

---

## 5. ERD (Entity Relationship Diagram)

### 5.1 엔티티 개요

본 프로젝트는 DynamoDB 기반의 NoSQL 모델을 사용합니다. 다만 데이터 관계 이해를 위해 ERD는 관계형 모델 관점으로 정리합니다. 실제 구현 시 DynamoDB 단일 테이블 디자인 또는 다중 테이블 디자인으로 매핑됩니다.

### 5.2 엔티티 정의

#### User (사용자)
| 필드 | 타입 | 설명 |
|---|---|---|
| user_id (PK) | String | Cognito Sub ID |
| email | String | 이메일 |
| nickname | String | 닉네임 |
| preferred_language | String | 모국어 (예: ko) |
| dietary_restrictions | List<String> | 알레르기·식이 제한 |
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

#### Place (인식된 장소)
| 필드 | 타입 | 설명 |
|---|---|---|
| place_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| photo_s3_key | String | S3 경로 |
| latitude | Number | 위도 |
| longitude | Number | 경도 |
| place_name | String | 인식된 장소명 |
| description | String | Bedrock 생성 설명 |
| labels | List<String> | Rekognition 라벨 |
| created_at | Timestamp | 인식 시각 |

#### TranslationLog (통역 기록)
| 필드 | 타입 | 설명 |
|---|---|---|
| translation_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| source_text | String | 원문 |
| source_lang | String | 원본 언어 |
| target_text | String | 번역문 |
| target_lang | String | 대상 언어 |
| audio_s3_key | String | 합성 음성 파일 |
| created_at | Timestamp | 시각 |

#### Menu (메뉴판 분석)
| 필드 | 타입 | 설명 |
|---|---|---|
| menu_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| photo_s3_key | String | 사진 경로 |
| items | List<MenuItem> | 메뉴 항목 |
| recommended | List<String> | 추천 메뉴 ID |
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

#### Diary (자동 생성 여행기)
| 필드 | 타입 | 설명 |
|---|---|---|
| diary_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| diary_date | Date | 해당 날짜 |
| title | String | AI 제목 |
| content | String | 본문 (마크다운) |
| photo_keys | List<String> | 포함된 사진 |
| user_edited | Boolean | 사용자 수정 여부 |
| created_at | Timestamp | 작성 시각 |

#### ChatMessage (대화 이력)
| 필드 | 타입 | 설명 |
|---|---|---|
| message_id (PK) | String | UUID |
| trip_id (FK) | String | 소속 여행 |
| role | Enum | user / assistant |
| content | String | 메시지 본문 |
| created_at | Timestamp | 시각 |

### 5.3 관계 정의

```
User (1) ─────────── (N) Trip
                       │
        ┌──────────────┼──────────────┬──────────────┬──────────────┬──────────────┐
        │              │              │              │              │              │
       (N)            (N)            (N)            (N)            (N)            (N)
      Place      TranslationLog     Menu        Expense        Schedule         Diary
                                     │
                                    (N)
                                  MenuItem (embedded)

Trip (1) ─────────── (N) ChatMessage
```

### 5.4 ERD 다이어그램 (텍스트 표기)

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
│     Place     │         │TranslationLog│        │     Menu      │
│───────────────│         │──────────────│        │───────────────│
│ place_id (PK) │         │transl_id (PK)│        │ menu_id (PK)  │
│ trip_id (FK)  │         │ trip_id (FK) │        │ trip_id (FK)  │
│ photo_s3_key  │         │ source_text  │        │ photo_s3_key  │
│ latitude      │         │ target_text  │        │ items[]       │
│ longitude     │         │ source_lang  │        │ recommended[] │
│ place_name    │         │ target_lang  │        └───────────────┘
│ description   │         │ audio_s3_key │
│ labels        │         └──────────────┘
└───────────────┘

        ┌─────────────────────────┬────────────────────────┐
        │ N                       │ N                      │ N
┌───────▼───────┐         ┌──────▼──────┐         ┌───────▼───────┐
│    Expense    │         │   Schedule   │        │     Diary     │
│───────────────│         │──────────────│        │───────────────│
│expense_id (PK)│         │sched_id (PK) │        │ diary_id (PK) │
│ trip_id (FK)  │         │ trip_id (FK) │        │ trip_id (FK)  │
│ receipt_s3_key│         │ title        │        │ diary_date    │
│ merchant      │         │ location     │        │ title         │
│ total_amount  │         │ latitude     │        │ content       │
│ currency      │         │ longitude    │        │ photo_keys[]  │
│ krw_amount    │         │ start_time   │        │ user_edited   │
│ category      │         │ end_time     │        └───────────────┘
│ occurred_at   │         │ source       │
└───────────────┘         └──────────────┘

                          ┌──────────────┐
Trip (1) ──────── (N) ────│ ChatMessage  │
                          │──────────────│
                          │ msg_id (PK)  │
                          │ trip_id (FK) │
                          │ role         │
                          │ content      │
                          └──────────────┘
```

---

## 6. Use Case

### UC-1: 낯선 건물 정보 즉시 확인

**행위자**: 여행자
**사전 조건**: 앱 로그인 상태, 위치 권한 허용, 카메라 권한 허용
**주요 흐름**:

여행자가 도쿄의 어느 골목에서 인상적인 전통 건물을 발견합니다. 앱을 열고 카메라 버튼을 탭한 뒤 건물을 비춥니다. 사용자가 화면 중앙의 셔터를 누르면 앱은 사진을 캡처하고 현재 GPS 좌표를 함께 묶어 S3에 업로드합니다. 업로드 완료 즉시 API Gateway를 통해 fn-place Lambda가 호출되며, Lambda는 Rekognition으로 사진 내 객체(예: temple, traditional architecture, pagoda)를 분석합니다. 동시에 Location Service의 SearchPlaceIndexForPosition으로 좌표 기반 장소명을 조회합니다. 두 결과(라벨 + 장소명)를 컨텍스트로 묶어 Bedrock Claude에 전달하면, Claude는 "이 건물은 센소지 사찰의 본당으로, 7세기에 창건된 도쿄에서 가장 오래된 사찰입니다..."와 같은 자연어 설명을 생성합니다. 응답은 DynamoDB Place 테이블에 저장되고 앱 화면에 카드 형태로 표시됩니다. 사용자가 "음성으로 듣기" 버튼을 누르면 Polly가 텍스트를 한국어 음성으로 합성해 재생합니다.

**예외 흐름**: GPS 신호가 약한 실내에서는 좌표 정확도가 떨어질 수 있으며, 이때 fn-place는 Rekognition 결과만으로 일반적인 설명을 생성합니다. 네트워크가 단절된 경우 사진은 로컬 큐에 저장되었다가 연결 복구 시 일괄 업로드됩니다.

---

### UC-2: 외국인과의 즉석 통역 대화

**행위자**: 여행자, 외국인 상대방
**사전 조건**: 마이크 권한 허용, 통역 모드 활성화
**주요 흐름**:

여행자가 도쿄 라멘 가게에서 직원에게 길을 물어보려 합니다. 앱 하단의 "통역" 탭을 선택하면 두 개의 큰 버튼(내 언어 / 상대 언어)이 나타납니다. 사용자가 "한국어 → 일본어" 버튼을 누르고 마이크 아이콘을 길게 누른 채 "근처에 ATM 어디 있나요?"라고 말합니다. 음성은 청크 단위로 Transcribe Streaming WebSocket으로 전송되어 실시간 텍스트로 변환됩니다. 발화가 끝나면(VAD가 끝점 감지) Translate API가 일본어로 번역하고, Polly Neural TTS가 자연스러운 일본어 음성으로 합성합니다. 폰 스피커에서 일본어가 흘러나오면 직원이 일본어로 응답합니다. 사용자가 반대 방향 버튼(일본어 → 한국어)을 누르고 직원에게 마이크를 향하면 동일한 흐름이 반대로 실행됩니다. 모든 통역 내용은 DynamoDB TranslationLog에 저장되어 나중에 채팅 형태로 다시 볼 수 있습니다.

**예외 흐름**: 시끄러운 환경에서 Transcribe 정확도가 떨어지면 사용자는 텍스트 직접 입력 모드로 전환할 수 있습니다. 통역 지연이 3초 이상 발생하면 앱은 "처리 중..." 인디케이터를 표시합니다.

---

### UC-3: 외국어 메뉴판 해독 및 추천

**행위자**: 여행자
**사전 조건**: 사용자 프로필에 식이 제한 정보 입력됨
**주요 흐름**:

여행자가 식당에 자리를 잡고 일본어로만 적힌 메뉴판을 받습니다. 앱의 "메뉴" 기능으로 메뉴판 사진을 촬영합니다. 사진은 S3에 업로드되고 fn-menu Lambda가 호출됩니다. Lambda는 먼저 Textract의 DetectDocumentText로 메뉴판의 모든 텍스트를 추출합니다(이때 항목별 좌표 정보도 함께 얻어 메뉴와 가격을 매칭). 추출된 일본어 항목들을 Translate API로 한국어로 변환합니다. 이어서 Bedrock Claude에 사용자의 식이 제한(예: "갑각류 알레르기") 정보와 함께 번역된 메뉴 목록을 전달하면, Claude는 알레르기 유발 가능 메뉴를 제외하고 "오늘 같은 쌀쌀한 날씨엔 따뜻한 미소라멘이 좋겠어요"와 같은 맥락 있는 추천을 생성합니다. 앱은 원문/번역/추천을 카드 UI로 표시하며, 추천 메뉴는 별도로 하이라이트됩니다.

**예외 흐름**: 메뉴판 사진이 흐릿하거나 기울어진 경우 Textract 정확도가 떨어집니다. 이 경우 앱은 "사진을 다시 촬영해 주세요" 가이드를 표시하며 촬영 시 가이드라인(직사각형 프레임)을 화면에 오버레이합니다.

---

### UC-4: 영수증 자동 가계부 작성

**행위자**: 여행자
**사전 조건**: 환율 정보 캐시 또는 실시간 환율 API 가용
**주요 흐름**:

식사 후 결제하고 받은 영수증을 여행자가 앱의 "지출" 탭에서 촬영합니다. 사진이 S3에 업로드되고 fn-receipt Lambda가 호출됩니다. Lambda는 Textract의 AnalyzeExpense API를 호출하는데, 이는 영수증에 특화된 API로 총액, 항목별 금액, 결제 일시, 상호명, 통화를 구조화된 형태로 추출합니다. Lambda는 추출된 통화(예: JPY)와 원화 환율을 외부 API로 조회해 원화 환산 금액을 계산합니다. 다음으로 Bedrock Claude가 상호명과 항목명을 보고 카테고리("식사")를 자동 분류합니다. 모든 결과는 DynamoDB Expense 테이블에 저장되고, 앱의 가계부 화면이 즉시 갱신됩니다. 사용자는 일별·카테고리별 통계를 그래프로 확인할 수 있고, 분류가 잘못된 경우 수동으로 카테고리를 변경할 수 있습니다.

**예외 흐름**: 영수증 인쇄가 흐릿하거나 일부 글자가 손상된 경우 Textract 결과의 신뢰도(Confidence) 점수가 낮게 반환됩니다. 신뢰도가 80% 미만인 필드는 앱이 사용자에게 확인을 요청합니다.

---

### UC-5: 날씨 변화에 따른 일정 재추천

**행위자**: 여행자
**사전 조건**: 기존 일정에 야외 활동(예: 공원 산책) 등록됨
**주요 흐름**:

다음 날 오후 우에노 공원 산책 일정이 있는 여행자가 저녁에 채팅 탭을 열어 "내일 비 온다는데 다른 거 추천해줘"라고 입력합니다. fn-chat Lambda가 호출되며, Lambda는 먼저 사용자 현재 위치의 다음 날 날씨를 외부 API로 조회합니다(강수 확률 80% 확인). Location Service의 SearchPlaceIndexForText로 "도쿄 실내 관광지" POI를 검색해 후보군을 얻습니다. 이 후보군과 사용자의 기존 일정·대화 이력을 컨텍스트로 묶어 Bedrock Claude에 전달하면, Claude는 "내일 오전부터 비가 예보되네요. 우에노 공원 대신 가까운 도쿄 국립박물관(도보 5분)을 추천드려요. 그리고 점심은 박물관 근처의 ..."와 같이 위치·시간·이전 일정을 고려한 추천을 생성합니다. 사용자가 "좋아, 일정 바꿔줘"라고 답하면 fn-chat은 DynamoDB Schedule 테이블의 기존 일정을 업데이트하고 EventBridge에 새 알림을 등록합니다.

**예외 흐름**: Bedrock이 일정 변경 의도를 명확히 파악하지 못한 경우 "기존 일정을 박물관 방문으로 변경할까요?"와 같은 확인 질문을 되돌립니다. 사용자가 거부하면 추천만 표시하고 변경하지 않습니다.

---

### UC-6: 하루 마감 시 자동 여행기 생성

**행위자**: 여행자 (수동 트리거) 또는 시스템 (자동 스케줄)
**사전 조건**: 당일 사진 1장 이상, 또는 위치 이력 존재
**주요 흐름**:

여행자가 저녁에 호텔로 돌아와 앱의 "오늘의 여행기 만들기" 버튼을 누릅니다(또는 매일 밤 11시 EventBridge가 자동 트리거). fn-diary-orchestrator Lambda가 Step Functions 워크플로우를 시작합니다. 첫 번째 단계에서 fn-diary-collector는 당일 0시부터 현재까지의 모든 데이터 — Place 테이블의 장소 인식 기록, Expense 테이블의 지출, Schedule 테이블에서 실제 방문한 일정, 음성 메모 텍스트 — 를 수집합니다. 두 번째 단계에서 Map State로 사진들을 병렬 분석해 누락된 태그를 보강합니다. 세 번째 단계에서 모든 데이터를 시간순으로 정렬해 컨텍스트 문서를 만들고, 네 번째 단계에서 Bedrock Claude에 전달합니다. Claude는 단순 나열이 아닌 자연스러운 일기 형식으로 "오늘은 아침 일찍 센소지부터 시작했다. 흐린 하늘 아래 본당의 붉은 기둥이 더 선명하게 보였고..."와 같은 여행기를 작성합니다. 결과는 DynamoDB Diary 테이블에 저장되고 SNS 푸시로 "오늘의 여행기가 도착했습니다" 알림이 전송됩니다. 사용자는 앱에서 여행기를 읽고 직접 편집해 저장할 수 있습니다.

**예외 흐름**: 당일 데이터가 거의 없는 경우(예: 사진 0장, 위치 이력만 있음) Step Functions는 짧은 요약 모드로 분기해 간단한 한두 문단을 생성합니다. Bedrock 응답이 30초 내 도착하지 않으면 워크플로우는 재시도하고, 3회 실패 시 사용자에게 "여행기 생성 중 문제가 발생했습니다" 알림을 보냅니다.

---

### UC-7: 대화형 즉흥 일정 추천

**행위자**: 여행자
**사전 조건**: 여행 활성 상태
**주요 흐름**:

여행자가 점심을 먹고 다음 일정 없이 자유 시간이 생겼습니다. 채팅 탭을 열고 "지금 근처에 가성비 좋은 카페 추천해줘. 분위기 조용한 곳으로"라고 입력합니다. fn-chat Lambda는 현재 GPS 좌표로 Location Service Places API의 SearchPlaceIndexForText에 "cafe"와 위치 바이어스를 전달해 반경 1km 내 카페 후보를 가져옵니다. 이 후보군(이름, 평점, 거리, 카테고리)과 사용자의 요청 의도("가성비", "조용한 분위기")를 Bedrock Claude에 전달하면, Claude는 단순히 카페를 나열하는 게 아니라 "도보 7분 거리의 X 카페가 평점 4.5에 가격대도 합리적입니다. 오후엔 손님이 적어 조용한 편이라고 해요"와 같이 사용자 요구에 맞춘 큐레이션을 제공합니다. 사용자가 추천을 마음에 들어 하면 카드의 "일정에 추가" 버튼으로 DynamoDB Schedule에 저장하고, 지도 탭으로 이동하면 Location Service의 지도 위에 마커로 표시됩니다.

**예외 흐름**: 사용자의 요청이 모호한 경우(예: "뭐 할까") Claude는 즉답 대신 "어떤 분위기를 원하세요? 활기찬 곳, 조용한 곳, 또는 특정 음식이 끌리시나요?"와 같은 질문을 되돌립니다.

---

## 7. 간트 차트 일정표

### 7.1 단계별 개요

총 개발 기간은 **10주**로 계획하며, 단계별 마일스톤은 다음과 같습니다.

| 단계 | 주차 | 핵심 마일스톤 |
|---|---|---|
| 1단계: 기반 환경 구축 | 1~2주 | AWS 계정·IAM·Cognito·S3·DynamoDB 구성, Android 앱 스켈레톤 |
| 2단계: 단일 AI 기능 PoC | 3~4주 | 카메라 → Rekognition → Bedrock 흐름 완성 |
| 3단계: 음성·번역 통합 | 5~6주 | 통역 모드, 메뉴판 OCR 구현 |
| 4단계: 데이터 처리 확장 | 7주 | 영수증 가계부, 날씨, 채팅 일정 추천 |
| 5단계: 자동 여행기 (Step Functions) | 8주 | Step Functions 워크플로우, 자동 푸시 |
| 6단계: 통합 테스트 및 최적화 | 9주 | E2E 테스트, 비용 최적화, 모니터링 |
| 7단계: 마무리 및 포트폴리오 정리 | 10주 | README, 데모 영상, 배포 문서 |

### 7.2 주차별 상세 일정 (간트 차트)

```
주차            │ 1주 │ 2주 │ 3주 │ 4주 │ 5주 │ 6주 │ 7주 │ 8주 │ 9주 │10주 │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
1. AWS 인프라    │ ███ │ ███ │     │     │     │     │     │     │     │     │
   구축          │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
2. Android 앱   │ ███ │ ███ │ ███ │     │     │     │     │     │     │     │
   스켈레톤      │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
3. Cognito 인증 │     │ ███ │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
4. UC-1 장소    │     │     │ ███ │ ███ │     │     │     │     │     │     │
   인식 구현     │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
5. UC-2 통역    │     │     │     │ ███ │ ███ │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
6. UC-3 메뉴판  │     │     │     │     │ ███ │ ███ │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
7. UC-4 영수증  │     │     │     │     │     │ ███ │ ███ │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
8. UC-5/7 날씨  │     │     │     │     │     │     │ ███ │ ███ │     │     │
   채팅 추천    │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
9. UC-6 자동    │     │     │     │     │     │     │     │ ███ │ ███ │     │
   여행기       │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
10. E2E 테스트  │     │     │     │     │     │     │     │     │ ███ │ ███ │
    + 최적화    │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
11. 모니터링    │     │     │     │     │     │     │     │     │ ███ │     │
    (X-Ray)    │     │     │     │     │     │     │     │     │     │     │
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
12. 문서 정리   │     │     │     │     │     │     │     │     │     │ ███ │
    데모 영상   │     │     │     │     │     │     │     │     │     │     │
────────────────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
```

### 7.3 주차별 세부 작업

#### 1주차 — AWS 기반 환경 구성
- AWS 계정 생성 및 결제 알람 설정 (Budgets $30)
- IAM 사용자·역할 설계
- S3 버킷 생성 (사진·음성·영수증 분리)
- DynamoDB 테이블 7종 생성
- Android 프로젝트 초기 세팅 (Kotlin + Compose + CameraX)

#### 2주차 — 인증 및 앱 스켈레톤
- Cognito User Pool 구성
- Amplify Android SDK 통합
- 회원가입·로그인 화면 구현
- 메인 네비게이션 (카메라·통역·메뉴·지출·채팅·여행기 탭)
- API Gateway 첫 엔드포인트 (헬스 체크)

#### 3주차 — UC-1 장소 인식 (1차)
- fn-place Lambda 작성
- Rekognition DetectLabels 통합
- Location Service Place Index 설정
- Bedrock Claude 호출 및 프롬프트 튜닝
- 카메라 촬영 → 업로드 → 결과 표시 흐름 연결

#### 4주차 — UC-1 완성 + UC-2 시작
- Polly Neural TTS 통합 (장소 설명 음성)
- Place 결과 DynamoDB 저장 및 히스토리 조회
- Transcribe Streaming WebSocket 연결
- Translate API 연동

#### 5주차 — UC-2 완성 + UC-3 시작
- 양방향 통역 UI 완성
- 통역 이력 화면
- Textract DetectDocumentText 통합
- 메뉴판 항목 파싱 로직

#### 6주차 — UC-3 완성 + UC-4 시작
- 메뉴 추천 Bedrock 프롬프트 최적화
- 사용자 식이 제한 프로필 화면
- Textract AnalyzeExpense 통합
- 환율 API 연동 및 캐싱

#### 7주차 — UC-4 완성 + UC-5/7 시작
- 가계부 화면 및 통계 차트
- 카테고리 자동 분류 + 수동 수정 UI
- OpenWeatherMap API 연동, fn-weather Lambda
- fn-chat Lambda 및 채팅 UI

#### 8주차 — UC-5/7 완성 + UC-6 시작
- 일정 추천 → 캘린더 등록 흐름
- EventBridge 알림 스케줄
- Step Functions State Machine 정의
- fn-diary-collector, fn-diary-writer 작성

#### 9주차 — UC-6 완성 + 통합 테스트
- Map State 병렬 사진 분석
- 자동 여행기 SNS 푸시
- 7개 UC E2E 테스트 (실제 여행 시뮬레이션)
- X-Ray 분산 추적 설정
- 비용 최적화 (Bedrock 호출 캐싱, S3 라이프사이클)

#### 10주차 — 마무리 및 포트폴리오 정리
- README 작성 (아키텍처 다이어그램 포함)
- 데모 영상 촬영 (실제 사용 시연)
- AWS SAM 템플릿 정리 (재현 가능성 확보)
- 비용 회고 및 개선 제안 문서
- GitHub 공개 저장소 정리

### 7.4 리스크 및 버퍼

- **8~9주차에 1주 버퍼 내재**: Step Functions가 처음이라 일정 초과 가능성 있어 9주차에 통합 테스트와 함께 진행
- **Bedrock 지역 가용성**: us-east-1만 안정적이므로 cross-region 호출 지연(~200ms) 감안
- **Transcribe Streaming 한국어 정확도**: 5주차 종료 시 정확도 부족 시 Custom Vocabulary 추가 작업 (+0.5주)
- **개인 시간 가용성**: 주당 20시간 기준 산정, 부족 시 12주로 연장 가능

---

## 8. 부록

### 8.1 예상 비용 상세 (월 1인 PoC 기준)

| 서비스 | 가정 사용량 | 월 비용 |
|---|---|---|
| Rekognition DetectLabels | 100회 | $0.10 |
| Bedrock Claude (Haiku 위주) | 500회 평균 1K tokens | $1.00 |
| Transcribe Streaming | 60분 | $1.44 |
| Translate | 50,000자 | $0.75 |
| Polly Neural | 30,000자 | $0.48 |
| Textract AnalyzeExpense | 30회 | $0.30 |
| Location Service | 1,000 요청 | $0.50 |
| Lambda + API Gateway + DynamoDB + S3 | 무료 티어 내 | $0.00 |
| CloudWatch Logs | 1GB | $0.50 |
| **합계** | | **약 $5 (12개월 무료 티어 적용 시)** |
| **무료 티어 종료 후** | | **약 $15~30** |

### 8.2 학습 포인트 정리

본 프로젝트를 통해 습득 가능한 기술:

- **AWS AI 서비스 7종 통합 활용**: Rekognition, Bedrock, Transcribe, Translate, Polly, Textract, Location Service
- **서버리스 아키텍처**: Lambda + API Gateway + DynamoDB
- **분산 워크플로우**: Step Functions (Map State, Catch, Retry)
- **이벤트 기반 처리**: EventBridge, SNS
- **인증·인가**: Cognito + IAM 최소 권한 원칙
- **모니터링**: CloudWatch + X-Ray
- **IaC**: SAM 또는 Terraform
- **Android 최신 스택**: Kotlin + Compose + CameraX

### 8.3 확장 가능성

PoC 이후 다음 기능을 추가 검토 가능:

- iOS 클라이언트 추가
- Bedrock Agents 도입 (능동적 비서 모드)
- Personalize로 사용자별 추천 고도화
- QuickSight 대시보드 (여행 분석)
- 다국어 UI 지원
- 친구와 여행 공유 (Multi-user Trip)
