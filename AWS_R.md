# Polylog — AWS 서비스 요청서 (AWS_R.md)

> AWS 리소스를 직접 생성하지 않고 **관리자에게 프로비저닝을 요청**하기 위한 문서입니다.

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) v2.0 PoC |
| 작성일 | 2026-05-26 |
| 요청자 | Polylog 개발자 (1인) |
| 수신자 | **AWS 계정 관리자** |
| 근거 문서 | `polylog-plan.md` §4·§6, `ADR.md` (ADR-001~011) |
| 핵심 제약 | 월 운영비 ~$5 목표(NFR-C1), **무료 티어 우선**, 상시 서버 0대(서버리스) |

---

## 1. 문서 목적 & 사용법

Polylog v2.0은 서버리스(Lambda + API Gateway) 기반 PoC입니다. 개발자가 AWS 리소스를 직접 생성할 권한이 없으므로, 아래 서비스의 **활성화 / 리소스 생성 / IAM 역할 생성 / 모델 액세스 승인**을 관리자에게 요청합니다.

**관리자 사용법**
1. §2 요약 테이블로 전체 요청 범위를 파악합니다.
2. §3~§5에서 서비스별 상세·선행 조건을 확인합니다.
3. §7 체크리스트로 완료 여부를 표시합니다.

> ⚠️ **가장 중요한 단 하나**: §5-1 **Bedrock 모델 액세스(us-east-1) 승인**. 이것이 없으면 4개 핵심 기능 전부가 동작하지 않습니다.

---

## 2. 요청 요약 (한눈에 보기)

| 서비스 | 리전 | 용도(기능) | 관리자 조치 유형 | 근거 ADR |
|---|---|---|---|---|
| **Amazon Bedrock (Claude Haiku)** | **us-east-1** | 자연어 추천·분류·대화 (4개 전체) | **모델 액세스 승인** | ADR-004, ADR-009 |
| Amazon Textract | ap-northeast-2 | 메뉴판/영수증 OCR (서브1·2) | 서비스 활성화 | ADR-005 |
| Amazon Translate | ap-northeast-2 | 메뉴 번역 (서브1) | 서비스 활성화 | ADR-005 |
| AWS Lambda | ap-northeast-2 | 백엔드 함수 5종 | 리소스 생성 / 배포 | ADR-001 |
| Amazon API Gateway | ap-northeast-2 | REST API + 인가 | 리소스 생성 | ADR-001, ADR-007 |
| Amazon DynamoDB | ap-northeast-2 | 구조화 데이터(엔티티 8종) | 리소스 생성 | ADR-002 |
| Amazon S3 | ap-northeast-2 | 미디어(사진·영수증) 저장 | 리소스 생성 | ADR-008 |
| Amazon CloudFront | 글로벌 | 사진 조회 CDN | 리소스 생성 | ADR-008 |
| Amazon Cognito | ap-northeast-2 | 사용자 인증 | 리소스 생성 | ADR-007 |
| Amazon CloudWatch | ap-northeast-2 | 로그·메트릭 | 자동(IAM 권한) | 기획 §4.2 |
| AWS Budgets | 글로벌 | $20 결제 알람 | **결제 권한** | NFR-C3 |
| AWS Secrets Manager *(선택)* | ap-northeast-2 | Google API 키 보관 | 리소스 생성 | ADR-006 |
| AWS CloudFormation (SAM) | ap-northeast-2 | 스택 배포 | 배포 권한 | ADR-010 |
| **IAM 역할 4종** | 글로벌 | Lambda 함수별 최소 권한 | **IAM 역할 생성** | 기획 §6, NFR-S2 |

> **리전 원칙**: 거의 모든 리소스는 **서울(ap-northeast-2)**. **Bedrock만 버지니아(us-east-1)** 로 cross-region 호출(ADR-009).

---

## 3. 서비스별 상세 요청

### (A) AI 계층

#### A-1. Amazon Bedrock (Claude Haiku)
| 항목 | 내용 |
|---|---|
| 리전 | **us-east-1** (서울 미가용, ADR-009) |
| 용도 | 4개 기능 전체의 자연어 생성·분류·대화 (메인/서브1/서브2/서브3) |
| 사용 API | `bedrock-runtime:InvokeModel` |
| 권장 설정 | Anthropic Claude **Haiku** 모델(비용 효율, 기획 §9 기준 500회/월 ≈ $1) |
| **관리자 조치** | **us-east-1 Bedrock 콘솔 → "Model access"에서 Anthropic Claude 모델 액세스 승인** (§5-1 참조) |

#### A-2. Amazon Textract
| 항목 | 내용 |
|---|---|
| 리전 | ap-northeast-2 |
| 용도 | 서브1 메뉴판 OCR / 서브2 영수증 OCR |
| 사용 API | `textract:DetectDocumentText` (메뉴판), `textract:AnalyzeExpense` (영수증) |
| 관리자 조치 | 서비스 활성화 + IAM 권한 부여(§4) |

