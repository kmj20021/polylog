# polylog

## 프로젝트 개요

Polylog는 여행 중 겪는 반복적인 불편함(장소 탐색 피로, 외국어 메뉴 해독, 영수증 관리, 즉흥적인 일정 변경)을 하나의 앱에서 해결하는 **AI 기반 여행 비서 앱**입니다. 스마트폰 GPS 위치와 인공지능을 결합해 여행자에게 맞춤형 장소 추천, 메뉴판 번역, 영수증 자동 기록, 대화형 일정 관리 기능을 제공하며, Android 스마트폰에서 사용할 수 있습니다.

### 핵심 기능

- **AI 장소 추천**: 현재 위치와 선택한 카테고리(맛집, 숙소, 관광지, 카페 등)를 기반으로 주변 장소를 검색하고, AI가 개인화된 추천 이유를 덧붙여 카드 형태로 결과를 보여줍니다.
- **메뉴판 번역**: 외국어 메뉴판을 카메라로 비추면 구글 렌즈를 통해 실시간으로 번역합니다. 라틴 문자와 한·중·일 문자 모두 지원합니다.
- **영수증 자동 가계부**: 영수증을 촬영하면 AI가 금액·항목·날짜를 자동으로 읽어 원화로 환산하고, 식사·교통·숙박 등 지출 카테고리를 자동 분류합니다.
- **AI 대화형 일정 관리**: "내일 근처 카페 추천해줘"처럼 자연어로 입력하면 AI가 주변 장소를 검색해 최적 동선을 제안하고, 일정을 타임라인으로 관리합니다.

### 기술 스택

| 분류 | 기술 |
|---|---|
| 모바일 앱 | Flutter (Dart) — Android 전용 |
| 서버 | AWS Lambda (서버리스) + Amazon API Gateway |
| 데이터베이스 | Amazon DynamoDB |
| 파일 저장 | Amazon S3 |
| AI | Amazon Bedrock (Claude) — 장소 추천·영수증 분석·일정 계획 |
| 장소 검색 | Google Places API |
| 환율 조회 | ExchangeRate-API |
| 로그인 | Google 소셜 로그인 |

### 만든 사람

1인 개발 (AI 에이전트 활용)

---

AI 여행 앱 PoC. 기획·요구사항·아키텍처 결정은 다음 문서를 참조:

- `docs/polylog-plan.md` — 핵심 기획안 (단일 진실 원천)
- `docs/requirements.md` — 요구사항(FR/NFR/TR)
- `docs/wbs.md` — 작업 분해
- `docs/ADR.md` — 아키텍처 결정 기록
- `docs/bootstrap-plan.md` — 0→1 환경 구축 플랜 (Phase 0~4)
- `docs/polylog-iam-guide.md` — 관리자 IAM 발급 가이드(환경 제약의 출처)
- `docs/archive/` — 보존용(드물게 참조): vision, schedule, mk_DynamoDB_logic

---

## 자원 소유·격리 규칙 (중요)

shingu-cs 계정(`443370697536`)은 4명이 **같은 네임스페이스를 공유**한다(`docs/polylog-iam-guide.md` 격리 모델).
본 레포가 만든 모든 AWS 자원의 owner는 **`polylog-1`** 이다.

- 모든 자원 이름은 **`polylog` prefix 필수** (위반 시 생성 거부).
- 자동 부착 태그 `group=polylog`, `username` 은 **수동 변경 불가** — 그대로 둔다.
- 실행 역할은 공용 **`SafeRole-polylog`** 재사용. `iam:CreateRole` 차단(ADR-012).
- **Access Key 미발급** → 로컬 `sam deploy`/`sam local` 불가. **모든 배포는 콘솔 CloudShell**(ADR-013).
- Cognito 미제공 → 소셜 OAuth(**Google 단독**, Android) + `fn-authorizer`(ADR-007).
- CloudFront 차단 → S3 Presigned URL(ADR-008).
- Bedrock은 us-east-1 cross-region 호출(ADR-009). 그 외 자원은 ap-northeast-2.

---

## 배포 (CloudShell 전용)

> **주의**: `sam deploy` 대신 `scripts/deploy.sh`를 사용한다.
> `lambda:TagResource` 차단으로 SAM/CloudFormation이 Lambda 생성 직후 `GetFunction` 폴링에서 실패함.
> AutoTagging-Function이 약 20초 후 `group=polylog` 태그를 비동기 부착하므로, 스크립트에서 대기 후 진행.

```bash
# 사전: polylog-sam-deploy 버킷이 존재해야 함 (Phase 2.2)
cd polylog
bash scripts/deploy.sh
# → 빌드 → S3 업로드 → Lambda 생성/업데이트 → API 재배포 → 헬스체크 자동 검증
# → {"status": "ok", "service": "polylog"}
```

새 Lambda 함수 추가 시 `scripts/deploy.sh` 하단의 함수 목록에 한 줄 추가:
```bash
deploy_lambda "polylog-fn-xxx" "$(get_s3_key FnXxx)" "app.lambda_handler" 10 128
```

## 디렉토리 구조

```
backend/
├── template.yaml                  # SAM IaC (Globals.Function.Role = SafeRole-polylog)
├── samconfig.toml                 # stack=polylog-backend, bucket=polylog-sam-deploy
└── src/handlers/
    ├── health/app.py              # fn-health (200 OK)
    ├── authorizer/app.py          # fn-authorizer 골격 (Phase 4에서 Google JWKS 검증 구현)
    └── requirements.txt
app/                               # Flutter (Phase 4에서 생성)
```
