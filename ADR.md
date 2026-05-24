# Polylog — Architecture Decision Records (ADR)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v1.0 |
| 작성일 | 2026-05-24 |
| 근거 문서 | `polylog-planning.md`, `requirements.md` |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-24 | 1.0 | 최초 작성 — 12건의 아키텍처 의사결정 기록 |

---

## ADR 목록

| ID | 제목 | 상태 | 영향 범위 |
|---|---|---|---|
| ADR-001 | 서버리스 아키텍처 채택 (Lambda + API Gateway) | 승인 | 백엔드 전체 |
| ADR-002 | DynamoDB를 주 데이터베이스로 선정 | 승인 | 데이터 계층 전체 |
| ADR-003 | Android (Kotlin + Jetpack Compose) 단일 플랫폼 | 승인 | 클라이언트 전체 |
| ADR-004 | Amazon Bedrock (Claude)을 종합 AI 엔진으로 채택 | 승인 | AI 처리 계층 |
| ADR-005 | AWS AI 서비스 7종 조합 전략 | 승인 | AI 처리 계층 |
| ADR-006 | Transcribe Streaming (WebSocket) 실시간 통역 | 승인 | 통역 기능 |
| ADR-007 | Step Functions로 여행기 생성 오케스트레이션 | 승인 | 여행기 기능 |
| ADR-008 | Amazon Cognito 단독 인증 | 승인 | 인증·인가 |
| ADR-009 | S3 + CloudFront 미디어 저장 전략 | 승인 | 미디어 계층 |
| ADR-010 | Bedrock Cross-Region 호출 (us-east-1) | 승인 | 네트워크·성능 |
| ADR-011 | AWS SAM을 IaC 도구로 선정 | 승인 | 배포·운영 |
| ADR-012 | Room 기반 오프라인 큐잉 전략 | 승인 | 클라이언트 네트워크 |

---

## ADR-001: 서버리스 아키텍처 채택 (Lambda + API Gateway)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 백엔드 전체 (11개 Lambda 함수, API Gateway REST/WebSocket) |
| **관련 요구사항** | TR-INF1, TR-INF2, NFR-A3, NFR-C1, NFR-C2, CON-4 |

### 맥락 (Context)

1인 개발 PoC 프로젝트로 월 $30 이하 비용 제약이 있다. 상시 가동 서버를 운영할 인프라 관리 인력도, 비용 여력도 없다. 동시에 사용량이 불규칙하여(여행 중에만 집중 사용) 고정 비용 구조는 비효율적이다.

### 결정 (Decision)

**AWS Lambda + API Gateway를 백엔드 전체에 적용한다. 상시 가동 서버는 0대로 유지한다.**

- REST API: 장소 인식, 메뉴판, 영수증, 채팅, 날씨 (fn-place, fn-menu, fn-receipt, fn-chat, fn-weather)
- WebSocket API: 실시간 통역 (fn-translate)
- Step Functions 트리거: 여행기 생성 (fn-diary-orchestrator)

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

**부정적**
- 콜드 스타트로 첫 요청 시 1~3초 추가 지연 가능
- Lambda 함수 간 상태 공유 불가 → DynamoDB 또는 S3로 중간 상태 전달 필요
- 로컬 디버깅 환경 구축에 SAM Local 필요 (추가 학습 비용)

---

## ADR-002: DynamoDB를 주 데이터베이스로 선정

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 데이터 계층 전체 (7종 테이블, 9개 엔티티) |
| **관련 요구사항** | TR-INF4, DR-1~DR-9, NFR-C1, CON-4 |

### 맥락 (Context)

9개 엔티티의 관계는 User → Trip → 하위 엔티티(Place, Expense 등)로 단순한 1:N 계층 구조다. 복잡한 JOIN이나 트랜잭션이 거의 없고, 읽기는 대부분 trip_id 기준 파티션 단위 조회이다. 무료 티어 비용 제약과 서버리스 아키텍처와의 자연스러운 통합이 중요하다.

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
- 단일 테이블 디자인 vs 다중 테이블 설계 의사결정 추가 필요
- GSI 추가 시 비용 증가 가능성

