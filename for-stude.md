# 인프라·서버 엔지니어 지망생을 위한 polylog 학습 가이드

> 이 문서는 "서버를 직접 안 띄우는(서버리스) AWS 백엔드 + 권한이 의도적으로 잠긴 공용 계정"이라는
> 이 프로젝트의 구조를, 인프라/서버 엔지니어 관점에서 **무엇을 / 왜** 공부해야 하는지 쉽게 정리한 것입니다.

---

## 0. 큰 그림 먼저 — 이 백엔드는 어떻게 생겼나

```
[Flutter 앱]
    │  HTTPS 요청 + Authorization: Bearer <Google 토큰>
    ▼
[API Gateway]  ── (요청마다) Lambda Authorizer 로 토큰 검사 ────┐
    │  통과한 요청만 통과시킴(프록시 통합)                        │
    ▼                                                        ▼
[Lambda 함수들]                                       [fn-authorizer]
 health    : 살아있는지 확인(헬스체크)                 Google tokeninfo 로
 recommend : AI 장소 추천                              토큰 검증 → Allow/Deny
 schedule  : 일정 저장·조회 + 대화형 플래너
 planner   : 대화형 AI 플래너
 menu      : 메뉴판 사진 번역
 receipt   : 영수증 사진 분석
    │
    ├─→ DynamoDB  (polylog-schedules / chats / trips)  ← 데이터 저장
    ├─→ Bedrock   (Claude, us-east-1)                  ← AI
    └─→ 외부 API  (Google Places, 환율)

★ 모든 Lambda 는 역할 하나(SafeRole-polylog)를 공유한다.
★ iam:CreateRole 차단 / 이름은 polylog- 접두사 강제 / group=polylog 태그 없으면 접근 거부.
```

**핵심 두 문장:**
1. 서버 컴퓨터를 직접 관리하지 않고, 요청이 올 때만 코드가 실행되는 **서버리스(Serverless)** 구조다.
2. 권한이 **일부러 잠겨 있어서**, "제약 안에서 안전하게 일하는 법"을 연습하기에 좋다.

---

## 1. 🥇 IAM과 권한 격리 — 가장 먼저, 가장 깊게

📂 `docs/polylog-iam-guide.md`

### 무슨 내용인가
- 새 권한 역할을 못 만든다(`iam:CreateRole` 차단) → 모든 함수가 **`SafeRole-polylog` 하나를 공유**.
- 리소스 이름은 반드시 `polylog-` 로 시작해야 한다. 안 그러면 **생성 자체가 거부**.
- `group=polylog` 태그가 없는 자원은 **접근 거부(explicit deny)**.
- Cognito·CloudFront·Route53 등은 **일부러 막아 놨다** ("You Are Not Google" 원칙).

### 왜 중요한가 (쉽게)
실무 클라우드는 "내가 뭐든 할 수 있는" 환경이 절대 아니다.
보안의 1번 규칙은 **최소 권한 원칙** — *필요한 만큼만 권한을 준다*.
사고가 나도 피해가 우리 그룹 안에만 갇히게(**blast radius 한정**) 설계한다.
이 프로젝트는 그 제약을 **실제로 몸으로 겪게** 해 준다. "왜 안 되지?"의 답이 거의 다 IAM이다.

### 공부 키워드
`IAM Role vs User` · `AssumeRole` · `최소 권한(least privilege)` ·
`신원 정책 vs 리소스 정책` · `태그 기반 접근 제어(ABAC)` · `explicit deny`

---

## 2. 🥈 배포 파이프라인과 IaC — 가장 "현장 냄새" 나는 부분

📂 `backend/template.yaml` (인프라를 코드로 선언) · `scripts/deploy.sh` (실제 배포)

### 무슨 내용인가
- `template.yaml` 은 **인프라를 코드로 적어 둔 설계도**(Lambda·API Gateway를 선언).
- 그런데 `lambda:TagResource` 권한이 막혀서 **정식 `sam deploy` 가 안 된다.**
- 그래서 `deploy.sh` 가 `aws lambda create-function` / `update-function-code` 를 **CLI로 직접** 호출한다.
- 신규 함수는 태그가 비동기로 붙으므로, 붙을 때까지 **`until ... sleep 5` 로 기다린다**(deploy.sh 내부).
- API 키는 git에 안 넣고 **셸 환경변수로만 주입**한다.

### 왜 중요한가 (쉽게)
실무에서 "문서대로 하면 끝나는 배포"는 거의 없다.
권한·타이밍·네트워크 같은 제약에 부딪히고, 그걸 **스크립트로 우회·자동화**하는 게 일의 절반이다.
이 스크립트는 그 축소판이다.
또한 **선언형(template.yaml)** 과 **명령형(deploy.sh)** 을 비교해 보면 IaC의 가치가 체감된다.

### 공부 키워드
`IaC(CloudFormation/SAM/Terraform)` · `선언형 vs 명령형` ·
`멱등성(idempotency, 다시 돌려도 안전)` · `비동기 리소스 생성과 폴링` · `set -euo pipefail`

---

## 3. 🥉 API Gateway + Lambda Authorizer — "문지기" 패턴

📂 `backend/src/handlers/authorizer/app.py` · `scripts/setup-authorizer.sh`

