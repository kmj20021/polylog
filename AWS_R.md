# Polylog — AWS 서비스 요청서 (AWS_R.md)

> 학습 목적 프로젝트로 **앱 배포(리소스 생성)는 개발자가 직접 수행**합니다. 이 문서는 그에 필요한 **서비스 활성화·IAM 권한을 관리자에게 요청**하기 위한 것입니다.

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) v2.0 PoC |
| 작성일 | 2026-05-26 |
| 요청자 | Polylog 개발자 (1인) |
| 수신자 | **AWS 계정 관리자** |
| 근거 문서 | `polylog-plan.md` §4·§6, `ADR.md` (ADR-001~011, 2.0.2) |
| 핵심 제약 | 월 운영비 ~$5 목표(NFR-C1), **무료 티어 우선**, 상시 서버 0대(서버리스) |
| 개정 | 2026-05-26 — CloudFront·Secrets Manager·**Budgets 제외**, 배포는 **개발자가 직접 수행**(서비스+IAM 권한만 요청), 최소권한(FullAccess 금지) |

---

## 1. 문서 목적 & 사용법

Polylog v2.0은 서버리스(Lambda + API Gateway) 기반 PoC이자 **학습 목적 프로젝트**입니다. 앱 배포(`sam deploy`로 Lambda·API·테이블 등 리소스 생성)는 **개발자가 직접 수행**합니다. 따라서 관리자께는 다음 두 가지만 요청합니다.

1. 필요한 **서비스 활성화 / Bedrock 모델 액세스 승인** (§5)
2. 개발자 계정에 **필요한 IAM 권한(액션 단위)을 부여** (§4) — 개발자가 이 권한으로 직접 배포

> 단, Lambda 실행 역할 4종(§4-1)은 `iam:CreateRole`이 민감 권한이라, **계정 발급 시 관리자가 함께 생성**해 주시면 개발자는 `iam:PassRole`로 참조만 합니다.

> 🚀 **기호 안내**: 본 문서에서 **🚀 표시는 "개발자가 직접 배포(`sam deploy`)로 생성·관리하는 부분"** 입니다. 🚀가 없는 항목은 관리자 조치(서비스 활성화·모델 액세스 승인·IAM 권한 부여·실행 역할 사전 생성)입니다.

**관리자 사용법**
1. §2 요약 테이블로 전체 요청 범위를 파악합니다.
2. §3~§5에서 서비스별 상세·선행 조건을 확인합니다.
3. §7 체크리스트로 완료 여부를 표시합니다.

> ⚠️ **가장 중요한 단 하나**: §5-1 **Bedrock 모델 액세스(us-east-1) 승인**. 이것이 없으면 4개 핵심 기능 전부가 동작하지 않습니다.

---

## 2. 요청 요약 (한눈에 보기)

> 관리자 조치는 **(가) 서비스 활성화/모델 액세스** 또는 **(나) 개발자 계정에 IAM 권한 부여** 둘 중 하나입니다. 리소스 생성(배포)은 개발자가 수행합니다.

| 서비스 | 리전 | 용도(기능) | 관리자 조치 | 근거 ADR |
|---|---|---|---|---|
| **Amazon Bedrock (Claude Haiku)** | **us-east-1** | 자연어 추천·분류·대화 (4개 전체) | **모델 액세스 승인** + `InvokeModel` 권한 | ADR-004, ADR-009 |
| Amazon Textract | ap-northeast-2 | 메뉴판/영수증 OCR (서브1·2) | IAM 권한 부여 (활성화 불필요) | ADR-005 |
| Amazon Translate | ap-northeast-2 | 메뉴 번역 (서브1) | IAM 권한 부여 (활성화 불필요) | ADR-005 |
| 🚀 AWS Lambda | ap-northeast-2 | 백엔드 함수 5종 | 생성·관리 IAM 권한 부여 (개발자 배포) | ADR-001 |
| 🚀 Amazon API Gateway | ap-northeast-2 | REST API + 인가 | 생성·관리 IAM 권한 부여 | ADR-001, ADR-007 |
| 🚀 Amazon DynamoDB | ap-northeast-2 | 구조화 데이터(엔티티 8종) | 생성·관리 IAM 권한 부여 | ADR-002 |
| 🚀 Amazon S3 | ap-northeast-2 | 미디어(사진·영수증) 저장 + Presigned URL 조회 | 생성·관리 IAM 권한 부여 | ADR-008 |
| 🚀 Amazon Cognito | ap-northeast-2 | 사용자 인증 | 생성·관리 IAM 권한 부여 | ADR-007 |
| Amazon CloudWatch | ap-northeast-2 | 로그·메트릭 | 실행 역할에 로그 권한 포함 | 기획 §4.2 |
| 🚀 AWS CloudFormation (SAM) | ap-northeast-2 | 스택 배포 | 배포 IAM 권한 부여 | ADR-010 |
| **IAM 실행 역할 4종** | 글로벌 | Lambda 함수별 최소 권한 | **역할 생성(발급 시 포함)** + 개발자에 `PassRole` 부여 | 기획 §6, NFR-S2 |