---

## ADR-003: Android (Kotlin + Jetpack Compose) 단일 플랫폼

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 클라이언트 전체 |
| **관련 요구사항** | TR-CLI1, TR-CLI2, CON-1, CON-2 |

### 맥락 (Context)

PoC이자 포트폴리오 프로젝트로, 제한된 6주 일정 내에 7개 기능을 구현해야 한다. 카메라, 마이크, GPS 등 네이티브 디바이스 기능에 깊이 의존하며, AWS Amplify SDK와의 통합이 필요하다. iOS 동시 개발은 일정상 불가능하다.

### 결정 (Decision)

**Android 네이티브 (Kotlin + Jetpack Compose)를 단일 클라이언트 플랫폼으로 채택한다. iOS는 PoC 범위에서 제외한다.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Flutter** | 크로스 플랫폼, 빠른 UI 개발 | AWS Amplify Flutter 지원 제한적, CameraX 직접 사용 불가, 네이티브 브릿지 오버헤드 | AWS SDK 통합 마찰 |
| **React Native** | JS 생태계, 웹 경험 활용 | 네이티브 카메라·오디오 스트리밍 성능 제한, AWS SDK 래퍼 필요 | 실시간 오디오 처리 부적합 |
| **Kotlin + Compose (채택)** | Google 공식 권장, CameraX·FusedLocation 네이티브 통합, Amplify SDK 완전 지원, 최신 선언형 UI | Android 전용, Compose 학습 곡선 | — |

### 결과 (Consequences)

**긍정적**
- CameraX, Transcribe Streaming 오디오 등 네이티브 기능에 직접 접근
- AWS Amplify Android SDK의 Cognito, S3 연동 완전 지원
- Android 최신 스택 학습 (학습 목표 L-3 달성)

**부정적**
- iOS 사용자 대상 시연 불가
- Jetpack Compose 미경험으로 학습 곡선 존재 (RISK-LIB1)

---

## ADR-004: Amazon Bedrock (Claude)을 종합 AI 엔진으로 채택

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | AI 처리 계층 전체 (5개 기능에서 사용) |
| **관련 요구사항** | TR-AI2, FR-1.3, FR-3.3, FR-4.2, FR-5.2, FR-7.1 |

### 맥락 (Context)

5개 기능(장소 설명, 메뉴 추천, 여행기 작성, 영수증 분류, 채팅 일정)에서 자연어 생성이 필요하다. 단순 번역이나 분류가 아닌, 컨텍스트를 종합하여 자연스러운 한국어 설명·추천·일기를 생성해야 한다. AWS 생태계 내에서 통합되어야 IAM 권한 관리와 비용 추적이 일원화된다.

### 결정 (Decision)

**Amazon Bedrock의 Claude 모델(Haiku 위주)을 종합 자연어 생성 엔진으로 사용한다.**

- 비용 효율: Haiku 모델 기본 사용 (500회/월 × 평균 1K tokens ≈ $1.00)
- 품질 필요 시: 여행기 작성 등 긴 텍스트 생성에 한해 Sonnet 고려

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **OpenAI API (GPT)** | 높은 범용성, 풍부한 커뮤니티 | AWS 외부 서비스 → IAM 통합 불가, API 키 관리 별도, 비용 추적 분리 | AWS 생태계 이탈 |
| **SageMaker 자체 모델** | 모델 커스터마이징 가능 | 엔드포인트 상시 비용, 모델 운영 부담, PoC에 과도 | 비용·복잡도 과다 |
| **Bedrock Claude (채택)** | IAM 기반 접근 제어, Lambda에서 AWS SDK로 직접 호출, 사용량 비례 과금, 한국어 성능 우수 | us-east-1 리전 제약, cross-region 지연 ~200ms | — |

### 결과 (Consequences)

