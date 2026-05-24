# Polylog — Architecture Decision Records (ADR)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v2.0 PoC |
| 작성일 | 2026-05-25 |
| 근거 문서 | `polylog-plan.md`, `requirements.md` v2.0 |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-25 | 2.0 | v2.0 기획서 기반 전면 재작성 — Main+Sub 구조, AWS AI 3종, Google Places API 채택 |

---

## ADR 목록

| ID | 제목 | 상태 | 영향 범위 |
|---|---|---|---|
| ADR-001 | 서버리스 아키텍처 채택 (Lambda + API Gateway) | 승인 | 백엔드 전체 |
| ADR-002 | DynamoDB를 주 데이터베이스로 선정 | 승인 | 데이터 계층 전체 |
| ADR-003 | Flutter (Dart) 크로스 플랫폼 채택 | 승인 | 클라이언트 전체 |
| ADR-004 | Amazon Bedrock (Claude)을 종합 AI 엔진으로 채택 | 승인 | AI 처리 계층 |
| ADR-005 | AWS AI 서비스 3종 "깊이 우선" 전략 | 승인 | AI 처리 계층 |
| ADR-006 | Google Places API를 POI 데이터 소스로 채택 | 승인 | 장소 추천·일정 기능 |
| ADR-007 | Amazon Cognito 단독 인증 | 승인 | 인증·인가 |
| ADR-008 | S3 + CloudFront 미디어 저장 전략 | 승인 | 미디어 계층 |
| ADR-009 | Bedrock Cross-Region 호출 (us-east-1) | 승인 | 네트워크·성능 |
| ADR-010 | AWS SAM을 IaC 도구로 선정 | 승인 | 배포·운영 |
| ADR-011 | sqflite 기반 오프라인 큐잉 전략 | 승인 | 클라이언트 네트워크 |

---

## ADR-001: 서버리스 아키텍처 채택 (Lambda + API Gateway)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 백엔드 전체 (5개 Lambda 함수, API Gateway REST API) |
| **관련 요구사항** | TR-INF1, TR-INF2, NFR-A3, NFR-C1, NFR-C2, CON-4 |

### 맥락 (Context)

1인 개발 PoC 프로젝트로 월 $20 이하 비용 제약이 있다. 상시 가동 서버를 운영할 인프라 관리 인력도, 비용 여력도 없다. 동시에 사용량이 불규칙하여(여행 중에만 집중 사용) 고정 비용 구조는 비효율적이다.

### 결정 (Decision)

**AWS Lambda + API Gateway REST API를 백엔드 전체에 적용한다. 상시 가동 서버는 0대로 유지한다.**

- fn-health: 헬스체크
- fn-recommend: AI 장소 추천 (Google Places + Bedrock)
- fn-menu: 메뉴판 OCR + 번역 + 추천 (Textract + Translate + Bedrock)
- fn-receipt: 영수증 OCR + 가계부 (Textract + Bedrock + 환율 API)
- fn-schedule: 대화형 일정 관리 (Google Places + Bedrock)

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **EC2 단일 서버** | 구성 단순, 익숙한 배포 | 상시 비용 발생 ($10~50/월), 스케일링 수동, 1인 운영 부담 | 비용 제약 위반, 관리 부담 |
| **ECS Fargate** | 컨테이너 기반 유연성, 자동 스케일링 | Lambda 대비 설정 복잡, 최소 비용 존재, 학습 곡선 높음 | 과도한 복잡도 |
| **Lambda (채택)** | 사용한 만큼만 과금, 무료 티어 100만 요청/월, 자동 스케일링, 함수 단위 권한 분리 | 콜드 스타트 지연, 실행 시간 제한(15분), 상태 비저장 | — |

### 결과 (Consequences)

**긍정적**
- 무료 티어 내에서 PoC 운영 비용 $0에 근접
- 함수별 IAM 역할 분리로 최소 권한 원칙 자연 적용 (NFR-S2)
- 트래픽 0일 때 비용도 0
- v1.0 대비 Lambda 11종 → 5종으로 간소화, 관리 복잡도 대폭 감소