> **리전 원칙**: 거의 모든 리소스는 **서울(ap-northeast-2)**. **Bedrock만 버지니아(us-east-1)** 로 cross-region 호출(ADR-009).
>
> **비용(Budgets) 제외**: $20 결제 알람 등 비용 통제는 계정 차원(관리자 영역)이므로 본 요청에 포함하지 않습니다.

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
| 관리자 조치 | 실행 역할에 위 액션 IAM 권한 부여(§4). **별도 서비스 활성화 불필요.** |

#### A-3. Amazon Translate
| 항목 | 내용 |
|---|---|
| 리전 | ap-northeast-2 |
| 용도 | 서브1 외국어 메뉴 → 한국어 번역 |
| 사용 API | `translate:TranslateText` |
| 관리자 조치 | 실행 역할에 위 액션 IAM 권한 부여(§4). **별도 서비스 활성화 불필요.** |

### (B) 컴퓨트 · API (서울 ap-northeast-2)

#### B-1. 🚀 AWS Lambda — 함수 5종
| 함수 | 역할 | 사용 AWS 서비스 |
|---|---|---|
| fn-health | 헬스체크 | — |
| fn-recommend | AI 장소 추천 | Bedrock |
| fn-menu | 메뉴판 OCR+번역+추천 | Textract, Translate, Bedrock, S3 |
| fn-receipt | 영수증 OCR+가계부 | Textract, Bedrock, S3 |
| fn-schedule | 대화형 일정 관리 | Bedrock |
| **관리자 조치** | Lambda 생성·관리 IAM 권한 부여 → 개발자가 `sam deploy`로 함수 생성. 무료 티어 100만 요청/월 내 운영. |

#### B-2. 🚀 Amazon API Gateway
| 항목 | 내용 |
|---|---|
| 용도 | REST API 엔드포인트, Cognito Authorizer로 인증 요청만 통과(NFR-S4) |
| 관리자 조치 | API Gateway 생성·관리 IAM 권한 부여 → 개발자가 배포 |

> 참고: 비용·단순성을 더 줄이려면 REST API 대신 **HTTP API**도 가능(Cognito JWT Authorizer 지원, 요금 저렴). 단 ADR-001/007에서 REST로 결정한 사안이라 현 단계 권장값은 REST 유지.

### (C) 데이터 · 미디어 (서울)

#### C-1. 🚀 Amazon DynamoDB
| 항목 | 내용 |
|---|---|
| 용도 | 구조화 데이터(User, Trip, Recommendation, Menu, Expense, Schedule, ChatMessage 등 8종 엔티티) |
| 권장 설정 | **On-Demand** 모드(ADR-002), 무료 티어 25GB 내 |
| 관리자 조치 | DynamoDB 생성·관리 IAM 권한 부여 → 개발자가 배포 |

#### C-2. 🚀 Amazon S3
| 항목 | 내용 |
|---|---|
| 용도 | 미디어 버킷 — 프리픽스 `photos/`(메뉴판), `receipts/`(영수증). 앱 업로드/조회 모두 **Presigned URL**로 처리 |
| 권장 설정 | **SSE-S3 서버측 암호화**(NFR-S1), 퍼블릭 액세스 차단, 무료 티어 5GB 내 |
| 관리자 조치 | S3 생성·관리 IAM 권한 부여 → 개발자가 배포. 암호화·퍼블릭 차단은 `template.yaml`에 포함 |

> **CloudFront 미사용**(리뷰 피드백 반영): 영수증·메뉴판은 개인정보(NFR-S1)라 공개 CDN/정적 호스팅이 부적합하고, PoC 트래픽에 CDN 캐싱 이득이 미미하다. 조회는 **S3 Presigned GET URL**로 충분하다(ADR-008 갱신).

### (D) 인증 (서울)

#### D-1. 🚀 Amazon Cognito
| 항목 | 내용 |
|---|---|
| 용도 | 이메일+비밀번호 사용자 인증, API Gateway Cognito Authorizer 연동 |
| 권장 설정 | **User Pool + App Client**, 무료 티어 50,000 MAU 내 |
| 관리자 조치 | Cognito 생성·관리 IAM 권한 부여 → 개발자가 User Pool/App Client 배포 |

### (E) 운영 (서울)

#### E-1. Amazon CloudWatch
| 항목 | 내용 |
|---|---|
| 용도 | Lambda 로그·메트릭 모니터링 |
| 관리자 조치 | 별도 리소스 불필요 — Lambda 실행 역할에 로그 쓰기 권한 포함(§4) |