**긍정적**
- 5개 기능에서 동일한 호출 패턴 (InvokeModel) 재사용
- IAM 역할 기반 접근 → API 키 유출 위험 없음
- 프롬프트만 변경하여 다양한 출력 생성 (설명, 추천, 일기, 분류)

**부정적**
- us-east-1 cross-region 호출 지연 (~200ms) → ADR-010에서 별도 다룸
- 프롬프트 엔지니어링 품질에 출력 품질이 크게 의존 (RISK-AI2)
- 모델 업데이트 시 출력 일관성 변화 가능

---

## ADR-005: AWS AI 서비스 7종 조합 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | AI 처리 계층 전체 |
| **관련 요구사항** | TR-AI1~TR-AI7, T-1 |

### 맥락 (Context)

이 프로젝트의 핵심 학습 목표(L-1)는 AWS AI 서비스의 실전 통합 패턴 체득이다. 단일 AI 모델로 모든 작업을 처리하는 것은 기술적으로 가능하나, 각 서비스의 특화 기능을 조합하는 것이 품질과 비용 면에서 더 효율적이다.

### 결정 (Decision)

**각 기능에서 특화 서비스가 1차 처리(인식·추출·변환)를 수행하고, Bedrock Claude가 최종 종합·생성을 담당하는 2단계 파이프라인을 채택한다.**

```
입력 → [특화 서비스: 구조화된 데이터 추출] → [Bedrock: 자연어 종합·생성] → 출력
```

| 기능 | 1차 처리 (특화 서비스) | 2차 처리 (Bedrock) |
|---|---|---|
| 장소 인식 | Rekognition (라벨) + Location (장소명) | 종합 설명 생성 |
| 통역 | Transcribe (음성→텍스트) + Translate (번역) + Polly (음성 합성) | — (불필요) |
| 메뉴판 | Textract (텍스트 추출) + Translate (번역) | 메뉴 추천 생성 |
| 영수증 | Textract AnalyzeExpense (구조화 추출) | 카테고리 분류 |
| 여행기 | Rekognition (사진 태깅) | 여행기 작성 |
| 채팅 일정 | Location (POI 검색) | 큐레이션 추천 생성 |

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Bedrock 멀티모달 단독** | 아키텍처 단순, 이미지+텍스트 동시 처리 | 비용 높음 (이미지 토큰 비쌈), OCR 정확도 낮음, 실시간 음성 처리 불가 | 비용·정확도·실시간 처리 한계 |
| **2단계 파이프라인 (채택)** | 특화 서비스의 높은 정확도, Bedrock 토큰 비용 절감 (구조화 데이터만 전달), 서비스별 학습 | 서비스 간 연동 복잡도, 서비스 수 증가에 따른 관리 부담 | — |

### 결과 (Consequences)

**긍정적**
- Textract의 영수증 특화 정확도 > Bedrock 멀티모달 OCR
- Bedrock에 구조화된 데이터만 전달하여 토큰 비용 절감
- AWS AI 서비스 7종 실전 통합 경험 (학습 목표 L-1 달성)

**부정적**
- 서비스 7종 모두 미경험 → 학습·통합 비용 높음 (RISK-API1~12)
- 서비스 간 데이터 포맷 변환 로직 필요
- 장애 지점(failure point) 증가

---

## ADR-006: Transcribe Streaming (WebSocket) 실시간 통역

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 통역 기능 (FR-2) |
| **관련 요구사항** | TR-AI3, FR-2.1, NFR-P2 |

### 맥락 (Context)

통역 기능은 2초 이내 응답이 요구된다(NFR-P2). 사용자가 말하는 동안 실시간으로 텍스트를 보여주고, 발화 종료 즉시 번역+음성 합성을 시작해야 자연스러운 통역 경험이 가능하다.

### 결정 (Decision)