### 무슨 내용인가
- **API Gateway** 가 모든 요청의 **입구**다(라우팅·인증·CORS·재배포 담당).
- **Lambda Authorizer** 가 요청마다 끼어들어 `Authorization: Bearer <토큰>` 을 검사한다.
- 검사 결과로 **Allow / Deny 정책(IAM Policy)** 을 돌려주고, 통과한 요청만 실제 함수로 간다.
- 검증은 Google `tokeninfo` 에 위임 → **외부 라이브러리 의존성 0**(영리한 최소 설계).
- `setup-authorizer.sh enable / disable` 로 **인증을 켜고 끄는 운영 스위치**를 구현했다.
- 결과를 300초 캐시(TTL)하고 정책을 `*/*` 범위로 줘서 **재요청 비용을 줄인다.**

### 왜 중요한가 (쉽게)
"누가 들어올 수 있나"를 **각 함수마다가 아니라 입구에서 한 번에** 거르는 게 확장 가능한 설계다.
- **인증(Authentication)** = "너 누구야?"
- **인가(Authorization)** = "너 이거 해도 돼?"

이 둘의 차이와 토큰 검증 흐름은 **모든 백엔드의 공통 토대**다.

### 공부 키워드
`API Gateway` · `JWT / OAuth ID 토큰` · `인증 vs 인가` · `Bearer 토큰` ·
`CORS` · `게이트웨이/리버스 프록시 패턴` · `인증 결과 캐싱(TTL)`

---

## 4. DynamoDB 데이터 모델링 — NoSQL의 사고방식

📂 `backend/src/handlers/schedule/app.py`

### 무슨 내용인가
- **PK=`trip_id`, SK=`start_time`** 조합으로 "한 여행의 일정을 시간순 조회"를 Query 한 번에 처리.
- DynamoDB는 **정렬키(SK)를 못 바꾼다** → 순서 변경 시 **삭제 후 새 키로 다시 저장**(`_rewrite_order`).
- 멀티유저가 아직 없어서 `scan` 을 쓰고, 주석에 **"멀티유저 땐 user_id GSI 필요"** 라고 미래 부채를 적어 둠.

### 왜 중요한가 (쉽게)
관계형 DB(SQL)는 "어떻게 저장할지"부터 짠다.
NoSQL(DynamoDB)은 반대로 **"어떻게 조회할지(액세스 패턴)를 먼저 정하고" 거기 맞춰 키를 설계**한다.
사고방식이 정반대라 처음엔 헷갈리는데, 이 파일이 그 차이를 작은 규모로 잘 보여준다.

### 공부 키워드
`파티션키/정렬키` · `단일 테이블 설계` · `GSI` ·
`Query vs Scan(비용 차이)` · `NoSQL 액세스 패턴 우선 설계`

---

## 5. 관측성(Observability)과 운영 감각

📂 `backend/template.yaml` 곳곳

### 무슨 내용인가
- `Tracing: Active` (AWS X-Ray) → 요청이 **함수→DB→외부API** 거치는 흐름을 추적.
- `Timeout` / `MemorySize` 를 함수 성격별로 다르게:
  - 가벼운 CRUD → 10초 / 128MB
  - 무거운 AI 비전·Bedrock 호출 → 30초 / 256MB
- API Gateway의 **29초 응답 한계**를 의식해 모델을 Haiku/Sonnet으로 분리(schedule/app.py 주석).

### 왜 중요한가 (쉽게)
서비스는 "배포하고 끝"이 아니다.
**돌아가는 걸 지켜보고, 느리거나 터지면 원인을 찾는** 게 더 큰 일이다.
타임아웃·메모리·트레이싱은 그 운영의 도구이고, **비용과 직결**된다.

### 공부 키워드
`분산 추적(X-Ray)` · `구조적 로깅(CloudWatch Logs)` · `콜드 스타트` ·
`타임아웃/메모리 튜닝` · `비용 최적화`

---

## 추천 학습 순서

| 단계 | 무엇을 이해할까 | 어디를 볼까 |
|----|------------------------------|----------------------------------------|
| 1 | 권한이 왜 잠겨 있나 | `docs/polylog-iam-guide.md`, `docs/ADR.md` |
| 2 | 인프라를 코드로 어떻게 선언하나 | `backend/template.yaml` |
| 3 | 제약을 우회해 어떻게 배포하나 | `scripts/deploy.sh` |
| 4 | 입구에서 인증을 어떻게 거르나 | `backend/src/handlers/authorizer/app.py` + `scripts/setup-authorizer.sh` |
| 5 | 데이터를 어떻게 모델링하나 | `backend/src/handlers/schedule/app.py` |

---

## 마지막으로 — 진짜 중요한 한 가지

이 프로젝트의 가치는 화려한 기능이 아니라,
**"제약(권한·비용·복잡도)을 의식적으로 받아들이고 가장 단순한 해법으로 우회한 설계 결정들"** 에 있다.

`docs/ADR.md`(아키텍처 결정 기록)와 IAM 가이드의 *"You Are Not Google"*,
*"Premature optimization is the root of all evil"* 철학을 함께 읽으면,
코드보다 더 중요한 **"왜 이렇게 만들었는가"라는 인프라 엔지니어의 의사결정 능력**이 길러진다.
그게 면접과 실무에서 진짜로 평가받는 역량이다.