**부정적**
- 콜드 스타트로 첫 요청 시 1~3초 추가 지연 가능
- Lambda 함수 간 상태 공유 불가 → DynamoDB로 중간 상태 전달 필요
- 로컬 디버깅 환경 구축에 SAM Local 필요 (추가 학습 비용)

---

## ADR-002: DynamoDB를 주 데이터베이스로 선정

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 데이터 계층 전체 (7종 테이블, 8개 엔티티) |
| **관련 요구사항** | TR-INF4, DR-1~DR-8, NFR-C1, CON-4 |

### 맥락 (Context)

8개 엔티티의 관계는 User → Trip → 하위 엔티티(Recommendation, Expense 등)로 단순한 1:N 계층 구조다. 복잡한 JOIN이나 트랜잭션이 거의 없고, 읽기는 대부분 trip_id 기준 파티션 단위 조회이다. 무료 티어 비용 제약과 서버리스 아키텍처와의 자연스러운 통합이 중요하다.

### 결정 (Decision)

**Amazon DynamoDB On-Demand 모드를 주 데이터베이스로 사용한다.**

- 파티션 키: 대부분 `trip_id` 기준
- 정렬 키: `created_at` 또는 엔티티별 고유 ID
- GSI: `user_id` 기반 여행 목록 조회 등 필요 시 추가

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **RDS (MySQL/PostgreSQL)** | SQL 익숙, JOIN 자유, 관계형 모델 자연스러움 | 상시 인스턴스 비용 ($15~/월), Lambda 연결 시 커넥션 풀 관리 필요, VPC 설정 복잡 | 비용 + 서버리스 통합 마찰 |
| **Aurora Serverless v2** | 자동 스케일링, SQL 지원 | 최소 ACU 비용 존재, 설정 복잡 | PoC에 과도한 스펙 |
| **DynamoDB (채택)** | Lambda와 네이티브 통합, 무료 티어 25GB + 25WCU/25RCU, On-Demand 시 사용량 비례 과금, IAM 기반 접근 제어 | NoSQL 설계 학습 필요, 복잡한 쿼리 제한, 유연한 집계 어려움 | — |

### 결과 (Consequences)

**긍정적**
- 무료 티어 내 운영 가능 (PoC 데이터량으로 충분)
- Lambda에서 VPC 없이 직접 접근 → 콜드 스타트 추가 지연 없음
- 테이블별 자동 백업 가능

**부정적**
- 카테고리별 지출 통계 등 집계 쿼리는 애플리케이션 레벨에서 계산 필요
- GSI 추가 시 비용 증가 가능성

---

## ADR-003: Flutter (Dart) 크로스 플랫폼 채택

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 클라이언트 전체 |
| **관련 요구사항** | TR-CLI1, TR-CLI2, CON-1, CON-2 |

### 맥락 (Context)

PoC이자 포트폴리오 프로젝트로, 제한된 4주 일정 내에 핵심 기능을 구현해야 한다. 카메라(메뉴판·영수증 촬영), GPS(장소 추천·일정) 등 네이티브 디바이스 기능에 의존하며, AWS Amplify SDK와의 통합이 필요하다. Android와 iOS 동시 데모가 가능하면 발표 임팩트가 높아진다.

### 결정 (Decision)

**Flutter (Dart)를 크로스 플랫폼 클라이언트로 채택한다. Android + iOS 동시 지원.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Android Native (Kotlin + Compose)** | Google 공식 권장, CameraX 네이티브 통합, Amplify SDK 완전 지원 | Android 전용, iOS 데모 불가 | 단일 플랫폼 제한 |
| **React Native** | JS 생태계 활용 | 네이티브 카메라 성능 제한, AWS SDK 래퍼 필요 | 성능 제한 |
| **Flutter (채택)** | 크로스 플랫폼 (Android + iOS), Hot Reload로 빠른 개발, Amplify Flutter SDK 지원, 선언형 UI | Amplify Flutter SDK가 Android SDK 대비 상대적으로 최신, 네이티브 브릿지 필요 시 추가 작업 | — |

### 결과 (Consequences)

**긍정적**
- Android + iOS 동시 데모로 발표 임팩트 상승
- Hot Reload로 UI 개발 속도 향상
- AWS Amplify Flutter SDK로 Cognito, S3 연동 지원
- Dart 언어의 학습 곡선이 비교적 낮아 진입 장벽 적음