**Amazon Transcribe Streaming API를 WebSocket으로 연결하여 실시간 음성→텍스트 변환을 수행한다.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Transcribe Batch** | 구현 단순 (S3 업로드 → 결과 폴링) | 발화 완료 후 파일 업로드 → 처리 → 결과 수신까지 5~10초, 2초 목표 불가 | 실시간 요구사항 위반 |
| **Google Speech-to-Text** | 한국어 정확도 높음, 스트리밍 지원 | AWS 생태계 외부, API 키 관리 별도, IAM 통합 불가 | AWS 통합 원칙 위반 |
| **Transcribe Streaming (채택)** | 실시간 부분 결과 제공, AWS IAM 통합, 발화 종료 즉시 최종 결과 | WebSocket 구현 복잡도 높음, 한국어 정확도 이슈 가능 | — |

### 결과 (Consequences)

**긍정적**
- 사용자가 말하는 동안 부분 결과(partial result)를 화면에 표시 → UX 향상
- VAD(Voice Activity Detection) 내장으로 발화 종료 자동 감지

**부정적**
- WebSocket 기반으로 REST API 대비 구현 복잡도 상 (RISK-API2)
- 한국어 정확도 부족 시 Custom Vocabulary 추가 작업 필요
- **폴백 경로**: 구현 실패 시 텍스트 직접 입력 → Translate → Polly 흐름으로 대체

---

## ADR-007: Step Functions로 여행기 생성 오케스트레이션

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 자동 여행기 기능 (FR-4) |
| **관련 요구사항** | TR-INF9, FR-4.1, FR-4.2, LF-7~LF-10 |

### 맥락 (Context)

여행기 생성은 4단계 순차 처리가 필요하다: 데이터 수집 → 사진 병렬 분석 → 컨텍스트 통합 → Bedrock 작성. 특히 사진 분석 단계에서 10~20장을 병렬로 처리(Map State)해야 하며, 각 단계 실패 시 재시도 로직이 필요하다. 전체 소요 시간은 30초~1분으로 Lambda 단일 호출로도 가능하지만 가시성과 에러 핸들링이 떨어진다.

### 결정 (Decision)

**AWS Step Functions Standard Workflow로 여행기 생성 파이프라인을 오케스트레이션한다.**

```
[fn-diary-orchestrator] → Step Functions State Machine
                           ├── State 1: fn-diary-collector (데이터 수집)
                           ├── State 2: Map State → fn-diary-photo-analyzer (병렬)
                           ├── State 3: 컨텍스트 통합 (Pass State)
                           └── State 4: fn-diary-writer (Bedrock 여행기 작성)
                                          └── fn-notify (SNS 푸시)
```

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **단일 Lambda 순차 호출** | 구현 단순, 학습 비용 없음 | 실행 시간 길어짐, 사진 병렬 분석 불가, 중간 실패 시 처음부터 재실행, 디버깅 어려움 | 병렬 처리·에러 핸들링 부족 |
| **SQS + Lambda 체이닝** | 비동기 처리, 재시도 내장 | 오케스트레이션 로직이 분산되어 흐름 파악 어려움, 상태 추적 불편 | 가시성 부족 |
| **Step Functions (채택)** | Map State 병렬 처리, Catch/Retry 내장, 실행 흐름 시각화, 각 단계 독립 디버깅 | ASL 학습 곡선, 첫 사용 (RISK-API8) | — |

### 결과 (Consequences)

**긍정적**
- 사진 10~20장 병렬 분석으로 처리 시간 단축
- 단계별 Retry/Catch로 Bedrock 일시 장애에도 자동 재시도
- AWS 콘솔에서 실행 흐름 시각적 추적 가능 (학습 목표 L-2)

**부정적**
- ASL(Amazon States Language) 학습 필요 (RISK-API8)
- **폴백 경로**: 14주차 2일차까지 미완성 시 단일 Lambda 순차 호출로 전환

---

## ADR-008: Amazon Cognito 단독 인증

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
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
| **Cognito (채택)** | API Gateway 네이티브 통합, Amplify SDK 지원, 무료 티어 50,000 MAU, JWT 자동 발급·검증 | 설정 복잡도, 커스터마이징 제한 | — |

### 결과 (Consequences)

