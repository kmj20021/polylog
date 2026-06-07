# 🗂️ Session README — 세션 간 공유 인프라 인벤토리

> **다음 진도를 나가기 전에 한 번씩 읽으세요.** 다른 기능을 만들다 참조할 "이미 만들어 둔 것들"(DB·람다·S3·API·역할)을 한곳에 모은 빠른 참조표입니다.
> 새 자원을 만들면 **여기에 한 줄 추가**해서 다음 세션이 헤매지 않게 합니다. (상세 결정 근거는 `ADR.md`, 단계별 핸드오프는 `session-handoff.md`)

마지막 갱신: 2026-06-07 (⭐ **다음 작업 = 영수증(서브2) `polylog-fn-receipt` CloudShell 배포** — ① `export EXCHANGE_RATE_API_KEY=... && bash scripts/deploy.sh`(코드 신규생성+키 주입) ② `bash scripts/setup-receipt-route.sh`(POST /receipt 라우트 1회) ③ curl 검증. 그 다음 프론트 `receipt_screen.dart`. // ✅ **영수증(서브2) 백엔드 `polylog-fn-receipt`(POST /receipt) 코드 완료** — 사진→Textract DetectDocumentText→Bedrock Haiku 한 콜(가게명·날짜·통화ISO4217·합계·품목[name_ko,amount,category])→외부 환율API(exchangerate-api.com v6 pair, urllib)로 원화 환산→`polylog-receipts`(PK trip_id, SK occurred_at) 저장. 메뉴 파이프라인 부품 재사용(의존성 0). 금액=문자열, total_krw만 정수, 통화미인식·환율실패 시 total_krw=null+note. OCR=DetectDocumentText(AnalyzeExpense ❌ — 권한 미확인+B-3 교훈). app.py·template(FnReceipt+ReceiptUrl)·deploy.sh(배포라인+5-4 환율키블록)·setup-receipt-route.sh·단위테스트 **19 passed**. 미배포(다음 세션). // 직전: 영수증 계획 확정(§10). // ✅ **메뉴판 번역(서브1) 백엔드 `polylog-fn-menu`(POST /menu) 완료** — 사진(base64)→Textract OCR→Bedrock Haiku(번역+설명+추천)→`polylog-menus` 저장. 코드·template·deploy.sh·`setup-menu-route.sh`·단위테스트(11 passed) + **CloudShell 배포·curl 검증 완료(HTTP 200, type:result)**. SafeRole 권한만으로 동작(env 불필요). 프론트 메뉴 화면은 다음 세션. **🐛 B-3 해결·배포완료**: 번역이 전 항목 미동작 → 원인은 Amazon Translate의 auto감지가 Comprehend 권한을 요구하는데 SafeRole에 없어 전부 실패 → **Translate 제거하고 Bedrock(`_analyze_menu`)이 번역+설명+추천을 한 콜로** 처리하도록 수정. **재배포·검증 완료**("Berberechos"→"꼬막" 번역·추천 정상). // 직전: 대화형 AI 플래너를 fn-schedule 에서 **`polylog-fn-planner`(POST /planner)** 로 분리 — 무거운 Bedrock+Places 작업을 가벼운 CRUD 와 격리. **사용자가 콘솔로 함수 생성·라우트 연결·curl 검증까지 완료(정상 응답 확인)**. 앱 '계획' 탭 chat 호출이 /schedule→/planner 로 변경. fn-schedule 의 _handle_chat 은 폴백으로 당분간 유지(검증 끝났으니 다음 정리 때 제거 가능). // 이전: 여러 '여행(trip)' 생성·관리(/schedule create/list/update/delete_trip → `polylog-trips`), 앱 메인=MainShell(하단탭 근처·계획·메뉴·영수증·내여행), 오늘이 기간 안인 여행 자동선택(Trip.isOngoing)→기능탭이 그 trip_id 로 동작, 메뉴·영수증은 tripId 배선만(본기능 WIP), 일정·추천 장소명 탭→구글지도 url_launcher)

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
| `polylog-trips` | trip_id | — | 여행(모든 도메인의 trip_id 발급원·부모). **사용 중**: 컬럼 `{trip_id, name, start_date, end_date, created_at}`. fn-schedule 의 trip 액션이 CRUD. PoC=한 사용자 가정 scan(멀티유저 땐 user_id GSI 필요) |
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
| `polylog-fn-schedule` | POST·GET·DELETE /schedule | ✅ 배포(재배포 필요) | ①CRUD: 추가/조회/삭제(`polylog-schedules`) ②**대화형 플래너(지역인식·멀티카테고리)**: `POST {action:"chat"}` → 이전 대화(`polylog-chats`)+현재 일정 기억. 두뇌(Haiku)가 `{region, searches[], edits}` 판단 → region이 있으면 GPS 편향 없이 그 지역을, 없으면 현재 위치 주변을 검색. searches(관광·식사·카페 등 종류별, ≤4개)를 멀티 텍스트검색해 후보 풀(중복제거)→ 큐레이터(Sonnet)가 종류 섞어 동선 제안 ③**순서 재정렬**: `POST {action:"reorder", trip_id, order:[start_time...]}` → 드래그로 바꾼 새 순서대로 `_rewrite_order`(delete+put 재기록), `{type:"reordered", items}` 반환. ④**여행(trip) 관리**: `POST {action:"create_trip"|"list_trips"|"update_trip"|"delete_trip"}` → `polylog-trips` CRUD(이름·기간). delete_trip 은 딸린 일정·대화까지 cascade 삭제. list_trips 는 scan(PoC 단일유저). **Timeout 30s, env `GOOGLE_PLACES_API_KEY` 필요**. chat·reorder·trip 모두 기존 POST 라우트에 action 분기(새 라우트 불필요) |
| `polylog-fn-planner` | POST /planner | ✅ 배포·검증 완료(curl 응답 확인) | **대화형 AI 플래너(fn-schedule 에서 분리)**. `POST {trip_id, message, lat, lng}` → 이전 대화(`polylog-chats`)+현재 일정(`polylog-schedules`) 기억. 두뇌(Haiku)가 `{region, searches[], edits}` 판단 → 멀티 텍스트검색(Places) 후보풀 → 큐레이터(Sonnet)가 종류 섞어 동선 제안. 편집(remove/reorder)은 즉시 반영. 진입점이 POST→chat 단순화(action 무시). **Timeout 30s, env `GOOGLE_PLACES_API_KEY` 필요**. `polylog-schedules`(읽기+편집)·`polylog-chats`(읽기+쓰기)만 — trips 안 건드림. code: `backend/src/handlers/planner/app.py` |
| `polylog-fn-menu` | POST /menu | ✅ 배포·검증 완료(curl 200, 번역수정 반영) | **메뉴판 번역(서브1)**. `POST {trip_id, image_base64(data URI 허용), language?, dietary_restrictions?}` → ①원본을 `polylog-media`(`menus/{trip_id}/{uuid}.jpg`, SSE)에 보관 ②**Textract** `detect_document_text`(Bytes, 동기 ≤5MB, 서울)로 LINE 추출 ③**Bedrock Haiku**(us-east-1) **한 콜로 번역+한줄설명+식이제한 추천 동시 처리**(`_analyze_menu`) ④`polylog-menus`(PK trip_id, SK created_at)에 이력 저장. 응답 `{type:"result", menu_id, photo_s3_key, items[{item_id,original_name,translated_name,price,description}], recommended[]}`. **환경변수 불필요**(SafeRole 권한). Timeout 30s·Mem 256MB. code: `backend/src/handlers/menu/app.py`. 라우트는 `scripts/setup-menu-route.sh`(1회). ⚠️ 번역은 Amazon **Translate 미사용** — auto감지가 Comprehend 권한을 요구하는데 SafeRole에 없어 전부 실패(B-3) → Bedrock로 대체. ⚠️ 프론트(메뉴 화면·image_picker)는 **미구현**(다음 세션) |
| `polylog-fn-receipt` | POST /receipt | ⬜ 코드작성완료·미배포 | **영수증 분석(서브2)**. `POST {trip_id, image_base64(data URI 허용), home_currency?(기본 KRW)}` → ①원본을 `polylog-media`(`receipts/{trip_id}/{uuid}.jpg`, SSE) 보관 ②**Textract** `detect_document_text`(메뉴와 동일 동기 OCR) ③**Bedrock Haiku** 한 콜로 가게명·날짜·통화(ISO4217)·합계·품목[{name_ko,amount,category}] 구조화 ④외부 **환율 API**(exchangerate-api.com v6 pair, urllib GET)로 합계를 원화 환산 ⑤`polylog-receipts`(PK trip_id, SK occurred_at) 저장. 응답 `{type:"result", receipt_id, photo_s3_key, merchant, occurred_at, currency, total, total_krw, items[], note}`. 금액=문자열 저장(소수→DynamoDB float 거부 회피), `total_krw`만 반올림 정수. 통화 미인식·환율 실패 시 결과는 주되 `total_krw=null`+`note`. **OCR=DetectDocumentText**(AnalyzeExpense ❌ — SafeRole 권한 미확인+B-3 교훈). Timeout 30s·Mem 256MB, env `EXCHANGE_RATE_API_KEY`(없으면 환산만 비활성). 단위테스트 19 passed. code: `backend/src/handlers/receipt/app.py`, 라우트 `scripts/setup-receipt-route.sh`(1회). ⚠️ 배포·curl·프론트(`receipt_screen.dart`)는 다음 세션 |
| `polylog-fn-authorizer` | (Lambda Authorizer) | ⬜ 코드만·미배포 | Phase 4 인증(JWT). 현재 API auth=NONE |

## 4. API Gateway
- 이름 `polylog-api`, REST, 스테이지 **dev**
- **Base URL**: `https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev`
- 경로: `/health`(GET) · `/recommend`(POST) · `/schedule`(POST·GET·DELETE) · `/planner`(POST) · `/menu`(POST) · `/receipt`(POST, ⬜라우트 미생성 — `setup-receipt-route.sh`)

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
| **B-1** | ~~플래너~~ → **해결(코드, 배포대기)** / 추천은 잔존 | (플래너) "오사카 맛집"처럼 다른 지역을 말해도 현재 GPS 주변만 검색 | 플래너 `_search_places` 가 현재 좌표 `locationBias` 고정 | **해결**: `_plan_intent` 가 `region` 추출 → region 있으면 `_search_places` 에 좌표 미전달(편향 제거)해 그 지역을 그대로 검색. ⚠️ **추천(recommend)** 의 `searchNearby` `locationRestriction`(`recommend/app.py:282`)은 아직 그대로 — 추천도 같은 처리 필요하면 별건 | 의도판단 프롬프트 + 라우팅 |
| **B-2** | 플래너 — **①해결(코드, 배포대기) / ②잔존** | "맛집 찾아줘" → 밥집 3연속, "전부 담기"가 비현실 동선 저장 | ① 큐레이터에 종류섞기 제약 없음 ② 담기 UI 가 all-or-nothing | **①해결**: 두뇌가 종류별 `searches`(관광·식사·카페)로 분해→멀티검색 후보풀, 큐레이터에 "종류 섞기·같은 종류 3연속 금지" 규칙 추가. ② 카드별 골라담기 UI 는 **아직**(`schedule_planner.dart` `_ProposalBlock`) | ①완료 ②프론트 UX 잔존 |
| **B-3** | 메뉴판(fn-menu) → **✅ 해결·배포완료** | **전 항목** `translated_name`이 원문과 동일(번역이 통째로 안 됨) | `_translate_lines`의 `SourceLanguageCode='auto'`(언어 자동감지)가 내부적으로 **Amazon Comprehend(DetectDominantLanguage)** 를 호출 → SafeRole에 Comprehend 권한 없어 AccessDenied 전부 실패 → 원문 폴백 | **해결·배포완료**: Amazon Translate 제거, **Bedrock(`_analyze_menu`)이 번역+설명+추천을 한 콜로** 처리. 새 IAM 불필요·음식 맥락 번역. 단위테스트 11 passed. 재배포·검증 완료("Berberechos"→"꼬막"). ⭐**교훈: SafeRole 권한을 가정하지 말 것 — fn-receipt도 같은 이유로 AnalyzeExpense 대신 DetectDocumentText 채택** | 권한/아키텍처 |

> (해결됨, 코드 반영·배포 대기) 별건으로, 플래너 의도판단(`_plan_intent`)이 가끔 `search` 스위치를 안 켜 **동선 제안이 비는 간헐적 현상**(약 1/5)이 있었음 — '정확성 결함'으로 분류해 단건 픽스함: ① `_invoke_claude`/`_try_claude` 에 `temperature` 파라미터화 → 의도판단은 `0.1`(결정적에 가깝게, 스위치 누락↓), 큐레이션은 `0.5` 유지 ② `_handle_chat` 에 키워드 안전망(`_wants_places`): search·edits 가 둘 다 비었는데 메시지에 장소 기미+좌표가 있으면 기본 검색어("근처 가볼만한 곳") 강제. 단위테스트 추가(28 passed). **다음 CloudShell 배포 때 `bash scripts/deploy.sh` 한 방으로 반영(코드만 변경).**

---

## 10. ✅ 영수증(서브2) `polylog-fn-receipt` (POST /receipt) — 백엔드 코드 완료(미배포)
> 메뉴판(서브1)의 **사진→Textract OCR→Bedrock→S3/DynamoDB** 파이프라인을 재사용해, 영수증 한 장에서 **품목(한국어)·금액·통화·원화 환산·지출 카테고리**를 뽑아 `polylog-receipts`(PK trip_id, SK occurred_at)에 지출 이력으로 쌓는다. **아래 작업항목 1~5 모두 코드 작성·로컬 pytest(19 passed) 완료** — 남은 건 CloudShell 배포·라우트·curl·프론트(다음 세션). 아래는 확정된 설계(= 구현됨).

### 한 일 (선행 토대 — 이미 있음)
- `polylog-receipts` 테이블(생성됨), `polylog-media` 버킷(메뉴·영수증 공용), SafeRole 권한(Textract·S3·Bedrock·DynamoDB), 환율 키 `EXCHANGE_RATE_API_KEY`(CloudShell env).
- 재사용 부품: `menu/app.py`의 `_decode_image`/`_store_image`/`_ocr_lines`/`_invoke_claude`/`_parse_json_object`/`_resp`/`_CORS`, `recommend/app.py:329 _places_post`의 **urllib HTTP 패턴**(환율 GET에 재사용).

### 앞으로 할 일 (작업 항목)
1. `backend/src/handlers/receipt/app.py` — menu 핸들러 복제 후: `_receipts_table`, `_fetch_rate(frm,to)`(urllib GET), `_analyze_receipt(lines, home_currency)`(Bedrock 한 콜→merchant·occurred_at·currency(ISO4217)·total·items[{name_ko,amount,category}]), `_to_krw(amount_str, rate)`, `_save_receipt`.
2. `backend/template.yaml` — `FnReceipt` 리소스 + `ReceiptUrl` 출력(`FnMenu` 본떠).
3. `scripts/deploy.sh` — `deploy_lambda "polylog-fn-receipt" ... 30 256` 한 줄 + **`EXCHANGE_RATE_API_KEY` env 주입 블록**(5-1 Places 블록 복제, 없으면 환산만 비활성).
4. `scripts/setup-receipt-route.sh`(신규·1회) — `setup-menu-route.sh` 복제, `FUNC=polylog-fn-receipt`·`PATH_PART=receipt`·`wire_method POST`.
5. `backend/src/handlers/receipt/test_app.py` — menu 테스트 패턴(AWS 경계 monkeypatch). 환산·카테고리·실패폴백 케이스.

### 확정된 설계 결정
- **OCR = `DetectDocumentText` + Bedrock 파싱** (영수증 전용 `AnalyzeExpense` ❌). 이유: SafeRole에 `textract:AnalyzeExpense` 권한 확인 불가 + **B-3 교훈(권한 가정 금지)** → 검증된 OCR 재사용으로 **새 IAM 요청 0**.
  - ⭐ **AnalyzeExpense 권한 확인 시도 결과(2026-06-07, 보류 확정)**: 바깥(CloudShell)에서는 SafeRole 권한을 확인할 길이 없음. ① 콘솔유저로 `analyze-expense` 직접 호출 → `InvalidS3ObjectException`(액션은 통과·S3객체만 못 찾음)이라 **콘솔유저에겐 권한 있음**이 확인됐으나, CloudShell은 SafeRole이 아닌 **콘솔유저 신원**으로 돌고 동기호출의 S3 읽기도 호출자 신원이라 **Lambda가 쓰는 SafeRole 검증은 안 됨**. ② `iam:SimulatePrincipalPolicy`·정책 직접읽기도 IAM 잠금(§7)으로 `AccessDenied`. → **유일한 확인법 = Lambda 안(SafeRole)에서 실제 호출(진단코드 배포 필요)**. 확인 비용 > 이득(어차피 번역·카테고리·환산 때문에 Bedrock 또 호출 → AnalyzeExpense는 비용만 얹힘)이라 **보류**. 추후 실제 영수증에서 합계·날짜 추출이 부정확하면 그때 "진단코드로 SafeRole 확인 → 정확하면 업그레이드"를 한 묶음으로.
- **출력 = 풀버전**: 품목별 금액 + 통화 자동인식 + 원화 환산 + 카테고리(식비/교통/쇼핑/숙박/관광/기타). Bedrock 한 콜로 처리.
- **금액 저장 = 문자열**(예 `"12.50"`): 영수증 금액은 소수라 DynamoDB의 float 거부를 피하려 문자열로 저장, 환산은 인메모리 float, `total_krw`만 반올림 정수(원).
- ⚠️ **환율 API 제공자 미확정**: `exchangerate-api.com` v6 pair 엔드포인트(`/v6/{KEY}/pair/{FROM}/KRW` → `conversion_rate`)를 **가정**. URL을 단일 상수로 두어 제공자 다르면 한 줄만 수정. 조회 실패·통화 미인식 시 결과는 반환하되 `total_krw=null`+`note`.
- **범위(Done)**: 백엔드 + 라우트 스크립트 + 로컬 pytest까지. 배포·curl·프론트(Flutter `receipt_screen.dart`)는 사용자/다음 세션.
