# Polylog — 요구사항 정의서 (Requirements Specification)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v2.0 PoC |
| 작성일 | 2026-05-25 |
| 근거 문서 | `polylog-plan.md` v2.0 |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-25 | 2.0 | v2.0 기획서 기반 전면 재작성 — Main+Sub 구조, AWS AI 3종, Flutter 기반 |

---

## 1. 기능 요구사항 (Functional Requirements)

### FR-M: 메인 — AI 장소 추천

| ID | 요구사항 | 우선순위 | 관련 서비스 |
|---|---|---|---|
| FR-M.1 | 사용자가 GPS 위치 권한을 허용하면 현재 위치를 자동 수집한다 | 필수 | geolocator |
| FR-M.2 | 카테고리(맛집, 숙소, 관광지, 카페 등)를 선택하거나 자연어로 입력한다 | 필수 | — |
| FR-M.3 | Google Places API로 반경 N km 내 장소 후보를 검색한다 | 필수 | Google Places (Nearby Search) |
| FR-M.4 | Bedrock Claude가 장소 후보를 분석하여 개인화 추천과 추천 이유를 생성한다 | 필수 | Bedrock |
| FR-M.5 | 추천 결과를 카드 UI(이름, 별점, 거리, AI 추천 이유)로 표시한다 | 필수 | — |
| FR-M.6 | 추천 이력을 DynamoDB에 저장하고 조회할 수 있다 | 필수 | DynamoDB |

**수용 기준**
- GPS 위치 수집 → 추천 결과 표시까지 5초 이내
- 추천 결과에 별점, 거리, AI 추천 이유가 포함
- GPS 권한 미허용 시 수동 위치 입력 대안 제공

---

### FR-S1: 서브1 — 메뉴판 번역

| ID | 요구사항 | 우선순위 | 관련 서비스 |
|---|---|---|---|
| FR-S1.1 | 메뉴판 사진 촬영 후 텍스트를 추출한다 | 필수 | Textract (DetectDocumentText) |
| FR-S1.2 | 외국어 메뉴를 한국어로 번역한다 | 필수 | Translate |
| FR-S1.3 | 사용자 선호도·알레르기 기반 추천 메뉴를 제시한다 | 필수 | Bedrock |
| FR-S1.4 | 메뉴별 간단한 설명을 제공한다 | 선택 | Bedrock |

**수용 기준**
- 메뉴판 텍스트 추출 정확도 90% 이상 (명확한 인쇄물 기준)
- 알레르기 유발 가능 메뉴 필터링
- 사진 품질 불량 시 재촬영 가이드라인(프레임 오버레이) 표시
- 응답 시간 6초 이내

---

### FR-S2: 서브2 — 영수증 기록

| ID | 요구사항 | 우선순위 | 관련 서비스 |
|---|---|---|---|
| FR-S2.1 | 영수증 사진 촬영 시 금액·항목·날짜를 자동 추출한다 | 필수 | Textract (AnalyzeExpense) |
| FR-S2.2 | 지출을 카테고리(식사, 교통, 숙박, 쇼핑 등)로 자동 분류한다 | 필수 | Bedrock |
| FR-S2.3 | 현지 통화를 원화로 자동 환산한다 | 필수 | ExchangeRate-API |
| FR-S2.4 | 일별·카테고리별 지출 목록을 제공한다 | 필수 | DynamoDB |

**수용 기준**
- Textract 신뢰도 80% 미만 필드는 사용자 확인 요청
- 카테고리 자동 분류 오류 시 수동 변경 가능
- 환율은 실시간 조회 + 캐싱 적용
- 응답 시간 4초 이내

---

### FR-S3: 서브3 — AI 일정 관리

| ID | 요구사항 | 우선순위 | 관련 서비스 |
|---|---|---|---|
| FR-S3.1 | AI와 대화형으로 일정을 계획한다 | 필수 | Bedrock |
| FR-S3.2 | AI가 GPS + Google Places API로 근처 장소를 검색하여 일정을 추천한다 | 필수 | Google Places (Text Search), geolocator |
| FR-S3.3 | 추천 결과를 일정에 추가·수정·삭제한다 | 필수 | DynamoDB |
| FR-S3.4 | 일정을 타임라인/카드 프레임으로 표시한다 | 필수 | — |
| FR-S3.5 | 일정 변경 시 자동으로 근처를 재검색하여 대안을 추천한다 | 필수 | Google Places, Bedrock |

