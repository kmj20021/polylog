# Polylog — Architecture Decision Records (ADR)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v2.0 PoC |
| 작성일 | 2026-05-25 |
| 근거 문서 | `polylog-plan.md`, `requirements.md` v2.0, `polylog-iam-guide.md` (관리자 IAM 발급 회신) |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-25 | 2.0 | v2.0 기획서 기반 전면 재작성 — Main+Sub 구조, AWS AI 3종, Google Places API 채택 |
| 2026-05-26 | 2.0.1 | ADR-001에 사용 패턴 분석(세션 길이≠요청 빈도) 및 서버리스 재검토 트리거 조건 추가 |
| 2026-05-26 | 2.0.2 | 리뷰 피드백 반영 — ADR-008 CloudFront 철회(S3 Presigned URL로 대체), ADR-006 Secrets Manager 옵션 철회(Lambda 환경변수로 일원화) |
| 2026-05-27 | 2.0.3 | 관리자 IAM 발급 가이드(`polylog-iam-guide.md`) 반영 — Cognito 미제공으로 ADR-007 대체(소셜 OAuth + 무상태 Lambda Authorizer), 공용 실행 역할 ADR-012·자원 네이밍/CloudShell 배포 ADR-013 신설, ADR-001(역할 모델)·ADR-008(CloudFront 차단 확정)·ADR-010(로컬 SAM 제약) 갱신, Lambda 5종→6종 |
| 2026-06-01 | 2.0.4 | Phase 1 점검 결과 반영 — ADR-007 provider 범위를 **Google 단독·Android 전용**으로 확정(Kakao 보류). `fn-authorizer`는 Google JWKS만 검증, Flutter 타깃 `android` 단일. |

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
| ADR-007 | 소셜 OAuth(Google 단독) 인증 (Cognito 대체, 2026-06-01 범위 확정) | 대체 | 인증·인가 |
| ADR-008 | S3 미디어 저장 전략 (CloudFront 철회, 2026-05-26 갱신) | 승인 | 미디어 계층 |
| ADR-009 | Bedrock Cross-Region 호출 (us-east-1) | 승인 | 네트워크·성능 |
| ADR-010 | AWS SAM을 IaC 도구로 선정 | 승인 | 배포·운영 |
| ADR-011 | sqflite 기반 오프라인 큐잉 전략 | 승인 | 클라이언트 네트워크 |
| ADR-012 | 공용 IAM 실행 역할 (SafeRole-polylog) 사용 | 승인 | 인증·인가·배포 |
| ADR-013 | 자원 네이밍(polylog prefix) 및 CloudShell 배포 규약 | 승인 | 배포·운영 |

---

## ADR-001: 서버리스 아키텍처 채택 (Lambda + API Gateway)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-25 |
| **영향 범위** | 백엔드 전체 (6개 Lambda 함수, API Gateway REST API) |
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
- fn-authorizer: API Gateway Lambda Authorizer — Google OAuth ID 토큰을 Google JWKS로 검증 (무상태, ADR-007 / Kakao 보류)

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **EC2 단일 서버** | 구성 단순, 익숙한 배포 | 상시 비용 발생 ($10~50/월), 스케일링 수동, 1인 운영 부담 | 비용 제약 위반, 관리 부담 |
| **ECS Fargate** | 컨테이너 기반 유연성, 자동 스케일링 | Lambda 대비 설정 복잡, 최소 비용 존재, 학습 곡선 높음 | 과도한 복잡도 |
| **Lambda (채택)** | 사용한 만큼만 과금, 무료 티어 100만 요청/월, 자동 스케일링, 함수 단위 권한 분리 | 콜드 스타트 지연, 실행 시간 제한(15분), 상태 비저장 | — |

### 사용 패턴 분석 — 세션 길이 ≠ 요청 빈도

"여행 중 앱을 계속 사용한다"는 **세션(포그라운드) 길이**가 길다는 의미이지, **백엔드 요청 빈도**가 높다는 의미가 아니다. 4개 기능은 모두 사람이 트리거하는 요청-응답 패턴으로, 앱을 하루 종일 열어둬도 백엔드 호출은 불연속 버스트로 발생한다(메뉴판 촬영 1회 → 수 분간 읽기, 추천 요청 1회 → 이동·관광). `polylog-plan.md` §9의 사용량 가정(Bedrock 500회/월, Google Places 300회/월, Textract 80회/월 ≈ 활발한 여행자 하루 15~25회)이 이를 뒷받침한다.

