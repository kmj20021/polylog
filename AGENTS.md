# AGENTS.md — polylog 단일 정책·운영 통합 파일

> **이 파일의 역할(=본인만의 기법).** polylog는 AI 에이전트의 **룰(rules) · 서브에이전트(agents) · 커맨드(commands) · 암묵지(memory) 운영규약**을 흩어두지 않고, 사람과 에이전트가 모두 읽는 **단일 진실원천(Single Source of Truth) 한 파일**로 통합·색인한다. 운영 본체는 `CLAUDE.md`와 `.claude/`에 두되, **"무엇이 어디에 있고 어떻게 협업·배포·테스트하는가"는 이 AGENTS.md 하나만 보면 된다.**
> 동시에 이 파일은 GitHub 클론자를 위한 **컨트리뷰터/설치 가이드(setup · build · deploy · testing)** 역할을 겸한다.

---

## 0. 프로젝트 한 줄 요약
**polylog** — 여행의 잡일(장소 추천·일정·메뉴 번역·영수증 가계부)을 AI가 대신 처리하는 **Flutter 앱 + AWS 서버리스 백엔드** PoC. 상시 서버 0대, 요청당 과금.

핵심 문서 색인(단일 관리: `docs/`)
| 문서 | 용도 |
|------|------|
| `docs/polylog-plan.md` | 핵심 기획안 (단일 진실 원천) |
| `docs/requirements.md` | 요구사항 FR/NFR/TR |
| `docs/WBS/wbs.md` | 작업 분해 + 마일스톤 |
| `docs/ADR.md` | 아키텍처 결정 기록 (ADR-001~018) |
| `docs/session_readme.md` | 인프라 인벤토리(DB·Lambda·S3·API·역할) + 배포 절차 |
| `docs/polylog-iam-guide.md` | 환경 제약(IAM)의 출처 |
| `README.md` | 자원 소유·격리 규칙 + 배포 요약 |
| `AGENTS.md` (이 파일) | 정책·에이전트·커맨드·암묵지 + setup/deploy/testing 통합 |

---

## 1. Setup (개발환경 구성)
- **앱**: Flutter SDK + Android 타깃. 소스 `app/`.
- **백엔드**: Python 3.11 Lambda, AWS SAM(IaC: `backend/template.yaml`), CloudShell.
- **AI/외부 연동**: Bedrock(Claude) · Google Places · 환율 API · Google OAuth.
- **로컬 준비**
  ```bash
  # 백엔드 의존성 (핸들러별 requirements.txt)
  pip install -r backend/src/handlers/requirements.txt
  ```
- **환경 제약(반드시 숙지 — `README.md`/`ADR` 출처)**
  - 모든 AWS 자원 이름은 **`polylog` prefix 필수**, 실행 역할은 공용 **`SafeRole-polylog`** 재사용(`iam:CreateRole` 차단, ADR-012).
  - **Access Key 미발급** → 로컬 `sam deploy`/`sam local` 불가. 모든 배포는 **CloudShell**(ADR-013).
  - Cognito 미제공 → **Google 소셜 OAuth + `fn-authorizer` tokeninfo 검증**(ADR-007).
  - CloudFront 차단 → **S3 Presigned URL**(ADR-008). Bedrock만 **us-east-1 cross-region**(ADR-009), 그 외 `ap-northeast-2`.

## 2. Build (빌드)
빌드(=패키징)와 배포(=클라우드 반영)는 다르다.
```bash
# scripts/deploy.sh 내부에서 수행
sam build      # Lambda 코드 빌드(패키징)
sam package    # S3(polylog-sam-deploy)에 코드 업로드
```

## 3. Deploy (배포 — CloudShell 전용)
> `sam deploy`는 **사용 불가**(`lambda:TagResource`/`GetFunction` 계정 정책 차단). 반드시 아래 스크립트 사용.
```bash
cd /home/cloudshell-user/polylog && bash scripts/deploy.sh
```
스크립트가 하는 일: ① `sam build` → ② `sam package`(S3 업로드) → ③ Lambda 함수 생성(`create-function` + `group=polylog` 자동 태깅 폴링) 또는 갱신(`update-function-code`) → ④ API Gateway `dev` 스테이지 재배포 → ⑤ `/health` 헬스체크 자동 검증.
- 슬래시 커맨드로도 호출: **`/deploy`** (`.claude/commands/deploy.md`).
- 새 Lambda 추가 시 `scripts/deploy.sh` 하단에 `deploy_lambda "polylog-fn-xxx" ...` 한 줄 추가.
- 라우트 셋업 스크립트: `scripts/setup-authorizer.sh` · `setup-menu-route.sh` · `setup-receipt-route.sh` · `setup-schedule-route.sh`.