**수용 기준**
- 대화 컨텍스트(이전 대화 이력 + 기존 일정) 유지
- 모호한 요청 시 확인 질문 반환
- 메인 추천 결과를 일정에 바로 추가 가능
- 응답 시간 4초 이내

---

## 2. 비기능 요구사항 (Non-Functional Requirements)

### 2.1 성능 (Performance)

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-P1 | AI 장소 추천 응답 시간 | 5초 이내 |
| NFR-P2 | 메뉴판 OCR + 번역 + 추천 응답 시간 | 6초 이내 |
| NFR-P3 | 영수증 분석 응답 시간 | 4초 이내 |
| NFR-P4 | 채팅 일정 추천 응답 시간 | 4초 이내 |

### 2.2 가용성 (Availability)

| ID | 요구사항 |
|---|---|
| NFR-A1 | 서비스 가용성 99% 이상 (PoC 기준) |
| NFR-A2 | 네트워크 단절 시 로컬 큐잉으로 데이터 유실 0% |
| NFR-A3 | Lambda 서버리스 구조로 사용량 기반 자동 확장 |

### 2.3 보안 (Security)

| ID | 요구사항 |
|---|---|
| NFR-S1 | 사진·영수증 파일 S3 SSE(Server-Side Encryption) 암호화 |
| NFR-S2 | IAM 최소 권한 원칙 — Lambda 함수별 역할 분리 |
| NFR-S3 | Cognito 기반 사용자 인증 |
| NFR-S4 | API Gateway Cognito Authorizer로 인증된 요청만 허용 |

### 2.4 사용성 (Usability)

| ID | 요구사항 |
|---|---|
| NFR-U1 | UI 언어: 한국어 |
| NFR-U2 | 메인 네비게이션: 추천·메뉴판·영수증·일정 탭 (4탭 구조) |
| NFR-U3 | 카메라 촬영 시 가이드라인 프레임 오버레이 제공 |
| NFR-U4 | Material Design 3 기반 일관된 UI/UX |

### 2.5 비용 (Cost)

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-C1 | 월 운영 비용 (PoC, 무료 티어 적용) | ~$5 |
| NFR-C2 | 월 운영 비용 (무료 티어 종료 후) | $10~$20 이하 |
| NFR-C3 | AWS 결제 알람 설정 | Budgets $20 |

### 2.6 관측 가능성 (Observability)

| ID | 요구사항 |
|---|---|
| NFR-O1 | CloudWatch Logs로 모든 Lambda 함수 로그 수집 |
| NFR-O2 | CloudWatch Metrics로 서비스 메트릭 모니터링 |

---

## 3. 기술 요구사항 (Technical Requirements)

### 3.1 AWS AI 서비스 (3종)

| ID | 서비스 | 용도 | 사용 API | 사용 기능 |
|---|---|---|---|---|
| TR-AI1 | Amazon Bedrock (Claude) | 자연어 생성, 분석, 추천, 대화 | InvokeModel | 메인, 서브1, 서브2, 서브3 |
| TR-AI2 | Amazon Textract | 문서/영수증 OCR | DetectDocumentText, AnalyzeExpense | 서브1(메뉴판), 서브2(영수증) |
| TR-AI3 | Amazon Translate | 텍스트 번역 | TranslateText | 서브1(메뉴판 번역) |

### 3.2 AWS 인프라 서비스

| ID | 서비스 | 용도 |
|---|---|---|
| TR-INF1 | AWS Lambda | 서버리스 백엔드 함수 실행 (5종) |
| TR-INF2 | Amazon API Gateway | REST API 엔드포인트 |
| TR-INF3 | Amazon S3 | 사진·영수증 미디어 저장 |
| TR-INF4 | Amazon DynamoDB | 구조화 데이터 저장 |
| TR-INF5 | Amazon Cognito | 사용자 인증 |
| TR-INF6 | Amazon CloudFront | 사진 CDN 배포 |
| TR-INF7 | Amazon CloudWatch | 로그·메트릭 모니터링 |

### 3.3 외부 서비스

| ID | 서비스 | 용도 | 사용 기능 |
|---|---|---|---|
| TR-EXT1 | Google Places API | 주변 장소 검색 (POI 데이터) | 메인(Nearby Search), 서브3(Text Search) |
| TR-EXT2 | ExchangeRate-API | 실시간 환율 조회 | 서브2(원화 환산) |

### 3.4 클라이언트 기술 스택