따라서 과금·확장을 결정하는 축은 세션 길이가 아니라 **요청 빈도(버스트형)**이며, 이는 서버리스의 교과서적 적합 사례다.

- **비용**: Lambda는 호출·실행시간 단위 과금이라 세션 길이와 무관. 위 사용량은 무료 티어 내로 Lambda 비용 ~$0 유지(NFR-C1, CON-4). 상시 EC2는 월 $10~50 고정 → 버스트형에서 서버리스가 엄격히 저렴.
- **콜드 스타트(완화)**: 콜드 스타트는 유휴 후 첫 호출에만 발생. 연속 사용 세션에서는 Lambda가 warm 유지되어 후속 호출 페널티 없음 → 연속 사용은 오히려 단점을 줄이는 방향.
- **네트워크 리스크 분리**: 여행 환경의 실제 위험은 해외·불안정 네트워크이며 이는 서버리스 vs 상시 서버와 무관한 축이다. ADR-011(sqflite 오프라인 큐잉)이 별도로 담당하므로 서버 전환으로 해결되지 않는다.

### 서버리스 재검토 트리거 조건

현 v2.0에는 해당 없으나, 아래 도입 시 해당 부분만 재검토한다.

| 조건 | v2.0 해당 | 비고 |
|---|---|---|
| 영속 연결/스트리밍(WebSocket) | ❌ | 기획 §10 *실시간 통역(Transcribe Streaming)* 확장 시 해당 기능만 WebSocket API/별도 컴포넌트로 분리 |
| 지속적 고RPS 정상 부하 | ❌ | 수천 RPS 상시 수준에서야 예약 용량이 유리 (PoC 무관) |
| 15분 초과 장시간 연산 | ❌ | OCR·Bedrock 호출은 초 단위 |

### 결과 (Consequences)

**긍정적**
- 무료 티어 내에서 PoC 운영 비용 $0에 근접
- 권한 격리는 공용 실행 역할 `SafeRole-polylog` + `polylog` prefix·`group=polylog` 태그 기반으로 적용 (NFR-S2, 상세는 ADR-012). 함수별 역할 분리는 운영 단계에서 재검토.
- 트래픽 0일 때 비용도 0
- v1.0 대비 Lambda 11종 → 6종(핵심 5 + 인가 1)으로 간소화, 관리 복잡도 대폭 감소

**부정적**
- 콜드 스타트로 첫 요청 시 1~3초 추가 지연 가능
- Lambda 함수 간 상태 공유 불가 → DynamoDB로 중간 상태 전달 필요
- 로컬 디버깅 제약 — Access Key 미발급으로 `sam local`/로컬 `sam deploy` 불가, 배포·통합 검증은 콘솔 CloudShell·실환경 의존 (ADR-010·ADR-013)

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

PoC이자 포트폴리오 프로젝트로, 제한된 4주 일정 내에 핵심 기능을 구현해야 한다. 카메라(메뉴판·영수증 촬영), GPS(장소 추천·일정) 등 네이티브 디바이스 기능에 의존하며, REST API 통신(dio)과 소셜 로그인 SDK(google_sign_in/kakao) 연동이 필요하다. Android와 iOS 동시 데모가 가능하면 발표 임팩트가 높아진다.

### 결정 (Decision)

**Flutter (Dart)를 크로스 플랫폼 클라이언트로 채택한다. Android + iOS 동시 지원.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Android Native (Kotlin + Compose)** | Google 공식 권장, CameraX 네이티브 통합, AWS SDK 네이티브 지원 | Android 전용, iOS 데모 불가 | 단일 플랫폼 제한 |
| **React Native** | JS 생태계 활용 | 네이티브 카메라 성능 제한, 소셜 로그인·AWS 호출 래퍼 필요 | 성능 제한 |
| **Flutter (채택)** | 크로스 플랫폼 (Android + iOS), Hot Reload로 빠른 개발, 소셜 로그인 SDK(google_sign_in/kakao) 지원, 선언형 UI | 일부 플러그인 성숙도 편차, 네이티브 브릿지 필요 시 추가 작업 | — |

### 결과 (Consequences)