배포 후 검증
```bash
BASE_URL="https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev"
curl -s "$BASE_URL/health"                 # {"status":"ok","service":"polylog"}
```

## 4. Testing (테스트)
- **단위 테스트(pytest)** — 핸들러별 `test_app.py`:
  ```bash
  cd backend && python -m pytest -q
  ```
  대상: `src/handlers/authorizer/test_app.py`(인증 검증) · `menu/test_app.py` · `planner/test_app.py` · `receipt/test_app.py`.
- **통합 테스트(E2E)**: 배포 후 실환경에서 위 `curl`/실기기로 4기능 시나리오 검증.
- 자동 테스트·배포는 사용자가 직접 트리거(토큰 절약 정책, 메모리 `no-auto-testing`).

---

## 5. Architecture (구조)
```
[Flutter App] ──HTTPS + Google ID 토큰──► [API Gateway (REST)] ──► [Lambda]
                                              │ fn-authorizer(tokeninfo 검증)
   메뉴 번역만 외부 위임 → [Google 렌즈]        ▼
                          [Bedrock(Claude) · Google Places · 환율] ──► [DynamoDB · S3]
```
- **Lambda 7종**: `health · authorizer · recommend · schedule · planner · menu · receipt` (`backend/src/handlers/`).
  - `fn-menu`는 배포돼 있으나 **앱이 호출하지 않는 미사용 엔드포인트** — 메뉴는 **구글 렌즈 위임**이 유일 경로(ADR-018).
  - 영수증만 **Bedrock 비전 OCR** 유지.
- **저장**: DynamoDB(`trip_id` 파티션 + 시각 SK로 자동 시간순 정렬) · S3 Presigned URL(SSE).
- **앱 디렉토리**: feature 단위(`recommend · menu · receipt · schedule`).

---

## 6. AI 에이전트 운영 (Agents · Commands · Rules)
이 프로젝트는 AI 에이전트 워크플로우를 적극 활용한다. 정의는 `.claude/`, 정책 색인은 이 파일.

### 6-1. Rules (룰) — `CLAUDE.md`
- **명료도 게이트**: 모든 요청을 목적/범위/대상/맥락/완료기준 5축 100%로 자가평가 → 85% 미만이면 질문 후 대기.
- **실행 가능성 분석**: 신규 기능마다 기술 실현성·난이도·리소스·대안 보고.
- **AWS 연계 명시·교육 우선 설명**: 코드가 어떤 AWS 서비스의 어떤 기능과 연계되는지 괄호로 밝히고, 중학생 눈높이로 설명.

### 6-2. Sub-agents (서브에이전트) — `.claude/agents/`
| 에이전트 | 모델 | 역할 | 협업 |
|----------|------|------|------|
| **backend-fixer** | opus | 디자인 변경 중 백엔드 로직 회귀 수정 | `@test-agent`의 오류 보고 수신 → 수정 → 재검증 요청 |
| **test-agent** | haiku | 기능 무결성 검증·테스트 자동화 | 실패 시 백엔드 오류→`@backend-fixer`, 프론트 오류→메인 에이전트 라우팅 |
- 두 에이전트는 `SendMessage`로 **상호 협업(Agent Teams)**, `memory: project`로 컨텍스트 격리·축적.

### 6-3. Commands (커맨드) — `.claude/commands/`
- **`/deploy`** → `scripts/deploy.sh` 실행(섹션 3).

### 6-4. Memory (암묵지 운영) — 최신 LLM 기반
- LLM 메모리 디렉토리(`MEMORY.md` 인덱스 + 노트 파일)로 **결정·선호·제약을 위키식으로 축적**, 노트 간 `[[name]]` 링크로 연결.
- 누적된 암묵지 예: `no-auto-testing`(직접 트리거) · `prefers-minimal-over-engineering`(YAGNI) · `menu-uses-google-lens`(ADR-018) · `deploy-tagresource-constraint`(배포 제약) 등.

---

## 7. 기여 가이드 (Contributing)
1. 작업 전 `docs/session_readme.md`로 기존 인프라 인벤토리 확인.
2. 신규 자원(테이블/함수/버킷/경로) 생성 시 즉시 `docs/session_readme.md`에 한 줄 추가.
3. 모든 자원 이름 `polylog` prefix 준수.
4. 배포는 `/deploy`(=`scripts/deploy.sh`), `sam deploy` 금지.
5. 결정 변경은 `docs/ADR.md`에 ADR로 기록.