**부정적**
- Amplify Flutter SDK가 Android SDK 대비 상대적으로 최신 — 일부 edge case 문서 부족 가능
- camera 패키지가 CameraX보다 기능이 제한적이나, 사진 촬영 용도로는 충분
- Flutter 미경험으로 학습 곡선 존재 (RISK-LIB1)

---

## ADR-004: Amazon Bedrock (Claude)을 종합 AI 엔진으로 채택

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | AI 처리 계층 전체 (4개 기능 모두에서 사용) |
| **관련 요구사항** | TR-AI1, FR-M.4, FR-S1.3, FR-S2.2, FR-S3.1 |

### 맥락 (Context)

4개 기능(AI 장소 추천, 메뉴 추천, 영수증 분류, 대화형 일정)에서 자연어 생성이 필요하다. 단순 번역이나 분류가 아닌, 컨텍스트를 종합하여 자연스러운 한국어 추천·분류·대화를 생성해야 한다. AWS 생태계 내에서 통합되어야 IAM 권한 관리와 비용 추적이 일원화된다.

### 결정 (Decision)

**Amazon Bedrock의 Claude 모델(Haiku 위주)을 종합 자연어 생성 엔진으로 사용한다.**

- 비용 효율: Haiku 모델 기본 사용 (500회/월 × 평균 1K tokens ≈ $1.00)
- 4개 기능에서 각기 다른 패턴으로 활용:

| 기능 | Bedrock 활용 패턴 | 복잡도 |
|---|---|---|
| 메인: AI 장소 추천 | 단발 추천 (장소 후보 → 개인화 큐레이션) | 낮음 |
| 서브1: 메뉴판 번역 | 개인화 추천 (번역된 메뉴 + 식이 제한 → 추천) | 중간 |
| 서브2: 영수증 기록 | 단발 분류 (상호명 + 항목 → 카테고리) | 낮음 |
| 서브3: AI 일정 관리 | 대화형 컨텍스트 (이전 대화 + 일정 + 장소 → 추천) | 높음 |

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **OpenAI API (GPT)** | 높은 범용성, 풍부한 커뮤니티 | AWS 외부 → IAM 통합 불가, API 키 관리 별도, 비용 추적 분리 | AWS 생태계 이탈 |
| **SageMaker 자체 모델** | 모델 커스터마이징 가능 | 엔드포인트 상시 비용, 모델 운영 부담, PoC에 과도 | 비용·복잡도 과다 |
| **Bedrock Claude (채택)** | IAM 기반 접근 제어, Lambda에서 AWS SDK로 직접 호출, 사용량 비례 과금, 한국어 성능 우수 | us-east-1 리전 제약, cross-region 지연 ~200ms | — |

### 결과 (Consequences)

**긍정적**
- 4개 기능에서 동일한 호출 패턴 (InvokeModel) 재사용
- IAM 역할 기반 접근 → API 키 유출 위험 없음
- 프롬프트만 변경하여 다양한 출력 생성 (추천, 분류, 대화)
- 단발 추천 → 개인화 → 대화형으로 점진적 복잡도 증가 — 학습 효과 극대화

**부정적**
- us-east-1 cross-region 호출 지연 (~200ms) → ADR-009에서 별도 다룸
- 프롬프트 엔지니어링 품질에 출력 품질이 크게 의존 (RISK-AI2)
- 모델 업데이트 시 출력 일관성 변화 가능

---

## ADR-005: AWS AI 서비스 3종 "깊이 우선" 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | AI 처리 계층 전체 |
| **관련 요구사항** | TR-AI1~TR-AI3 |

### 맥락 (Context)

v1.0에서는 AWS AI 서비스 7종(Rekognition, Bedrock, Transcribe, Translate, Polly, Textract, Location Service)의 "넓은 커버리지"를 목표로 했으나, 4주라는 짧은 개발 기간과 1인 개발 제약 하에서 7종을 모두 의미 있게 통합하기 어렵다고 판단했다. 특히 Transcribe Streaming(WebSocket 기반)과 Step Functions(ASL 학습)은 각각 구현 난이도가 높아 일정 리스크가 컸다.