**긍정적**
- Android + iOS 동시 데모로 발표 임팩트 상승
- Hot Reload로 UI 개발 속도 향상
- 소셜 로그인 SDK(google_sign_in/kakao)로 OAuth, dio로 REST·S3 Presigned URL 연동
- Dart 언어의 학습 곡선이 비교적 낮아 진입 장벽 적음

**부정적**
- 소셜 로그인 SDK·일부 플러그인의 플랫폼별 성숙도 편차 — edge case 문서 부족 가능
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
- AWS 외부 서비스 → API 키 관리 필요. **Lambda 환경변수로 관리**한다 (2026-05-26 갱신: 기존 "환경변수 또는 Secrets Manager" 중 Secrets Manager 옵션은 리뷰 피드백에 따라 철회 — 키 1개·PoC 규모에 별도 시크릿 저장소는 오버엔지니어링).
- Google Places API 사용량이 월 $200 크레딧을 초과하면 추가 비용 발생 (PoC 기준 300회/월이면 크레딧 내)
- AWS 생태계 외부 의존성 1개 추가

---

## ADR-007: 소셜 OAuth(Google/Kakao) 인증 (Cognito 대체)

| 항목 | 내용 |
|---|---|
| **상태** | 대체 (2026-05-27 — 원 Cognito 결정은 아래 갱신 블록으로 대체됨) |
| **일자** | 2026-05-25 (원안) / 2026-05-27 (갱신) |
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

### 갱신 (2026-05-27) — Cognito 철회, 소셜 OAuth + 무상태 Lambda Authorizer로 대체

> 관리자 IAM 발급 회신(`polylog-iam-guide.md`)에서 **Cognito는 제공하지 않는다**고 통보했다. 위 원 결정은 이력 보존을 위해 남기되, 아래로 대체된다.

**철회 사유**

관리자 측 두 원칙으로 정리됨: (1) *You Are Not Google* — 트래픽 없는 단계의 운영급 인증 추상화는 비용·복잡도만 증가, (2) *Premature optimization* — Cognito의 MFA·SSO·User Pool 관리는 시연용 PoC에 불필요. Cognito는 IAM·트리거 람다·콜백 URL이 얽혀 디버깅 표면이 넓고, 인증 학습은 Polylog 4개 핵심 기능과 별개 트랙이다.

**새 결정**

**사용자 인증은 소셜 OAuth(Google/Kakao)를 Flutter 클라이언트에서 직접 연동하고, API 보호는 무상태 Lambda Authorizer(`fn-authorizer`)로 처리한다.**

- 클라이언트: `google_sign_in` / `kakao_flutter_sdk`로 OAuth → provider ID 토큰 획득. `user_id = provider sub`.
- 백엔드: `fn-authorizer`가 API Gateway Lambda Authorizer로서 ID 토큰을 **provider 공개키(JWKS)로 검증** → 인증된 요청만 통과(NFR-S4 유지). 영속 인증 인프라(User Pool 등) 0.
- AWS 인증 서비스(Cognito) 미사용. `fn-authorizer`는 공용 `SafeRole-polylog`를 재사용(추가 AWS 권한 불필요 — 외부 JWKS 조회 + 토큰 검증만).

| 대안 | 장점 | 단점 | 채택 여부 |
|---|---|---|---|
| 게스트/Mock (서버측 검증 없음) | 가장 단순, 백엔드 0 | API 사실상 공개 → 영수증·사진(개인정보, NFR-S1) 보호 미흡 | 기각 |
| 직접 구현 JWT (이메일+bcrypt+로그인 Lambda) | 학습 가치 | 비밀번호 저장·해시 관리 부담, 회원 DB 운영 | 기각 |
| **소셜 OAuth + 무상태 Lambda Authorizer (채택)** | 비밀번호 미보관, 영속 인프라 0, NFR-S4 유지, Cognito 대비 디버깅 표면 축소 | provider별 redirect URI 설정, JWKS 검증 코드(~30줄) | — |

**결과**

- 긍정적: 비밀번호 직접 관리 불필요(provider 위임), Cognito 설정/RISK-API7 제거, `fn-authorizer` 무상태라 콜드스타트·비용 영향 미미.
- 부정적: Google/Kakao 콘솔에서 OAuth 클라이언트·redirect URI 설정 필요, ID 토큰 만료·갱신을 클라이언트가 처리, Lambda 함수 1종(`fn-authorizer`) 추가(5종→6종, ADR-001).