> **Budgets($20 알람) 미요청**: 비용 통제는 계정 차원(관리자 영역, NFR-C3). 개발자 계정에 결제 권한을 요청하지 않는다.
>
> **Secrets Manager 미사용**(리뷰 피드백 반영): Google Places API 키 1개는 **Lambda 환경변수**로 주입하면 충분하다(ADR-006 갱신). PoC 규모에서 별도 시크릿 저장소는 오버엔지니어링.

### (F) 배포 도구

#### F-1. 🚀 AWS SAM / CloudFormation
| 항목 | 내용 |
|---|---|
| 용도 | `template.yaml` 하나로 전체 인프라 배포(ADR-010) — **개발자가 직접 수행** |
| 관리자 조치 | 개발자 계정에 CloudFormation 배포 IAM 권한 부여(§4-3). 배포 산출물용 S3 버킷은 개발자가 생성. |
| 배포 주체 | **개발자** — 발급받은 계정의 콘솔 **CloudShell**에서 `sam deploy` 실행(로컬 access key 불필요) |

---

## 4. IAM 권한 요청

### 4-1. Lambda 실행 역할 4종 (최소 권한, 기획 §6)

함수별로 역할을 분리하여 최소 권한 원칙(NFR-S2)을 적용합니다. 이 4종은 `iam:CreateRole`이 민감 권한이므로 **관리자가 계정 발급 시 생성**해 주시고, 개발자는 배포 시 `iam:PassRole`로 참조만 합니다(§4-3). 배포 템플릿(`template.yaml`)은 이 역할들을 **기존 ARN으로 참조**합니다.

| 역할 | 핵심 권한 |
|---|---|
| **LambdaRecommendRole** | `bedrock:InvokeModel`, `dynamodb:PutItem`, `dynamodb:Query` |
| **LambdaMenuRole** | `textract:DetectDocumentText`, `translate:TranslateText`, `bedrock:InvokeModel`, `s3:GetObject` |
| **LambdaReceiptRole** | `textract:AnalyzeExpense`, `bedrock:InvokeModel`, `s3:GetObject`, `dynamodb:PutItem` |
| **LambdaScheduleRole** | `bedrock:InvokeModel`, `dynamodb:Query`, `dynamodb:PutItem` |

> 공통: 모든 역할에 **CloudWatch Logs 쓰기**(`logs:CreateLogGroup/CreateLogStream/PutLogEvents`) 포함. fn-health는 기본 로깅 권한만 필요.
>
> **원칙(FullAccess 금지)**: `*FullAccess` 관리형 정책이나 단독 와일드카드(`*:*`)는 사용하지 않습니다. 위 표처럼 **필요한 액션만** 부여하고, 가능하면 리소스 ARN으로 스코프를 제한합니다.

### 4-2. Cross-region 주의 (ADR-009)
Lambda는 서울에 배포되지만 **Bedrock은 us-east-1을 호출**합니다. 위 역할의 `bedrock:InvokeModel` 권한이 **us-east-1 리소스 대상으로 허용**되어야 합니다(리전 한정 정책 시 us-east-1 포함 필수).

### 4-3. 🚀 배포 권한 — 개발자 계정에 부여 (access key 미발급)

개발자가 직접 배포하므로, **발급받는 개발자 계정(IAM 사용자/SSO 역할)** 에 아래 액션을 부여해 주세요. 로컬에 access key를 두지 않고 **콘솔 CloudShell**에서 `sam deploy`를 실행합니다(유출 위험 차단).

**필요 액션 (FullAccess 금지 — 액션 단위 + 리소스 스코프 제한):**

| 대상 | 허용 액션 | 스코프 제한 |
|---|---|---|
| CloudFormation | `cloudformation:CreateStack/UpdateStack/DescribeStacks/CreateChangeSet/ExecuteChangeSet/DeleteStack` | Polylog 스택 |
| Lambda | `lambda:CreateFunction/UpdateFunctionCode/UpdateFunctionConfiguration/GetFunction/AddPermission` | fn-* 함수 |
| API Gateway | `apigateway:GET/POST/PUT/PATCH/DELETE` | 해당 API |
| DynamoDB | `dynamodb:CreateTable/UpdateTable/DescribeTable` | Polylog 테이블 |
| S3 | `s3:CreateBucket/PutObject/GetObject/PutBucketPolicy/PutEncryptionConfiguration` | **배포 버킷 + 미디어 버킷만** |
| Cognito | `cognito-idp:CreateUserPool/CreateUserPoolClient/DescribeUserPool` | 해당 User Pool |
| Logs | `logs:CreateLogGroup/PutRetentionPolicy/DescribeLogGroups` | — |
| **IAM** | **`iam:PassRole`만** (`CreateRole` 미요청) | **§4-1의 4개 실행 역할 ARN으로만 한정** |