### 결정 (Decision)

**AWS AI 서비스를 7종에서 3종(Bedrock, Textract, Translate)으로 줄이되, 각 서비스를 여러 기능에서 다양한 패턴으로 깊이 있게 활용하는 "깊이 우선" 전략을 채택한다.**

```
v1.0: 7종 × 얕은 활용 (서비스당 1~2회 사용)
v2.0: 3종 × 깊은 활용 (서비스당 2~4가지 패턴)
```

| 서비스 | 사용 기능 | 활용 패턴 |
|---|---|---|
| **Bedrock (Claude)** | 메인, 서브1, 서브2, 서브3 (4개 전체) | 단발 추천, 개인화 추천, 단발 분류, 대화형 컨텍스트 |
| **Textract** | 서브1, 서브2 | DetectDocumentText (메뉴판), AnalyzeExpense (영수증) — API 2종 |
| **Translate** | 서브1 | TranslateText (메뉴판 번역) |

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **7종 유지 (v1.0)** | AWS AI 서비스 폭넓은 경험 | 4주 내 7종 통합 불가능, 각 서비스 피상적 사용, 일정 리스크 "상" | 일정·품질 리스크 과다 |
| **Bedrock 멀티모달 단독** | 아키텍처 최단순 (1종만 사용) | AWS AI 학습 목표 미달, OCR 정확도 낮음 (특히 영수증), 비용 높음 | 학습 목표 위반 + 정확도 부족 |
| **3종 깊이 활용 (채택)** | 핵심 서비스를 다양한 패턴으로 체득, 4주 내 완성 현실적, 2단계 파이프라인 구조 유지 | 커버리지 축소 (Rekognition, Transcribe, Polly 미사용) | — |

### v1.0 대비 제거된 서비스 및 사유

| 제거된 서비스 | 제거 사유 | 대체 방안 |
|---|---|---|
| **Rekognition** | 장소 인식(FR-1) 기능 제거 → 사용처 없음. Google Places API가 POI 데이터 제공 | Google Places API |
| **Transcribe Streaming** | 실시간 통역(FR-2) 기능 제거. WebSocket 기반 구현 난이도가 4주 일정에 과도 | — (기능 자체 제거) |
| **Polly** | 음성 합성 사용처 없음 (통역 제거) | — (기능 자체 제거) |
| **Location Service** | Google Places API가 POI 검색 + 리뷰/별점/사진 등 더 풍부한 데이터 제공 | Google Places API |

### 결과 (Consequences)

**긍정적**
- Bedrock를 4가지 패턴으로 활용 → "하나의 서비스, 다양한 응용" 학습 깊이 확보
- Textract의 2가지 API(DetectDocumentText, AnalyzeExpense) 비교 학습
- 서비스 3종으로 미경험 기술 위험(RISK-API) 대폭 감소
- 4주 내 완성 가능한 현실적 범위

**부정적**
- 음성 기반 기능(통역, TTS) 미포함 — 발표 시 "확장 가능성"으로 제시
- AWS AI 서비스 커버리지 수치 자체는 감소 (7종 → 3종)
- Rekognition, Transcribe 실전 경험 미확보

---

## ADR-006: Google Places API를 POI 데이터 소스로 채택

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 메인(AI 장소 추천), 서브3(AI 일정 관리) |
| **관련 요구사항** | TR-EXT1, FR-M.3, FR-S3.2 |

### 맥락 (Context)

메인 기능(AI 장소 추천)과 서브3(AI 일정 관리)에서 현재 GPS 위치 기반으로 주변 장소(맛집, 숙소, 관광지, 카페)를 검색해야 한다. 장소 이름, 별점, 리뷰 수, 가격대, 영업시간, 사진 등 풍부한 POI(Point of Interest) 데이터가 필요하다.

### 결정 (Decision)

**Google Places API를 주변 장소 검색의 단일 데이터 소스로 채택한다.**