> 관련 문서: `polylog-iam-guide.md` §"Cognito는 제공하지 않습니다".

### 갱신 (2026-06-01) — provider 범위 Google 단독·Android 전용 확정

> Phase 1(외부 의존성 트리거) 점검에서 실제 등록 상태를 확인한 결과, OAuth 클라이언트는 **Google(Android 전용) 1종만** 발급되어 있다. 4주 PoC·1인 개발(CON-6) 범위에서 provider를 하나로 좁혀 인증 트랙 공수를 줄이는 결정을 확정한다.

**결정**

- 인증 provider는 **Google 단독**. Kakao는 보류(필요 시 후속 ADR로 재개 — provider별 JWKS·redirect만 추가하면 되는 무상태 구조라 후행 추가 비용 낮음).
- 클라이언트는 `google_sign_in`만 사용. `kakao_flutter_sdk` 의존성 제거.
- 타깃 플랫폼은 **Android 전용**(`flutter create --platforms=android`). iOS는 범위 밖.
- `fn-authorizer`는 **Google JWKS(`https://www.googleapis.com/oauth2/v3/certs`) 검증만** 구현. `iss=accounts.google.com`(또는 `https://accounts.google.com`)·`aud=Google 클라이언트 ID` 확인.

**근거**

- 두 provider 동시 지원은 JWKS·iss·aud 분기와 콘솔 설정을 2배로 늘리나, PoC 시연에는 로그인 경로 하나면 충분(Premature optimization 회피 — ADR-007 원 철회 사유와 동일 논리).
- Android 전용은 에뮬레이터 단일 환경으로 E2E 관통(Phase 4) 검증을 단순화.

**영향**

- `fn-authorizer` 구현 범위 축소(Google JWKS 단일 경로).
- Exit State #5·#6, bootstrap-plan §1.2·§4.1이 Google·Android로 정정됨(동기화 완료).
- 보류 항목: Kakao OAuth, iOS 빌드.

### 갱신 (2026-06-07) — 검증 방식: JWKS 로컬 → **Google tokeninfo 엔드포인트**로 단일화

> **결정**: `fn-authorizer`의 토큰 검증을 RS256 로컬 JWKS 대신 Google **tokeninfo**(`GET https://oauth2.googleapis.com/tokeninfo?id_token=<JWT>`)에 위임한다. 구글이 서명·만료를 검증해 클레임을 반환하고, 함수는 `iss∈{accounts.google.com, https://accounts.google.com}`·`aud=GOOGLE_CLIENT_ID`만 추가 확인한다.

**근거**
- 로컬 JWKS RS256 검증은 `PyJWT`+`cryptography` 번들이 필요 → "배포 패키지 의존성 0"(SafeRole·urllib 패턴) 원칙과 CloudShell 패키징을 깨뜨린다.
- tokeninfo 는 urllib GET 1회로 끝나 의존성 0·새 IAM 0(환율 API 패턴과 동일). PoC 트래픽(거의 0)에선 호출당 1회 외부 왕복 비용이 무의미. (대규모 트래픽 시 로컬 JWKS 로 후행 전환 가능 — 무상태라 교체 쉬움.)
- 사용자 승인(2026-06-07).

**영향**
- `fn-authorizer` 구현 = `app.py`(tokeninfo 검증, TOKEN authorizer, context.user_id=sub). 단위테스트 8 passed.
- env `GOOGLE_CLIENT_ID`(웹 클라이언트 ID=aud) 주입(deploy.sh 5-5). 미설정 시 aud 검증만 생략.
- authorizer 부착은 `scripts/setup-authorizer.sh`(create/enable/disable). `/health`·OPTIONS 는 강제 제외(배포 헬스체크·CORS).
- 클라이언트는 `google_sign_in`(serverClientId=GOOGLE_CLIENT_ID) → idToken → `Authorization: Bearer` 자동 첨부(DioClient 인터셉터).

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

### 갱신 (2026-05-26) — CloudFront 철회

> 인프라 관리팀 리뷰 피드백을 반영하여 **CloudFront를 철회**한다. 위 "S3 + CloudFront" 원 결정은 이력 보존을 위해 남기되, 아래로 대체된다.

