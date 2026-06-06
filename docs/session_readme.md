# 🗂️ Session README — 세션 간 공유 인프라 인벤토리

> **다음 진도를 나가기 전에 한 번씩 읽으세요.** 다른 기능을 만들다 참조할 "이미 만들어 둔 것들"(DB·람다·S3·API·역할)을 한곳에 모은 빠른 참조표입니다.
> 새 자원을 만들면 **여기에 한 줄 추가**해서 다음 세션이 헤매지 않게 합니다. (상세 결정 근거는 `ADR.md`, 단계별 핸드오프는 `session-handoff.md`)

마지막 갱신: 2026-06-06 (일정 드래그 재정렬: schedule action="reorder" 추가 / 간헐적 빈 제안 단건 픽스 / 백로그 B-1·B-2)

---

## 1. 리전 — 두 곳으로 나뉨 (헷갈리면 호출 실패)
| 용도 | 리전 |
|---|---|
| 거의 모든 자원(Lambda·DynamoDB·API GW·S3) | **ap-northeast-2 (서울)** |
| Bedrock | **us-east-1** (모델 액세스 승인 리전). 추천/요약=Claude 3 Haiku. **플래너(fn-schedule)=하이브리드**: 의도판단=Haiku, 동선 큐레이션=**Claude 3.5 Sonnet**(`PLANNER_MODEL_ID` env로 교체, Sonnet 모델 액세스 승인 필요). Opus는 29초 천장·비용 때문에 미사용 |

## 2. DynamoDB — 7종 모두 생성됨 (PAY_PER_REQUEST, 서울)
> 접근 통제는 **이름 prefix `polylog-`** 기반(태그 불필요). 비키 컬럼은 스키마리스.

| 테이블 | PK | SK | 용도 |
|---|---|---|---|
| `polylog-users` | user_id | — | 회원 |
| `polylog-trips` | trip_id | — | 여행(모든 도메인의 trip_id 발급원·부모) |
| `polylog-recommendations` | trip_id | created_at | 추천 누적 이력 |
| `polylog-menus` | trip_id | created_at | 메뉴판 분석 이력 |
| `polylog-receipts` | trip_id | occurred_at | 영수증/지출 (plan의 expenses) |
| `polylog-schedules` | trip_id | start_time | 일정 (ADR-014 단일 테이블) |
| `polylog-chats` | trip_id | created_at | 대화 이력 (fn-schedule 플래너가 기억용으로 사용) |

> 키 설계 사유는 ADR-014/015, 생성 명령 원본은 `docs/archive/mk_DynamoDB_logic.md`.
> PoC 고정 trip_id = **`demo-trip`** (로그인/Trip 생성 전까지).

## 3. Lambda — 모두 공용 역할 `SafeRole-polylog` 사용
| 함수 | 라우트 | 상태 | 비고 |
|---|---|---|---|
| `polylog-fn-health` | GET /health | ✅ 배포 | 배포 파이프라인 헬스체크 |
| `polylog-fn-recommend` | POST /recommend | ✅ 배포 | GPS+Places(New)+Bedrock, Timeout 30s, env `GOOGLE_PLACES_API_KEY` |
| `polylog-fn-schedule` | POST·GET·DELETE /schedule | ✅ 배포(재배포 필요) | ①CRUD: 추가/조회/삭제(`polylog-schedules`) ②**대화형 플래너**: `POST {action:"chat"}` → 이전 대화(`polylog-chats`)+현재 일정 기억, Places 검색, Bedrock 2콜로 동선 제안·대화 편집 ③**순서 재정렬**: `POST {action:"reorder", trip_id, order:[start_time...]}` → 드래그로 바꾼 새 순서대로 `_rewrite_order`(delete+put 재기록), `{type:"reordered", items}` 반환. **Timeout 30s, env `GOOGLE_PLACES_API_KEY` 필요**. chat·reorder 모두 기존 POST 라우트에 action 분기(새 라우트 불필요) |
| `polylog-fn-authorizer` | (Lambda Authorizer) | ⬜ 코드만·미배포 | Phase 4 인증(JWT). 현재 API auth=NONE |

## 4. API Gateway
- 이름 `polylog-api`, REST, 스테이지 **dev**
- **Base URL**: `https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev`
- 경로: `/health`(GET) · `/recommend`(POST) · `/schedule`(POST·GET·DELETE)

## 5. S3
| 버킷 | 용도 |
|---|---|
| `polylog-sam-deploy` | SAM 배포 산출물(코드 zip) |
| `polylog-media` | 메뉴판·영수증 이미지(암호화 + 퍼블릭 차단). 노출은 Presigned URL(CloudFront 차단) |

## 6. IAM — 공용 역할 `SafeRole-polylog`
- 보유 권한: **Bedrock · Textract · Translate · DynamoDB(`polylog*`) · S3(`polylog*`) · CloudWatch Logs**
- 권한 변경은 관리자 영역 → 새 AWS 서비스 필요 시 요청해야 함.

---