- 메인 기능: **Nearby Search API** — GPS 좌표 + 카테고리 기반 반경 검색
- 서브3: **Text Search API** — 사용자 자연어 키워드 + 위치 바이어스 기반 검색

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **AWS Location Service** | AWS 생태계 내 통합, IAM 접근 제어 | POI 데이터 품질 열세 (리뷰·별점·사진·영업시간 부족), 특히 해외 여행지 데이터 불충분 | POI 데이터 품질 부족 |
| **Foursquare Places API** | POI 데이터 풍부 | Google 대비 커버리지 낮음, 별도 API 키 관리, 커뮤니티 규모 작음 | 커버리지 열세 |
| **Google Places API (채택)** | 전 세계 POI 데이터 최대 커버리지, 별점·리뷰·사진·영업시간·가격대 포함, 월 $200 무료 크레딧, Nearby Search + Text Search 2종 제공 | AWS 외부 서비스 → API 키 관리 별도, IAM 통합 불가 | — |

### GPS vs Location Service vs Google Places API 구분

| 구분 | 역할 | 이 프로젝트에서의 용도 |
|---|---|---|
| **GPS** | 하드웨어 센서. 위도·경도 좌표만 반환 | geolocator 패키지로 현재 위치 좌표 수집 |
| **AWS Location Service** | 역지오코딩, 라우팅, 지오펜싱 등 위치 인프라 서비스. POI 데이터는 제한적 | **미사용** — POI 데이터 품질이 Google Places 대비 부족 |
| **Google Places API** | 전 세계 POI 데이터베이스. 장소 이름, 별점, 리뷰, 사진, 영업시간, 가격대 등 풍부한 정보 | 메인(Nearby Search) + 서브3(Text Search)에서 장소 후보 수집 |

### 결과 (Consequences)

**긍정적**
- 해외 여행지에서도 풍부한 POI 데이터 확보 (별점, 리뷰 수, 사진, 영업시간)
- 월 $200 무료 크레딧으로 PoC 비용 $0
- Bedrock에 전달하는 장소 후보 데이터 품질이 높아 AI 추천 품질 향상

**부정적**
- AWS 외부 서비스 → API 키를 Lambda 환경 변수 또는 Secrets Manager로 관리 필요
- Google Places API 사용량이 월 $200 크레딧을 초과하면 추가 비용 발생 (PoC 기준 300회/월이면 크레딧 내)
- AWS 생태계 외부 의존성 1개 추가

---

## ADR-007: Amazon Cognito 단독 인증

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 인증·인가 전체 |
| **관련 요구사항** | TR-INF5, NFR-S3, NFR-S4 |

### 맥락 (Context)

PoC 프로젝트로 소셜 로그인(Google, Kakao 등)은 범위 밖이다. 이메일+비밀번호 기반 기본 인증이면 충분하며, API Gateway의 요청 인가와 통합이 필요하다.

### 결정 (Decision)

**Amazon Cognito User Pool을 단독 인증 솔루션으로 사용하고, API Gateway Cognito Authorizer로 요청을 인가한다.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Firebase Auth** | 설정 간편, Google 로그인 쉬움 | AWS 외부 → API Gateway 통합에 Custom Authorizer Lambda 필요, 토큰 검증 직접 구현 | AWS 통합 마찰 |
| **자체 JWT 구현** | 완전한 커스터마이징 | 보안 위험, 토큰 관리 직접 구현, MFA 등 추가 기능 구현 부담 | 보안 위험 과다 |
| **Cognito (채택)** | API Gateway 네이티브 통합, Amplify Flutter SDK 지원, 무료 티어 50,000 MAU, JWT 자동 발급·검증 | 설정 복잡도, 커스터마이징 제한 | — |

### 결과 (Consequences)

**긍정적**
- API Gateway Cognito Authorizer 연결로 인증 로직 코드 없이 요청 인가
- Amplify Flutter SDK로 회원가입·로그인 UI 빠르게 구현
- 무료 티어 50,000 MAU → PoC에 충분

**부정적**
- Cognito 설정(User Pool, App Client, 도메인)이 복잡하여 초기 세팅 시간 소요 (RISK-API7)
- 소셜 로그인 추가 시 Identity Pool 추가 설정 필요

---

## ADR-008: S3 + CloudFront 미디어 저장 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 미디어 저장 계층 |
| **관련 요구사항** | TR-INF3, TR-INF6, NFR-S1, DR-5, DR-6 |