| 항목 | 변경 후 |
|---|---|
| **결정** | CloudFront 미사용. 미디어 **업로드·조회 모두 S3 Presigned URL**로 처리. |
| **권장 설정** | S3 SSE-S3 암호화 + **퍼블릭 액세스 차단**. CloudFront 배포·OAI 불필요. |
| **사유** | (1) PoC 트래픽 규모에서 CDN 캐싱 이득 미미. (2) 영수증·메뉴판은 **개인정보**(NFR-S1)라 공개 CDN/정적 호스팅이 부적합 — 서명 URL이 인증·만료 제어 측면에서 더 적합. (3) 배포+OAI 설정 복잡도만 증가하는 오버엔지니어링. |
| **영향** | 원 "부정적" 항목의 "CloudFront OAI 설정 학습" 불필요. Presigned URL 로직은 업로드용으로 이미 필요했으므로 조회로 확장 시 추가 공수 거의 없음. |

> **2026-05-27 추가 확인**: 관리자 IAM 발급 가이드(`polylog-iam-guide.md`)에서 CloudFront는 **플랫폼 차원에서도 차단**(Route 53·ACM·CloudFront 등)임이 확인됐다. 본 철회는 내부 설계 판단과 플랫폼 제약이 모두 일치하는 확정 사항이다.

> 관련 문서: `AWS_R.md` §3 C-2, `polylog-iam-guide.md`.

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
- template.yaml 하나로 전체 인프라 재현 → GitHub에 포함하여 포트폴리오 가치 상승
- CloudFormation 호환으로 AWS 콘솔에서 스택 관리 가능
- v2.0에서는 Lambda 6종(핵심 5 + 인가 1) + API Gateway + DynamoDB만 관리 → SAM 축약 문법으로 충분

**부정적**
- SAM 템플릿 문법 학습 필요 (RISK-LIB6)
- 로컬 `sam local invoke` 테스트는 제약 — 아래 갱신 참조

### 갱신 (2026-05-27) — 배포 방식: CloudShell 전용, 공용 역할 참조

> 관리자 IAM 발급 가이드(`polylog-iam-guide.md`) 반영.

- **배포는 콘솔 CloudShell에서 `sam deploy`로만 수행한다.** Access Key가 발급되지 않으므로 로컬 머신에서의 `sam deploy`/`sam local invoke`는 사용하지 않는다(AWS 자격증명 필요한 로컬 테스트 제약 — TR-DEV3 갱신). 로직 검증은 Bedrock 등 호출이 적은 단위는 별도 PoC 스크립트로, 통합 검증은 배포 후 실환경에서 수행.
- **실행 역할은 공용 `SafeRole-polylog`를 참조한다**(ADR-012). `iam:CreateRole`이 차단되어 함수별 역할 생성 불가하므로 SAM 템플릿에 한 줄로 고정:

  ```yaml
  Globals:
    Function:
      Role: !Sub arn:aws:iam::${AWS::AccountId}:role/SafeRole-polylog
  ```

- **배포 산출물 버킷은 `polylog-sam-deploy`를 직접 선생성**한다(ADR-013). `--guided` 기본 버킷명(`aws-sam-cli-managed-default-...`)은 `polylog` prefix 위반으로 거부됨:

  ```bash
  aws s3 mb s3://polylog-sam-deploy --region ap-northeast-2
  sam deploy --guided --s3-bucket polylog-sam-deploy --stack-name polylog-backend
  ```

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

---

## ADR-012: 공용 IAM 실행 역할 (SafeRole-polylog) 사용

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-27 |
| **영향 범위** | 모든 Lambda 함수(6종)의 실행 역할, 배포 |
| **관련 요구사항** | NFR-S2 |

### 맥락 (Context)

원안(ADR-001, `AWS_R.md` §4-1)은 함수별 IAM 역할 4종을 분리해 최소 권한 원칙(NFR-S2)을 적용하려 했다. 그러나 관리자 IAM 발급 가이드(`polylog-iam-guide.md`)에서 **`iam:CreateRole`이 차단**되어 학생이 새 역할을 만들 수 없고, 모든 Lambda는 **사전 생성된 공용 역할 `SafeRole-polylog`를 공유**하도록 통보됐다.

### 결정 (Decision)

**모든 Lambda 함수는 공용 실행 역할 `SafeRole-polylog`를 사용한다.** SAM 템플릿에서 `Globals.Function.Role`로 일괄 지정한다.