> - 실행 역할 4종(§4-1)은 관리자가 사전 생성 → 개발자는 위 `PassRole`로 참조만. **`iam:CreateRole`은 요청하지 않습니다.**
> - 배포 산출물 저장용 S3 버킷이 별도로 필요합니다(SAM 패키지 업로드). 미디어 버킷(C-2)과 분리 권장.

---

## 5. 특별 선행 조건 (놓치기 쉬운 항목)

### 5-1. ⚠️ Bedrock 모델 액세스 활성화 (최우선)
- **us-east-1** Bedrock 콘솔 → **Model access** → Anthropic **Claude(Haiku)** 모델 액세스를 **명시적으로 승인**해야 합니다.
- 승인 전에는 `InvokeModel`이 `AccessDeniedException`으로 거부되어 **메인·서브1·서브2·서브3 전부 동작 불가**.

### 5-2. 리전 분리 확인
- 서울(ap-northeast-2): Lambda, API Gateway, DynamoDB, S3, Cognito, Textract, Translate, CloudWatch.
- 버지니아(us-east-1): **Bedrock만**.

### 5-3. IAM 실행 역할 4종 — 관리자 사전 생성
- §4-1의 역할 4종은 `iam:CreateRole`이 민감 권한이라 **관리자가 계정 발급 시 함께 생성**해 주세요.
- 개발자에겐 이 역할들에 대한 **`iam:PassRole`만** 부여하면 됩니다(개발자는 `CreateRole` 미요청).
- 각 역할의 `bedrock:InvokeModel`은 **us-east-1** 대상으로 허용되어야 합니다(§4-2).

> 비용(Budgets) 관련 권한은 계정 차원(관리자 영역)이므로 본 요청에 포함하지 않습니다.

---

## 6. 비-AWS 의존성 (참고 — AWS 관리자 대상 아님)

아래는 AWS가 아닌 외부 서비스로, **별도 채널에서 발급**받아야 합니다. 관리자 요청 대상이 아님을 명시합니다.

| 의존성 | 발급처 | 용도 | 근거 |
|---|---|---|---|
| **Google Places API 키** | Google Cloud Console | 메인(Nearby Search)·서브3(Text Search) 장소 검색 | ADR-006 |
| **ExchangeRate-API 키** | exchangerate-api.com | 서브2 원화 환율 환산 | 기획 §4.3 |

> - Google Places는 월 $200 무료 크레딧 내 PoC 비용 $0(ADR-006).
> - 두 키 모두 **Lambda 환경변수**로 주입(Secrets Manager 불필요).
> - 향후 일정 알림(기획 §10) 확장 시 이메일 발송이 필요하면 **SES가 아닌 SNS**를 사용(SES는 계정 소유자 전용·샌드박스 제약).

---

## 7. 관리자 체크리스트

**(가) 서비스 활성화 / 모델 액세스 — 관리자 직접**
- [ ] Bedrock — **us-east-1 Claude(Haiku) 모델 액세스 승인** ⚠️ 최우선
- [ ] (Textract·Translate는 별도 활성화 불필요 — IAM 권한만, 아래)

**(나) 개발자 계정에 IAM 권한 부여 — 개발자가 이 권한으로 직접 배포**
- [ ] Bedrock `InvokeModel` (us-east-1 대상)
- [ ] Textract `DetectDocumentText` / `AnalyzeExpense`
- [ ] Translate `TranslateText`
- [ ] 🚀 Lambda 생성·관리 (fn-* 스코프)
- [ ] 🚀 API Gateway 생성·관리
- [ ] 🚀 DynamoDB 생성·관리 (Polylog 테이블)
- [ ] 🚀 S3 생성·관리 (배포 버킷 + 미디어 버킷) — 암호화·퍼블릭 차단은 template
- [ ] 🚀 Cognito 생성·관리 (User Pool/App Client)
- [ ] 🚀 CloudFormation 배포 액션 (§4-3 표)
- [ ] 🚀 `iam:PassRole` — §4-1의 4개 실행 역할 ARN으로만 한정 (`CreateRole` 미부여)

**(다) IAM 실행 역할 4종 — 관리자 사전 생성(발급 시 포함)**
- [ ] LambdaRecommendRole / LambdaMenuRole / LambdaReceiptRole / LambdaScheduleRole (액션 단위 최소권한, FullAccess 금지)
- [ ] 역할들의 `bedrock:InvokeModel`이 **us-east-1** 대상 허용 확인

> 배포는 개발자가 발급받은 계정의 **콘솔 CloudShell에서 `sam deploy`** 로 직접 수행(access key 미발급). 비용(Budgets)은 계정 차원이라 본 요청에서 제외.