### 맥락 (Context)

메뉴판 사진(서브1)과 영수증 이미지(서브2) 등 바이너리 미디어 파일을 안전하게 저장하고, 앱에서 빠르게 조회할 수 있어야 한다. DynamoDB에 바이너리를 저장하는 것은 비용·성능 면에서 비효율적이다.

### 결정 (Decision)

**S3에 미디어를 용도별 프리픽스(photos/, receipts/)로 분리 저장하고, 사진 조회에는 CloudFront CDN을 적용한다.**

| 프리픽스 | 용도 | 관련 기능 |
|---|---|---|
| photos/ | 메뉴판 사진 | 서브1 |
| receipts/ | 영수증 이미지 | 서브2 |

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **DynamoDB 직접 저장** | 단일 저장소 관리 | 항목 크기 제한 400KB, 바이너리 저장 비용 매우 높음, 읽기 성능 저하 | 기술적 부적합 |
| **Firebase Storage** | 설정 간편 | AWS 외부, IAM 통합 불가, Lambda에서 접근 시 추가 인증 필요 | AWS 생태계 이탈 |
| **S3 + CloudFront (채택)** | 무제한 용량, SSE 암호화, Lambda 네이티브 접근, CDN으로 앱 조회 성능 향상, 무료 티어 5GB | S3 버킷 정책 설정 학습 | — |

### 결과 (Consequences)

**긍정적**
- SSE-S3 암호화로 저장 시점부터 보안 적용 (NFR-S1)
- CloudFront로 사진 조회 지연 최소화
- v1.0 대비 저장 분류 단순화 (3종 → 2종: audio/ 제거)

**부정적**
- 프리사인드 URL 생성 로직 필요 (앱에서 직접 업로드 시)
- S3 버킷 정책 + CloudFront OAI 설정 학습 필요

---

## ADR-009: Bedrock Cross-Region 호출 (us-east-1)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | Bedrock 호출 관련 모든 Lambda 함수 (fn-recommend, fn-menu, fn-receipt, fn-schedule) |
| **관련 요구사항** | CON-3, CON-7, NFR-P1, RISK-API1 |

### 맥락 (Context)

프로젝트의 주 인프라는 서울 리전(ap-northeast-2)에 배포하나, Bedrock Claude 모델은 서울 리전에서 가용하지 않다(2026-05 기준). 가장 안정적인 Bedrock 리전은 us-east-1(버지니아)이다. v2.0에서는 4개 Lambda 함수 모두 Bedrock을 사용하므로 영향 범위가 크다.

### 결정 (Decision)

**Lambda는 서울 리전에 배포하되, Bedrock 호출 시에만 us-east-1 리전의 Bedrock 엔드포인트를 cross-region으로 호출한다.**

```python
# Lambda (ap-northeast-2) → Bedrock (us-east-1)
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')
```

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **전체 인프라를 us-east-1에 배포** | Bedrock 지연 없음 | S3, DynamoDB, API Gateway 모두 해외 → 앱↔API 지연 증가 | 전체 서비스 지연 증가 |
| **Cross-region 호출 (채택)** | 대부분 서비스는 서울 리전 유지, Bedrock만 us-east-1 | Bedrock 호출 시 ~200ms 추가 지연 | — |

### 결과 (Consequences)

**긍정적**
- S3, DynamoDB, API Gateway 등은 서울 리전에서 낮은 지연으로 동작
- 사용자 체감 지연은 Bedrock 호출 구간에만 국한

**부정적**
- Bedrock 호출마다 ~200ms 네트워크 오버헤드
- 4개 Lambda 함수 모두 영향 → 전체 응답 시간에 일괄적으로 ~200ms 추가
- 대응: 프롬프트 최적화(토큰 최소화) + Google Places/Textract 결과 사전 가공으로 완화

---

## ADR-010: AWS SAM을 IaC 도구로 선정

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 배포·운영 전체 |
| **관련 요구사항** | TR-DEV1, TR-DEV3, CON-2 |

### 맥락 (Context)