| ID | 분류 | 기술 | 비고 |
|---|---|---|---|
| TR-CLI1 | 프레임워크 | Flutter (Dart) | Flutter 3.x, Dart 3.x |
| TR-CLI2 | UI | Flutter Widgets | Material Design 3 |
| TR-CLI3 | 카메라 | camera / image_picker 패키지 | 메뉴판·영수증 촬영 |
| TR-CLI4 | 위치 | geolocator 패키지 | GPS 좌표 수집 |
| TR-CLI5 | 네트워크 | dio | REST API 통신 |
| TR-CLI6 | 로컬 DB | sqflite | 오프라인 큐잉 |
| TR-CLI7 | 인증 | AWS Amplify Flutter SDK | Cognito 연동 |

### 3.5 개발·운영 도구

| ID | 분류 | 도구 |
|---|---|---|
| TR-DEV1 | IaC | AWS SAM |
| TR-DEV2 | CI/CD | GitHub Actions |
| TR-DEV3 | 로컬 테스트 | AWS SAM Local |
| TR-DEV4 | 버전 관리 | Git / GitHub |

---

## 4. 데이터 요구사항 (Data Requirements)

### 4.1 데이터 엔티티 목록

| ID | 엔티티 | 저장소 | 설명 |
|---|---|---|---|
| DR-1 | User | DynamoDB | 사용자 프로필 (Cognito Sub ID, 언어, 식이 제한) |
| DR-2 | Trip | DynamoDB | 여행 단위 (목적지, 기간, 통화, 상태) |
| DR-3 | Recommendation | DynamoDB | AI 추천 기록 (좌표, 카테고리, AI 요약) |
| DR-4 | Place | DynamoDB (임베디드) | 추천 장소 (Google Places ID, 별점, 거리, AI 추천 이유) |
| DR-5 | Menu / MenuItem | DynamoDB + S3 | 메뉴판 분석 (사진, 항목, 번역, 추천) |
| DR-6 | Expense | DynamoDB + S3 | 지출 (영수증 사진, 금액, 환산, 카테고리) |
| DR-7 | Schedule | DynamoDB | 일정 (장소, 시간, 수동/AI추천 구분) |
| DR-8 | ChatMessage | DynamoDB | 대화 이력 (사용자/AI 역할, 메시지) |

### 4.2 데이터 관계

```
User (1) ── (N) Trip
                 │
    ┌────────────┼────────────┬────────────┐
   (N)          (N)          (N)          (N)
Recommendation  Menu       Expense     Schedule
    │            │
   (N)          (N)
  Place       MenuItem
 (embedded)  (embedded)

Trip (1) ── (N) ChatMessage
```

### 4.3 미디어 저장 정책

| 유형 | S3 경로 | 암호화 | 비고 |
|---|---|---|---|
| 메뉴판 사진 | photos/ | SSE-S3 | CloudFront CDN 배포 |
| 영수증 이미지 | receipts/ | SSE-S3 | — |

---

## 5. 제약사항 (Constraints)

| ID | 분류 | 제약 내용 |
|---|---|---|
| CON-1 | 플랫폼 | Flutter 크로스 플랫폼: Android + iOS 동시 지원 |
| CON-2 | 목적 | 개인 학습 프로젝트 — 상용 출시 아닌 포트폴리오 목적 |
| CON-3 | 리전 | AWS 서울 리전 우선, Bedrock은 가용 리전(us-east-1) 사용 |
| CON-4 | 비용 | 무료 티어 적극 활용, 월 $20 이하 유지 |
| CON-5 | 개발 기간 | 4주 (12~15주차) |
| CON-6 | 인원 | 1인 개발 |
| CON-7 | Bedrock 리전 | us-east-1 cross-region 호출로 ~200ms 추가 지연 감안 |

---

## 6. Lambda 함수 요구사항

| ID | 함수명 | 역할 | 트리거 | 목표 실행 시간 | AWS 서비스 | 외부 API |
|---|---|---|---|---|---|---|
| LF-1 | fn-health | 헬스체크 | API Gateway | <1초 | — | — |
| LF-2 | fn-recommend | AI 장소 추천 | API Gateway | 3~5초 | Bedrock | Google Places |
| LF-3 | fn-menu | 메뉴판 OCR + 번역 + 추천 | API Gateway | 4~6초 | Textract, Translate, Bedrock | — |
| LF-4 | fn-receipt | 영수증 OCR + 가계부 | API Gateway | 3~4초 | Textract, Bedrock | ExchangeRate-API |
| LF-5 | fn-schedule | 대화형 일정 관리 | API Gateway | 2~4초 | Bedrock | Google Places |