## 7. 환경 제약 5가지 (왜 절차가 특이한가)
1. **이름 prefix `polylog-` 강제** — 안 맞으면 자원 생성 자체가 거부.
2. **`iam:CreateRole` 차단** — 함수별 역할 못 만듦 → 공용 `SafeRole-polylog` 공유(ADR-012).
3. **즉시 태그 권한 없음(`lambda:TagResource` 차단)** — 공용 계정. `AutoTagging-Function`이 ~20초 후 비동기로 `group=polylog` 부착(Lambda 한정). DynamoDB/S3는 prefix라 태그 무관.
4. **Access Key 미발급** — 로컬 `sam deploy`/`sam local` 불가 → **CloudShell 전용** 배포.
5. **Cognito·CloudFront 차단** — 소셜 OAuth+`fn-authorizer`, 미디어는 Presigned URL.

## 8. 배포 치트시트 (무엇을 바꿨냐에 따라 절차가 다름)
| 바꾼 것 | 해야 할 일 |
|---|---|
| **기존 함수 코드만 수정** | `bash scripts/deploy.sh` 한 방 (update-function-code + 스테이지 재배포) |
| **새 Lambda 추가** | template.yaml + deploy.sh에 등록 → `bash scripts/deploy.sh` (create-function + AutoTagging 대기) |
| **새 API 경로 추가** | deploy.sh가 라우트는 못 만듦 → `aws apigateway` 수동 연결(예: `scripts/setup-schedule-route.sh`) |
| **새 DynamoDB 테이블** | `aws dynamodb create-table`(이름 `polylog-`로 시작, 태그 불필요) — template.yaml 아님 |
| **새 S3 버킷** | `aws s3 mb s3://polylog-...` |

> 키는 git 금지 — CloudShell 환경변수로만 주입(`GOOGLE_PLACES_API_KEY` 등, `cloudshell-api-key-env-names` 메모리 참조).

---

## 9. 알려진 개선 과제 (백로그 — 즉시 결함 아님, "프롬프트 튜닝 일괄 패스"에서 처리)
> 핵심 기능(추천·일정·로그인) 안정화 후, 작은 eval셋을 깔고 흩어진 프롬프트(4~6개)를 한 번에 손볼 때 함께 처리한다. 배포가 CloudShell 전용이라 잔손질을 분산하면 왕복 비용만 커지므로 묶는다.

| # | 기능 | 증상 | 근본 원인 | 수정 방향 | 분류 |
|---|---|---|---|---|---|
| **B-1** | 추천 + 플래너 | "오사카 맛집 찾아줘"처럼 **다른 지역**을 말해도 현재 GPS 주변만 검색 | 좌표가 있으면 recommend 는 `searchNearby` 의 `locationRestriction`(현재 좌표 **하드 제한**, `recommend/app.py:282`), 플래너는 `searchText` 의 `locationBias`(현재 좌표 편향)로 고정 → 발화 속 지역명 무시(`_resolve_intent`/`_plan_intent` 가 카테고리만 추출) | 발화에서 지역명 감지 시: 좌표 제한/편향을 빼고 `search_text_places("오사카 맛집")` 로 라우팅(또는 지역 지오코딩). **Trip 목적지(3단계 로그인+Trip) 개념과 연결** | 의도판단 프롬프트 + 라우팅 로직 |
| **B-2** | 플래너(여행) | "맛집 찾아줘" → 밥집만 3연속 제안되고 "이대로 전부 담기"가 그대로 저장돼 비현실적 동선(밥 3끼 연속) | ① 큐레이터 프롬프트(`_curate_plan`)에 '하루 동선=종류 섞기' 제약 없음 → 검색된 한 종류만 N개 선택 ② 담기 UI 가 전부-담기(all-or-nothing) | ① 큐레이터에 "하루 일정이면 식사+카페+관광 등 종류·시간대 분산, 같은 종류 연속 금지(사용자가 명시 요청하면 예외)" 규칙 추가 ② `app/lib/features/schedule/schedule_planner.dart` 에 카드별 선택/제외(골라 담기) | ①프롬프트 튜닝 + ②프론트 UX |

> (해결됨, 코드 반영·배포 대기) 별건으로, 플래너 의도판단(`_plan_intent`)이 가끔 `search` 스위치를 안 켜 **동선 제안이 비는 간헐적 현상**(약 1/5)이 있었음 — '정확성 결함'으로 분류해 단건 픽스함: ① `_invoke_claude`/`_try_claude` 에 `temperature` 파라미터화 → 의도판단은 `0.1`(결정적에 가깝게, 스위치 누락↓), 큐레이션은 `0.5` 유지 ② `_handle_chat` 에 키워드 안전망(`_wants_places`): search·edits 가 둘 다 비었는데 메시지에 장소 기미+좌표가 있으면 기본 검색어("근처 가볼만한 곳") 강제. 단위테스트 추가(28 passed). **다음 CloudShell 배포 때 `bash scripts/deploy.sh` 한 방으로 반영(코드만 변경).**