Lambda + API Gateway + DynamoDB 중심의 서버리스 아키텍처를 코드로 관리해야 한다. 포트폴리오 프로젝트이므로 재현 가능성(reproducibility)이 중요하다. 로컬 테스트 환경도 필요하다. v2.0에서는 Step Functions을 사용하지 않으므로 SAM의 서버리스 특화 기능만으로 충분하다.

### 결정 (Decision)

**AWS SAM (Serverless Application Model)을 IaC 및 로컬 테스트 도구로 사용한다.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Terraform** | 멀티 클라우드, 풍부한 커뮤니티, 세밀한 리소스 제어 | 서버리스 특화 아닌 범용 도구, HCL 학습 필요, 로컬 Lambda 테스트 미지원 | 로컬 테스트 부재 |
| **AWS CDK** | TypeScript/Python으로 인프라 정의, 추상화 수준 높음 | 추상화가 오히려 학습에 방해, 디버깅 시 CloudFormation 레벨까지 추적 필요 | PoC에 과도한 추상화 |
| **Serverless Framework** | 서버리스 특화, 플러그인 풍부 | 3rd-party 도구, 유료 기능 존재 | AWS 공식 도구 우선 |
| **AWS SAM (채택)** | 서버리스 특화, `sam local` 로컬 테스트, CloudFormation 호환, AWS 공식 도구 | SAM 특유의 제약 | — |

### 결과 (Consequences)

**긍정적**
- `sam local invoke`로 Lambda 로컬 테스트 가능 (TR-DEV3)
- template.yaml 하나로 전체 인프라 재현 → GitHub에 포함하여 포트폴리오 가치 상승
- CloudFormation 호환으로 AWS 콘솔에서 스택 관리 가능
- v2.0에서는 Lambda 5종 + API Gateway + DynamoDB만 관리 → SAM 축약 문법으로 충분

**부정적**
- SAM 템플릿 문법 학습 필요 (RISK-LIB6)

---

## ADR-011: sqflite 기반 오프라인 큐잉 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 클라이언트 네트워크 처리 |
| **관련 요구사항** | TR-CLI6, NFR-A2 |

### 맥락 (Context)

여행 중 네트워크가 불안정하거나 단절되는 상황이 빈번하다. 사용자가 촬영한 메뉴판 사진, 영수증 이미지 등이 네트워크 단절로 유실되면 안 된다(NFR-A2: 데이터 유실 0%). 오프라인에서도 기본적인 데이터 수집은 계속되어야 한다.

### 결정 (Decision)

**sqflite 로컬 데이터베이스에 오프라인 요청 큐를 구현하고, 네트워크 복구 시 자동으로 일괄 업로드(동기화)한다.**

```
[오프라인 동작 흐름]
사진 촬영 → sqflite 큐 저장 (status: PENDING)
         → 네트워크 감지 (connectivity_plus 패키지)
         → 연결 복구 시 큐 순차 처리 (S3 업로드 → API 호출)
         → 성공 시 status: COMPLETED
         → 실패 시 status: RETRY (최대 3회)
```

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **SharedPreferences** | 구현 최단순 | 구조화 데이터 부적합, 큐 관리 어려움, 대용량 미지원 | 기능 부족 |
| **파일 시스템 직접 관리** | 미디어 파일은 이미 로컬 저장 | 메타데이터 관리 어려움, 큐 상태 추적 불편, 정렬·검색 불가 | 관리 복잡도 |
| **sqflite (채택)** | SQLite 기반 구조화, 큐 상태 관리 용이, Dart async/await 지원, 크로스 플랫폼 호환 | sqflite 라이브러리 학습 필요 | — |

### 결과 (Consequences)

**긍정적**
- 네트워크 단절 시에도 사용자 경험 연속성 유지
- 큐 테이블의 status 컬럼으로 PENDING/UPLOADING/COMPLETED/FAILED 상태 추적
- StreamController/ChangeNotifier로 큐 변화 실시간 감지 → UI에 동기화 진행률 표시 가능

**부정적**
- sqflite 스키마 설계 + connectivity_plus 리스너 구현 추가 공수
- 동기화 순서 보장 로직 (시간순 큐 처리) 필요
- 미디어 파일 자체는 sqflite가 아닌 로컬 파일시스템에 저장 → 메타데이터와 파일의 일관성 관리 필요