### IAM 역할 (최소 권한)

| 역할 | 핵심 권한 |
|---|---|
| LambdaRecommendRole | `bedrock:InvokeModel`, `dynamodb:PutItem`, `dynamodb:Query` |
| LambdaMenuRole | `textract:DetectDocumentText`, `translate:TranslateText`, `bedrock:InvokeModel`, `s3:GetObject` |
| LambdaReceiptRole | `textract:AnalyzeExpense`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| LambdaScheduleRole | `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem` |

---

## 7. 요구사항 추적 매트릭스 (Traceability Matrix)

| 기능 요구사항 | Lambda 함수 | Use Case | 데이터 엔티티 | AWS AI 서비스 |
|---|---|---|---|---|
| FR-M (AI 장소 추천) | fn-recommend | UC-1 | Recommendation, Place | Bedrock |
| FR-S1 (메뉴판 번역) | fn-menu | UC-2 | Menu, MenuItem | Textract, Translate, Bedrock |
| FR-S2 (영수증 기록) | fn-receipt | UC-3 | Expense | Textract, Bedrock |
| FR-S3 (AI 일정 관리) | fn-schedule | UC-4 | Schedule, ChatMessage | Bedrock |

---

## 8. 위험 요구사항 (Risk Requirements)

### 8.1 미경험 기술 식별표

#### 8.1.1 처음 사용하는 라이브러리 / 프레임워크

| ID | 기술 | 사용 목적 | 숙련도 | 위험 등급 | 관련 요구사항 |
|---|---|---|---|---|---|
| RISK-LIB1 | Flutter Widgets | Flutter UI 구성 | 미경험 | 상 | TR-CLI2 |
| RISK-LIB2 | camera 패키지 | 메뉴판·영수증 촬영 | 미경험 | 중 | TR-CLI3, FR-S1.1, FR-S2.1 |
| RISK-LIB3 | AWS Amplify Flutter SDK | Cognito 인증 연동 | 미경험 | 중 | TR-CLI7, NFR-S3 |
| RISK-LIB4 | sqflite | 로컬 큐잉 및 동기화 | 미경험 | 중 | TR-CLI6, NFR-A2 |
| RISK-LIB5 | dio | REST API 통신 | 미경험 | 중 | TR-CLI5 |
| RISK-LIB6 | AWS SAM (IaC) | Lambda·API Gateway 배포 자동화 | 미경험 | 중 | TR-DEV1 |

**대응 방안**
- 각 라이브러리별 공식 Codelab / 튜토리얼을 착수 전 1회 이상 완주
- Flutter Widgets는 앱 전체 UI의 근간이므로 가장 높은 학습 우선순위 부여
- camera·Amplify Flutter는 공식 샘플 프로젝트를 fork하여 동작 확인 후 프로젝트에 통합

---

#### 8.1.2 처음 사용하는 API / AWS 서비스

| ID | API / 서비스 | 사용 목적 | 숙련도 | 위험 등급 | 관련 요구사항 |
|---|---|---|---|---|---|
| RISK-API1 | Amazon Bedrock (InvokeModel) | 자연어 생성·분석·추천·대화 | 미경험 | 상 | TR-AI1 |
| RISK-API2 | Amazon Textract (DetectDocumentText) | 메뉴판 텍스트 추출 | 미경험 | 중 | TR-AI2, FR-S1.1 |
| RISK-API3 | Amazon Textract (AnalyzeExpense) | 영수증 특화 OCR | 미경험 | 중 | TR-AI2, FR-S2.1 |
| RISK-API4 | Amazon Translate | 텍스트 번역 | 미경험 | 하 | TR-AI3, FR-S1.2 |
| RISK-API5 | Google Places API | 주변 장소 검색 (Nearby/Text Search) | 미경험 | 중 | TR-EXT1, FR-M.3, FR-S3.2 |
| RISK-API6 | ExchangeRate-API | 환율 조회 | 미경험 | 하 | TR-EXT2, FR-S2.3 |
| RISK-API7 | Amazon Cognito | 사용자 인증·권한 관리 | 미경험 | 중 | TR-INF5, NFR-S3 |