```yaml
Globals:
  Function:
    Role: !Sub arn:aws:iam::${AWS::AccountId}:role/SafeRole-polylog
```

`SafeRole-polylog`에는 Bedrock / Textract / Translate / DynamoDB(`polylog*`) / S3(`polylog*`) / CloudWatch Logs 권한이 포함되어 있다. (`fn-authorizer`는 외부 JWKS 조회·토큰 검증만 하므로 이 역할의 권한 중 별도로 요구하는 것은 없다.)

### 근거 (Rationale)

- `iam:CreateRole` 차단으로 함수별 역할 분리가 **물리적으로 불가**.
- 관리자 판단: 함수 4종을 따로 만드는 분리 효과보다, **`polylog` prefix + `group=polylog` 태그 격리**로 이미 blast radius가 그룹 내부로 한정되어 차이가 거의 없음. 태그(username, group)는 자동 부착되며 수동 변경 불가.
- PoC 단계에서 충분하며, **함수별 최소권한 분리는 운영 단계에서 재검토**한다.

### 결과 (Consequences)

**긍정적**
- 역할 생성·`PassRole` 설정 불필요 → 배포 단순화(SAM 한 줄).
- prefix·태그 기반 격리로 팀(그룹) 외부 자원 접근 차단.

**부정적**
- 함수별 최소권한(NFR-S2 원안)에서 후퇴 — 한 역할이 모든 함수 권한을 보유(운영 단계 재검토 트리거).
- `SafeRole-polylog` 권한 변경은 관리자 영역 → 새 AWS 서비스 사용 시 `#999-general-tech-qna`로 권한 추가 요청 필요.

> 관련 문서: `polylog-iam-guide.md` §"Lambda / API Gateway / SAM 배포", §"Access Key는 절대 발급 불가".

---

## ADR-013: 자원 네이밍(polylog prefix) 및 CloudShell 배포 규약

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-27 |
| **영향 범위** | S3·DynamoDB 등 모든 자원 네이밍, 배포 절차 |
| **관련 요구사항** | TR-DEV1, TR-DEV3, CON-4 |

### 맥락 (Context)

공용 AWS 계정(shingu-cs / 443370697536)을 polylog 그룹 4계정(polylog-1~4)이 공유한다. 관리자는 자원 격리를 위해 **모든 자원 이름에 `polylog` prefix를 강제**하고, **Access Key를 발급하지 않아 배포를 콘솔 CloudShell로 제한**한다.

### 결정 (Decision)

1. **네이밍**: S3·DynamoDB 등 생성하는 모든 자원 이름은 `polylog`로 시작한다. prefix가 맞지 않으면 **생성 자체가 거부**된다.
   - S3 예: `polylog-media`, `polylog-sam-deploy`
   - DynamoDB 예: `polylog-users`, `polylog-trips`, `polylog-expenses`
2. **배포**: 콘솔 **CloudShell에서 `sam deploy`** 로만 수행(로컬 X). 배포 버킷 `polylog-sam-deploy`는 첫 배포 전 직접 생성. 함수 생성 직후 ~5초 반영 지연 존재(새로고침).

### 근거 (Rationale)

- prefix·태그 격리는 1인당 별도 계정 대신 공용 계정을 쓰면서도 blast radius를 그룹 내부로 한정하는 관리자의 격리 모델(ADR-012)과 일관.
- Access Key 미발급은 키 유출 위험을 원천 차단 — CloudShell은 세션 자격증명을 사용하므로 로컬에 장기 키를 두지 않음.

### 결과 (Consequences)

**긍정적**
- 팀 내 자원 소유 구분이 이름으로 드러남(README·prefix 컨벤션 권장).
- 자격증명 유출 표면 최소화.

**부정적**
- 로컬 `sam local`·로컬 `sam deploy` 불가 → 디버깅은 CloudShell·실환경 의존(ADR-010 갱신, TR-DEV3).
- 팀 4명이 같은 네임스페이스를 공유하므로 이름 충돌 방지 컨벤션 필요(앱 개발 자체는 1인 — CON-6).

> 관련 문서: `polylog-iam-guide.md` §"S3 / DynamoDB — 이름은 반드시 polylog로 시작", §"격리 모델".

---

## ADR-014: 일정 테이블 단일화 (schedules + schedule-items 통합)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-31 |
| **영향 범위** | DynamoDB `polylog-schedules`, `fn-schedule` Lambda, Flutter 일정 탭 |
| **관련 요구사항** | FR-S3.1~S3.5, DR-7, NFR-P4 |