**긍정적**
- API Gateway Cognito Authorizer 연결로 인증 로직 코드 없이 요청 인가
- Amplify Android SDK로 회원가입·로그인 UI 빠르게 구현
- 무료 티어 50,000 MAU → PoC에 충분

**부정적**
- Cognito 설정(User Pool, App Client, 도메인)이 복잡하여 초기 세팅 시간 소요 (RISK-API10)
- 소셜 로그인 추가 시 Identity Pool 추가 설정 필요

---

## ADR-009: S3 + CloudFront 미디어 저장 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 미디어 저장 계층 |
| **관련 요구사항** | TR-INF3, TR-INF6, NFR-S1, DR-3~DR-6 |

### 맥락 (Context)

사진(장소·메뉴판), 음성(통역·메모), 영수증 이미지 등 바이너리 미디어 파일을 안전하게 저장하고, 앱에서 빠르게 조회할 수 있어야 한다. DynamoDB에 바이너리를 저장하는 것은 비용·성능 면에서 비효율적이다.

### 결정 (Decision)

**S3에 미디어를 용도별 프리픽스(photos/, audio/, receipts/)로 분리 저장하고, 사진 조회에는 CloudFront CDN을 적용한다.**

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
- S3 라이프사이클 정책으로 비용 자동 관리 가능

**부정적**
- 프리사인드 URL 생성 로직 필요 (앱에서 직접 업로드 시)
- S3 버킷 정책 + CloudFront OAI 설정 학습 필요

---

## ADR-010: Bedrock Cross-Region 호출 (us-east-1)

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | Bedrock 호출 관련 모든 Lambda 함수 |
| **관련 요구사항** | CON-3, CON-7, NFR-P1, RISK-API1 |

### 맥락 (Context)

프로젝트의 주 인프라는 서울 리전(ap-northeast-2)에 배포하나, Bedrock Claude 모델은 서울 리전에서 가용하지 않다(2026-05 기준). 가장 안정적인 Bedrock 리전은 us-east-1(버지니아)이다.

### 결정 (Decision)

**Lambda는 서울 리전에 배포하되, Bedrock 호출 시에만 us-east-1 리전의 Bedrock 엔드포인트를 cross-region으로 호출한다.**

```python
# Lambda (ap-northeast-2) → Bedrock (us-east-1)
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')
```

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **전체 인프라를 us-east-1에 배포** | Bedrock 지연 없음 | S3, DynamoDB, API Gateway 모두 해외 → 앱↔API 지연 증가, Location Service 서울 데이터 정확도 저하 | 전체 서비스 지연 증가 |
| **Cross-region 호출 (채택)** | 대부분 서비스는 서울 리전 유지, Bedrock만 us-east-1 | Bedrock 호출 시 ~200ms 추가 지연 | — |

### 결과 (Consequences)

**긍정적**
- S3, DynamoDB, API Gateway, Location Service 등은 서울 리전에서 낮은 지연으로 동작
- 사용자 체감 지연은 Bedrock 호출 구간에만 국한

**부정적**
- Bedrock 호출마다 ~200ms 네트워크 오버헤드
- 대응: 프롬프트 최적화(토큰 최소화) + 캐싱(동일 좌표 반경 50m)으로 완화

---

## ADR-011: AWS SAM을 IaC 도구로 선정

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 배포·운영 전체 |
| **관련 요구사항** | TR-DEV1, TR-DEV3, CON-2 |

### 맥락 (Context)

Lambda + API Gateway + DynamoDB 중심의 서버리스 아키텍처를 코드로 관리해야 한다. 포트폴리오 프로젝트이므로 재현 가능성(reproducibility)이 중요하다. 로컬 테스트 환경도 필요하다.

### 결정 (Decision)