#### A-3. Amazon Translate
| 항목 | 내용 |
|---|---|
| 리전 | ap-northeast-2 |
| 용도 | 서브1 외국어 메뉴 → 한국어 번역 |
| 사용 API | `translate:TranslateText` |
| 관리자 조치 | 서비스 활성화 + IAM 권한 부여(§4) |

### (B) 컴퓨트 · API (서울 ap-northeast-2)

#### B-1. AWS Lambda — 함수 5종
| 함수 | 역할 | 사용 AWS 서비스 |
|---|---|---|
| fn-health | 헬스체크 | — |
| fn-recommend | AI 장소 추천 | Bedrock |
| fn-menu | 메뉴판 OCR+번역+추천 | Textract, Translate, Bedrock, S3 |
| fn-receipt | 영수증 OCR+가계부 | Textract, Bedrock, S3 |
| fn-schedule | 대화형 일정 관리 | Bedrock |
| **관리자 조치** | 함수 생성 권한 또는 SAM 배포 허용(§4 배포 권한). 무료 티어 100만 요청/월 내 운영. |

#### B-2. Amazon API Gateway
| 항목 | 내용 |
|---|---|
| 용도 | REST API 엔드포인트, Cognito Authorizer로 인증 요청만 통과(NFR-S4) |
| 관리자 조치 | REST API 리소스 생성 / SAM 배포 허용 |

### (C) 데이터 · 미디어 (서울)

#### C-1. Amazon DynamoDB
| 항목 | 내용 |
|---|---|
| 용도 | 구조화 데이터(User, Trip, Recommendation, Menu, Expense, Schedule, ChatMessage 등 8종 엔티티) |
| 권장 설정 | **On-Demand** 모드(ADR-002), 무료 티어 25GB 내 |
| 관리자 조치 | 테이블 생성 권한 또는 SAM 배포 허용 |

#### C-2. Amazon S3
| 항목 | 내용 |
|---|---|
| 용도 | 미디어 버킷 — 프리픽스 `photos/`(메뉴판), `receipts/`(영수증) |
| 권장 설정 | **SSE-S3 서버측 암호화**(NFR-S1), 무료 티어 5GB 내 |
| 관리자 조치 | 버킷 생성 + 암호화 정책 |

#### C-3. Amazon CloudFront
| 항목 | 내용 |
|---|---|
| 용도 | 사진 조회용 CDN(앱 조회 지연 최소화) |
| 권장 설정 | S3 오리진 + OAI(Origin Access Identity) |
| 관리자 조치 | 배포(distribution) 생성 |

### (D) 인증 (서울)

#### D-1. Amazon Cognito
| 항목 | 내용 |
|---|---|
| 용도 | 이메일+비밀번호 사용자 인증, API Gateway Cognito Authorizer 연동 |
| 권장 설정 | **User Pool + App Client**, 무료 티어 50,000 MAU 내 |
| 관리자 조치 | User Pool / App Client 생성 (도메인 설정 포함) |

### (E) 운영 · 비용 (서울/글로벌)

#### E-1. Amazon CloudWatch
| 항목 | 내용 |
|---|---|
| 용도 | Lambda 로그·메트릭 모니터링 |
| 관리자 조치 | 별도 리소스 불필요 — Lambda 역할에 로그 쓰기 권한 포함(§4) |

#### E-2. AWS Budgets
| 항목 | 내용 |
|---|---|
| 용도 | **$20 결제 알람**(NFR-C3) — 예산 초과 방지 |
| 관리자 조치 | 결제(Billing) 권한 필요 — Budgets에서 $20 알람 생성 |

#### E-3. AWS Secrets Manager *(선택)*
| 항목 | 내용 |
|---|---|
| 용도 | Google Places API 키 안전 보관(ADR-006: **환경변수 또는 Secrets Manager** 중 택1) |
| 관리자 조치 | 환경변수 방식 채택 시 **불필요**. Secrets Manager 채택 시 시크릿 생성 + Lambda 읽기 권한 |

### (F) 배포 도구

#### F-1. AWS SAM / CloudFormation
| 항목 | 내용 |
|---|---|
| 용도 | `template.yaml` 하나로 전체 인프라 배포(ADR-010) |
| 관리자 조치 | CloudFormation 스택 생성/갱신 권한 + SAM 배포용 S3 버킷 (§4 배포 권한 참조) |

---

## 4. IAM 권한 요청

### 4-1. Lambda 실행 역할 4종 (최소 권한, 기획 §6)

함수별로 역할을 분리하여 최소 권한 원칙(NFR-S2)을 적용합니다.