### 맥락 (Context)

Phase 2.3에서 일정 테이블을 `polylog-schedules`(헤더, PK=schedule_id) + `polylog-schedule-items`(상세, PK=item_id) 두 개로 분리 생성했다. 그러나 (1) 두 테이블 모두 PK가 standalone UUID여서 어느 여행 소속인지 키로 표현되지 않고, (2) FR-S3.4(타임라인 뷰)·FR-S3.5(컨텍스트 재추천)가 모두 "한 여행의 모든 일정을 한 번에 조회"하는 패턴이라 분리는 매 호출 2 round-trip 또는 GSI 추가 비용을 발생시킨다.

### 결정 (Decision)

**`polylog-schedule-items`를 삭제**하고 **`polylog-schedules` 단일 테이블로 재설계**한다. 키 구조는 PK=`trip_id` (HASH), SK=`start_time` (RANGE, ISO 8601 문자열). 기존 `schedule_id`는 일반 속성으로 강등하여 외부 참조(예: ChatMessage → Schedule 링크) 용도로만 사용한다.

### 근거 (Rationale)

- DynamoDB는 "함께 조회되는 데이터는 같은 파티션에"가 원칙(NoSQL anti-normalization). 헤더만/디테일만 따로 보는 화면이 기획에 없다.
- 데이터 규모가 작다 — PoC 시나리오 기준 1여행 3~7일×5~10항목 = 30~70 row, 분리 이득 없음.
- SK를 시간으로 두면 `Query`가 자동 시간순 정렬을 반환하여 정렬 로직을 클라이언트에서 제거할 수 있다.
- 분리를 유지해도 현재 두 테이블의 standalone-UUID PK는 어차피 재설계해야 하므로, 통합으로 가는 비용이 절감 비용보다 크지 않다.

### 결과 (Consequences)

**긍정적**
- 타임라인 뷰가 단일 `Query` 호출로 끝나 NFR-P4(4초) 여유 확보.
- 트랜잭션 일관성 단순화 — 일정 추가 시 한 테이블만 쓰면 됨.
- 스키마가 polylog-plan.md 원안(7장 Schedule)과 일치.

**부정적**
- 만약 향후 일정 헤더(일별 요약, 날씨 등)가 추가되면 같은 파티션에 다른 타입 row를 섞거나(SK prefix로 구분, single-table design) 추가 테이블로 분리하는 재결정이 필요. 현 PoC 범위에서는 불필요.

### 적용 절차

1. CloudShell: `aws dynamodb delete-table --table-name polylog-schedule-items`
2. CloudShell: `aws dynamodb delete-table --table-name polylog-schedules`
3. CloudShell: `archive/mk_DynamoDB_logic.md` #2 명령으로 `polylog-schedules` 재생성
4. `polylog-plan.md` 7장 Schedule 엔티티 정의 동기화 (완료)

> 관련 문서: `archive/mk_DynamoDB_logic.md` §"2. 여행 일정 서랍장", `polylog-plan.md` §7.2 Schedule.

---

## ADR-015: 도메인 4종 테이블 trip_id 파티션 통일 (recommendations / menus / receipts / chats)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-31 |
| **영향 범위** | DynamoDB `polylog-recommendations`, `polylog-menus`, `polylog-receipts`, `polylog-chats` 및 대응 Lambda 4종(`fn-recommend`, `fn-menu`, `fn-receipt`, `fn-schedule`) |
| **관련 요구사항** | FR-M.6, FR-S1, FR-S2.4, FR-S3.1, DR-3·DR-5·DR-6·DR-8, NFR-P1~P4 |

### 맥락 (Context)

Phase 2.3 초기 생성 시 4개 도메인 테이블이 모두 **PK=standalone-UUID**(`recommend_id`, `menu_id`, `receipt_id`, `chat_id`) 구조로 만들어졌다. 이 구조에서는 "어느 여행 소속인지"가 키로 표현되지 않아 사실상 매 조회가 `Scan`이 된다. ADR-014에서 `polylog-schedules`에 대해 동일한 문제를 해결한 뒤, 나머지 4개도 같은 구조적 결함을 안고 있음이 확인됐다.