**AWS SAM (Serverless Application Model)을 IaC 및 로컬 테스트 도구로 사용한다.**

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **Terraform** | 멀티 클라우드, 풍부한 커뮤니티, 세밀한 리소스 제어 | 서버리스 특화 아닌 범용 도구, HCL 학습 필요, 로컬 Lambda 테스트 미지원 | 로컬 테스트 부재 |
| **AWS CDK** | TypeScript/Python으로 인프라 정의, 추상화 수준 높음 | 추상화가 오히려 학습에 방해, 디버깅 시 CloudFormation 레벨까지 추적 필요 | PoC에 과도한 추상화 |
| **Serverless Framework** | 서버리스 특화, 플러그인 풍부 | 3rd-party 도구, 유료 기능 존재, AWS 공식 아닌 커뮤니티 지원 | AWS 공식 도구 우선 |
| **AWS SAM (채택)** | 서버리스 특화, `sam local` 로컬 테스트, CloudFormation 호환, AWS 공식 도구 | SAM 특유의 제약, 복잡한 리소스는 직접 CloudFormation 작성 필요 | — |

### 결과 (Consequences)

**긍정적**
- `sam local invoke`로 Lambda 로컬 테스트 가능 (TR-DEV3)
- template.yaml 하나로 전체 인프라 재현 → GitHub에 포함하여 포트폴리오 가치 상승
- CloudFormation 호환으로 AWS 콘솔에서 스택 관리 가능

**부정적**
- SAM 템플릿 문법 학습 필요 (RISK-LIB6)
- 복잡한 리소스(Step Functions, EventBridge 규칙)는 SAM 축약 문법 미지원 → 직접 CloudFormation 작성

---

## ADR-012: Room 기반 오프라인 큐잉 전략

| 항목 | 내용 |
|---|---|
| **상태** | 승인 |
| **일자** | 2026-05-24 |
| **영향 범위** | 클라이언트 네트워크 처리 |
| **관련 요구사항** | TR-CLI6, NFR-A2 |

### 맥락 (Context)

여행 중 네트워크가 불안정하거나 단절되는 상황이 빈번하다. 사용자가 촬영한 사진, 음성 메모 등이 네트워크 단절로 유실되면 안 된다(NFR-A2: 데이터 유실 0%). 오프라인에서도 기본적인 데이터 수집은 계속되어야 한다.

### 결정 (Decision)

**Room 로컬 데이터베이스에 오프라인 요청 큐를 구현하고, 네트워크 복구 시 자동으로 일괄 업로드(동기화)한다.**

```
[오프라인 동작 흐름]
사진 촬영 → Room 큐 저장 (status: PENDING)
         → 네트워크 감지 (ConnectivityManager)
         → 연결 복구 시 큐 순차 처리 (S3 업로드 → API 호출)
         → 성공 시 status: COMPLETED
         → 실패 시 status: RETRY (최대 3회)
```

### 근거 (Rationale)

| 대안 | 장점 | 단점 | 기각 사유 |
|---|---|---|---|
| **SharedPreferences** | 구현 최단순 | 구조화 데이터 부적합, 큐 관리 어려움, 대용량 미지원 | 기능 부족 |
| **파일 시스템 직접 관리** | 미디어 파일은 이미 로컬 저장 | 메타데이터 관리 어려움, 큐 상태 추적 불편, 정렬·검색 불가 | 관리 복잡도 |
| **Room (채택)** | SQLite 기반 구조화, 큐 상태 관리 용이, Kotlin Coroutines/Flow 지원, 앱 스키마 마이그레이션 | Room 라이브러리 학습 필요 | — |

### 결과 (Consequences)

**긍정적**
- 네트워크 단절 시에도 사용자 경험 연속성 유지
- 큐 테이블의 status 컬럼으로 PENDING/UPLOADING/COMPLETED/FAILED 상태 추적
- Kotlin Flow로 큐 변화 실시간 감지 → UI에 동기화 진행률 표시 가능

**부정적**
- Room 스키마 설계 + ConnectivityManager 리스너 구현 추가 공수
- 동기화 순서 보장 로직 (시간순 큐 처리) 필요
- 미디어 파일 자체는 Room이 아닌 로컬 파일시스템에 저장 → 메타데이터와 파일의 일관성 관리 필요