**대응 방안**
- **위험 등급 "상"** (Bedrock): 독립 PoC 스크립트로 단독 호출 테스트 먼저 수행. 동작 확인 후 Lambda에 통합
- **위험 등급 "중"** (Textract, Google Places, Cognito): AWS 콘솔 또는 API Explorer에서 수동 테스트 1회 이상 수행 후 코드화
- **위험 등급 "하"** (Translate, ExchangeRate-API): REST API 기반으로 복잡도 낮음. 공식 문서 참고하여 바로 구현 가능

---

#### 8.1.3 AI 의존 위험 (AI 생성 코드 이해도 부족)

| ID | 위험 영역 | 위험 설명 | 위험 등급 |
|---|---|---|---|
| RISK-AI1 | Lambda 비즈니스 로직 | AI가 생성한 AWS SDK 호출 코드(Textract, Bedrock 등)의 파라미터·응답 구조를 본인이 이해하지 못함 | 상 |
| RISK-AI2 | Bedrock 프롬프트 엔지니어링 | AI가 작성한 프롬프트의 의도와 구조를 설명하지 못함. 프롬프트 수정 시 예상치 못한 품질 변화 발생 | 상 |
| RISK-AI3 | SAM / IaC 템플릿 | AI가 생성한 template.yaml의 리소스 정의·권한 설정을 이해하지 못해 배포 오류 시 수정 불가 | 중 |
| RISK-AI4 | Flutter UI | AI가 작성한 Widget의 상태 관리(StatefulWidget, Provider/Riverpod)를 이해하지 못해 UI 버그 수정 불가 | 중 |
| RISK-AI5 | 발표 질의응답 대응 | 코드의 동작 원리를 질문받았을 때 "AI가 작성했다"는 답변만 가능하여 학습 목표 미달 판정 | 상 |

**대응 방안**

| 대응 전략 | 설명 |
|---|---|
| **코드 리뷰 의무화** | AI가 생성한 모든 코드를 커밋 전에 한 줄씩 읽고, 주석 없이도 동작 원리를 말로 설명할 수 있어야 커밋 허용 |
| **"설명 테스트" 규칙** | 각 Lambda 함수 완성 시, 해당 함수의 입력→처리→출력 흐름을 3분 이내에 구두로 설명하는 셀프 테스트 수행. 실패 시 코드를 직접 다시 작성 |
| **핵심 로직 수동 작성** | Bedrock 프롬프트, DynamoDB 쿼리, IAM 권한 정의는 반드시 본인이 직접 작성. AI는 보조 검토 용도로만 활용 |
| **단계적 AI 활용** | 1단계: 본인이 의사 코드 작성 → 2단계: AI로 구현 코드 생성 → 3단계: 생성 코드와 의사 코드 대조 검증 |
| **블랙박스 코드 금지** | 동작은 하지만 원리를 설명하지 못하는 코드는 프로젝트에 포함하지 않음. 이해 불가 시 더 단순한 대안으로 교체 |

---

### 8.2 미경험 기술 위험 요약 매트릭스

```
위험 등급 ▲
  상   │ RISK-LIB1              RISK-API1
       │ RISK-AI1   RISK-AI2    RISK-AI5
       │
  중   │ RISK-LIB2~6            RISK-API2  RISK-API3  RISK-API5  RISK-API7
       │ RISK-AI3   RISK-AI4
       │
  하   │                        RISK-API4  RISK-API6
       └──────────────────────────────────────────────────▶
                라이브러리         API/서비스        AI 의존
```

### 8.3 기능별 미경험 기술 의존도 요약

| 기능 | 미경험 라이브러리 | 미경험 API | AI 의존 위험 | 종합 위험도 |
|---|---|---|---|---|
| FR-M AI 장소 추천 | Flutter Widgets, geolocator | Google Places, Bedrock | 프롬프트, SDK 코드 | **상** |
| FR-S1 메뉴판 번역 | camera 패키지, Flutter Widgets | Textract, Translate, Bedrock | 프롬프트, 파싱 로직 | **상** |
| FR-S2 영수증 기록 | camera 패키지, Flutter Widgets | Textract AnalyzeExpense, Bedrock | SDK 코드 | **중** |
| FR-S3 AI 일정 관리 | Flutter Widgets | Google Places, Bedrock | 프롬프트, 대화 컨텍스트 관리 | **상** |
| 인증 | Amplify Flutter SDK | Cognito | 설정 코드 | **중** |
| 인프라 | SAM | IAM, S3, DynamoDB | IaC 템플릿 | **중** |