요구사항 분석 결과 4개 모두 **"여행 단위 시간순 조회"가 1차 액세스 패턴**이다:
- FR-M.6 추천 이력 — 한 여행의 추천 누적 조회
- FR-S1 메뉴판 — 한 여행 중 분석한 메뉴판 이력
- FR-S2.4 일별·카테고리별 지출 — 한 여행의 결제 시각순 정렬
- FR-S3.1 대화 컨텍스트 — 한 여행의 메시지를 Bedrock 호출 직전 시간순 일괄 로드

### 결정 (Decision)

4개 테이블을 모두 삭제 후 **PK=`trip_id` (HASH) + SK=시간 속성 (RANGE, ISO 8601)** 합성키로 재생성한다. 기존 standalone UUID PK는 일반 속성으로 강등하여 외부 참조용으로만 보존한다.

| 테이블 | PK | SK | SK 시간 속성 선택 사유 |
|---|---|---|---|
| `polylog-recommendations` | `trip_id` | `created_at` | 추천 발생 시각 — 누적 이력 |
| `polylog-menus` | `trip_id` | `created_at` | 촬영 시점 — 시간순 정렬 |
| `polylog-receipts` | `trip_id` | `occurred_at` | 결제 시각 — "일별 지출" 정렬 직접 충족 |
| `polylog-chats` | `trip_id` | `created_at` | 메시지 시각 — 대화 순서 보장 |

### 근거 (Rationale)

- **ADR-014와 동일한 NoSQL 원칙 재적용** — "함께 조회되는 데이터는 같은 파티션에". 4개 도메인 모두 trip 단위 일괄 조회가 핵심.
- **Lambda 코드가 안정된 스키마 위에 작성되어야 함** — Phase 3 이후 `fn-recommend`/`fn-menu`/`fn-receipt`/`fn-schedule`이 본격 구현되기 전에 키 구조를 확정해야 두 번 만들지 않는다.
- **시간 SK 선택은 1차 액세스 패턴에 정렬 비용 0으로 응답** — `Query` 결과가 자동 정렬되어 클라이언트 정렬 로직 제거.
- **데이터 0건 상태에서 적용** — 마이그레이션 비용 없음. 지금이 가장 싼 변경 시점.

### 결과 (Consequences)

**긍정적**
- 모든 도메인 조회가 `Query` 한 번으로 종료 → NFR-P1~P4 응답 시간 여유.
- 4개 테이블 키 패턴이 통일되어 Lambda 코드의 DynamoDB 호출 모양이 일관됨.
- 카테고리 GSI(receipts), place_id 역인덱스(recommendations) 같은 후속 보강은 키 변경 없이 GSI 추가만으로 가능.

**부정적**
- `trip_id` 없이 단건만 알고 있는 경우(예: 외부 URL로 단일 메뉴 공유) `GetItem`을 직접 호출할 수 없음 → 운영상 그런 패턴이 등장하면 `id-index` GSI를 별도로 추가해야 함. 현 PoC 범위에서는 불필요.
- `receipts`의 카테고리별 집계는 데이터가 커지면 클라이언트 그룹화로 한계 → `category-index` GSI 추가 결정이 후속으로 필요할 수 있음 (현 PoC 규모에서는 보류).

### 적용 절차

1. CloudShell: 기존 4개 테이블 삭제
   ```bash
   aws dynamodb delete-table --table-name polylog-recommendations --region ap-northeast-2
   aws dynamodb delete-table --table-name polylog-menus           --region ap-northeast-2
   aws dynamodb delete-table --table-name polylog-receipts        --region ap-northeast-2
   aws dynamodb delete-table --table-name polylog-chats           --region ap-northeast-2
   ```
2. CloudShell: `archive/mk_DynamoDB_logic.md` #3~#6 명령으로 4개 재생성.
3. 검증: `aws dynamodb list-tables`(7개 유지) + 각 테이블 `describe-table --query 'Table.KeySchema'`로 `trip_id`(HASH) + 시간(RANGE) 확인.
4. `polylog-plan.md` §7.2 Recommendation / Menu / Expense / ChatMessage 엔티티 정의 동기화 (완료).

> 관련 문서: `archive/mk_DynamoDB_logic.md` §"3~6", `polylog-plan.md` §7.2 Recommendation/Menu/Expense/ChatMessage. ADR-014와 같은 결정 패턴의 4개 도메인 일괄 적용판.