| 역할 | 핵심 권한 |
|---|---|
| **LambdaRecommendRole** | `bedrock:InvokeModel`, `dynamodb:PutItem`, `dynamodb:Query` |
| **LambdaMenuRole** | `textract:DetectDocumentText`, `translate:TranslateText`, `bedrock:InvokeModel`, `s3:GetObject` |
| **LambdaReceiptRole** | `textract:AnalyzeExpense`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| **LambdaScheduleRole** | `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem` |

> 공통: 모든 역할에 **CloudWatch Logs 쓰기**(`logs:CreateLogGroup/CreateLogStream/PutLogEvents`) 포함. fn-health는 기본 로깅 권한만 필요.

### 4-2. Cross-region 주의 (ADR-009)
Lambda는 서울에 배포되지만 **Bedrock은 us-east-1을 호출**합니다. 위 역할의 `bedrock:InvokeModel` 권한이 **us-east-1 리소스 대상으로 허용**되어야 합니다(리전 한정 정책 시 us-east-1 포함 필수).

### 4-3. 개발자 배포 권한 (둘 중 택1)
- **(옵션 A) 개발자 직접 배포**: SAM 배포에 필요한 권한을 개발자 IAM 사용자/역할에 부여 — CloudFormation, Lambda, API Gateway, DynamoDB, S3, Cognito, **`iam:PassRole`**(위 4역할 전달용), 배포 S3 버킷 접근.
- **(옵션 B) 관리자 대리 배포**: 개발자가 `template.yaml`을 전달하면 관리자가 `sam deploy` 수행.

> 어느 옵션을 선택할지 관리자 회신 요망.

---

## 5. 특별 선행 조건 (놓치기 쉬운 항목)

### 5-1. ⚠️ Bedrock 모델 액세스 활성화 (최우선)
- **us-east-1** Bedrock 콘솔 → **Model access** → Anthropic **Claude(Haiku)** 모델 액세스를 **명시적으로 승인**해야 합니다.
- 승인 전에는 `InvokeModel`이 `AccessDeniedException`으로 거부되어 **메인·서브1·서브2·서브3 전부 동작 불가**.

### 5-2. 리전 분리 확인
- 서울(ap-northeast-2): Lambda, API Gateway, DynamoDB, S3, Cognito, Textract, Translate, CloudWatch.
- 버지니아(us-east-1): **Bedrock만**.

### 5-3. 결제/Budgets 권한
- $20 예산 알람(NFR-C3) 설정에는 Billing 콘솔 접근 권한 필요(보통 관리자/루트 영역).

### 5-4. IAM 역할 생성 권한
- §4-1의 역할 4종 생성은 일반적으로 관리자 전용 권한이므로, 관리자가 생성하거나 개발자에게 한정 위임 필요.

---

## 6. 비-AWS 의존성 (참고 — AWS 관리자 대상 아님)

아래는 AWS가 아닌 외부 서비스로, **별도 채널에서 발급**받아야 합니다. 관리자 요청 대상이 아님을 명시합니다.

| 의존성 | 발급처 | 용도 | 근거 |
|---|---|---|---|
| **Google Places API 키** | Google Cloud Console | 메인(Nearby Search)·서브3(Text Search) 장소 검색 | ADR-006 |
| **ExchangeRate-API 키** | exchangerate-api.com | 서브2 원화 환율 환산 | 기획 §4.3 |

> Google Places는 월 $200 무료 크레딧 내 PoC 비용 $0(ADR-006).

---

## 7. 관리자 체크리스트

**AI 계층**
- [ ] Bedrock — **us-east-1 Claude(Haiku) 모델 액세스 승인** ⚠️ 최우선
- [ ] Textract 활성화 (ap-northeast-2)
- [ ] Translate 활성화 (ap-northeast-2)

**컴퓨트·API·데이터 (서울)**
- [ ] Lambda 함수 5종 생성/배포 허용
- [ ] API Gateway REST API 생성
- [ ] DynamoDB On-Demand 테이블 생성
- [ ] S3 미디어 버킷 + SSE-S3 암호화
- [ ] CloudFront 배포 생성
- [ ] Cognito User Pool + App Client 생성

**운영·비용**
- [ ] CloudWatch 로그 권한(Lambda 역할에 포함)
- [ ] Budgets $20 결제 알람 설정
- [ ] (선택) Secrets Manager — Google 키 보관 방식 채택 시

**IAM**
- [ ] LambdaRecommendRole / LambdaMenuRole / LambdaReceiptRole / LambdaScheduleRole 생성
- [ ] 역할들의 `bedrock:InvokeModel`이 **us-east-1** 대상 허용 확인
- [ ] 배포 방식 결정 — (A) 개발자 직접 배포 권한 부여 / (B) 관리자 대리 배포

**배포**
- [ ] CloudFormation 스택 권한 + SAM 배포용 S3 버킷
