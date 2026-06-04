# Polylog 세션 핸드오프 — 메인 기능 구현 착수

> **새 세션은 이 문서를 먼저 읽고 바로 이어서 진행하세요.** 이전 세션에서 합의된 작업환경·구현 순서·기술 결정을 모두 담았습니다.
> 근거 문서: `docs/polylog-plan.md`(기획), `docs/ADR.md`(결정), `docs/bootstrap-plan.md`(환경구축). 행동 규칙: 루트 `CLAUDE.md`.

---

## 0. 지금 어디까지 왔나 (현재 상태)

> **[2026-06-04 진행]** 메인 #1 코드 작업 완료(노트북). STEP 1(app.py 재작성·검색로직 분리)·
> STEP 2(test_app.py 21개 통과)·STEP 3(deploy.sh 키 주입 분기)·STEP 4(geolocator 의존성 추가·
> recommend_screen 카드 UI·AndroidManifest 위치권한) 모두 작성+정적분석 통과.
> **남은 것은 🧑 사용자 실행**: STEP 0(Google 키 발급) → STEP 3(CloudShell `export … && deploy.sh` + curl) → STEP 5(폰 E2E).
>
> **[2026-06-04 추가 — 추천 "대화형"으로 확장]** Google Places(New) 실 호출 검증 완료(신주쿠 실데이터).
> 이어서 추천을 대화형으로 확장(범위: 추천까지만, 일정 #2는 별도). 변경된 `/recommend` contract:
>   - 입력: `{lat,lng,query}`(자연어 주력) · `{lat,lng,category}`(칩) · `{location,query}`(폴백).
>   - 응답 `type` 분기: `"clarify"`(카테고리 모호 → `message`+`suggestions[]`) / `"result"`(`ai_summary`+`places[]`).
>   - place 필드 변경: `ai_reason` 제거, `review_good`·`review_bad`·`reviews_used` 추가
>     (FieldMask에 `places.reviews` 추가 → 최신 3개 리뷰 Bedrock 1콜 요약. 광고탐지는 미구현).
>   - 프론트 `recommend_screen.dart` = 채팅 UI(모드선택 장소추천/일정변경[준비중]+말풍선+칩+카드)로 재작성.
>   - pytest 28개 통과 / `flutter analyze` 클린. **배포·E2E는 동일하게 🧑 STEP 3·5.**


- 환경 구축(Phase 0~4) 완료: API Gateway·Lambda(`fn-health`, `fn-recommend`)·DynamoDB 7종·S3 2종·Bedrock 액세스·Flutter 스켈레톤 존재.
- **`fn-recommend`는 "가짜" 상태** — GPS·Google Places를 안 쓰고 텍스트 지역명을 Bedrock에 넘겨 장소를 "지어냄"(`backend/src/handlers/recommend/app.py:43-50`). Flutter `recommend_screen.dart`도 텍스트 입력 + 단일 텍스트 카드.
- **다음 할 일 = 이걸 실제 GPS+Places 기반으로 바꾸는 것** (= 메인 기능 #1).

### 고정 사실 (코드에 박혀 있는 값)
| 항목 | 값 |
|---|---|
| API base URL | `https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev` |
| 리전 | 인프라 `ap-northeast-2` / Bedrock만 `us-east-1` |
| Account ID | `443370697536` |
| 실행 역할 | `arn:aws:iam::443370697536:role/SafeRole-polylog` (모든 Lambda 공용, ADR-012) |
| Bedrock 모델 | `anthropic.claude-3-haiku-20240307-v1:0` |
| 추천 저장 테이블 | `polylog-recommendations` (PK `trip_id`, SK `created_at`) |
| 배포 | **CloudShell에서 `scripts/deploy.sh`** (★ `sam deploy` 불가 — 계정 정책 차단) |

---

## 1. 작업환경 분담 (확정)

**핵심 원칙: git이 유일한 진실 원천(SSOT). 코드는 노트북에서만 쓰고, CloudShell은 받아서 배포·점검만.**

| | 노트북 (저작) | CloudShell (실행기) | 폰 (노트북에서 flutter run) |
|---|---|---|---|
| 프론트 | ✅ 개발·`flutter run`·hot reload | — | ✅ 실기기 UI/GPS |
| 백엔드 | ✅ **코드 저작**(IDE+AI) + pytest + curl 스모크 | ✅ `git pull && deploy.sh` + 키 주입 + 로그/AWS 점검 | ✅ 실기기 E2E |

- 제약 출처: Access Key 미발급(ADR-013) → 로컬 `sam deploy`/`aws` CLI 불가 → **AWS 배포는 CloudShell 전용**. 폰은 노트북 `flutter run`으로만 올림(CloudShell은 APK 못 만듦).
- 둘이 만나는 접점 = **공개된 API Gateway URL**. 폰이 LTE만 있어도 호출됨(Authorizer 아직 NONE).
- CloudShell 편의 별칭: `gp() { git pull && bash scripts/deploy.sh; }` (`~/.bashrc`).
- **CloudShell-only 편집 금지.** 급히 고쳤으면 즉시 `git commit && push`로 노트북에 되돌릴 것.

### Bedrock 테스트
- 노트북에서 **직접 호출 불가**(자격증명 없음). → **배포된 `/recommend`를 curl**로 호출해 결과 검증(공개 API라 어디서든 됨).
- CloudShell은 세션 자격증명 있음 → 배포·로그 OK. 직접 `bedrock-runtime invoke-model`은 사람 유저 권한 여부 불확실(막히면 Lambda 경유로 우회, 굳이 안 뚫어도 됨).

---

## 2. 전체 기능 구현 순서 (확정 — Option A)

추천("주변 검색")은 **재사용 부품**, 일정은 그걸 호출하는 **조립자**. 그래서 추천이 먼저. 일정은 `trip_id`(상태)에 하드 의존하지만, **임시 `poc-trip` id로 두 메인을 먼저 붙이고 로그인은 나중에 하드닝**한다(Option A).

```
1. 위치 기반 장소 추천   (메인 A) ← 지금 시작   ※ 주변검색을 일정이 재사용하도록 공용 부품으로 설계
2. 텍스트 대화 일정 계획 (메인 B) ← 임시 poc-trip 사용. use case 2(일정 변경→재추천) 완성
3. 로그인 + Trip 생성            ← 임시 trip_id를 실제 인증 id로 교체. 추천 저장(M-6)도 이때 회수
─────────── 시간 부족 시 아래는 제외 가능 ───────────
4. 메뉴판 번역  (S3+Textract+Translate+Bedrock)
5. 영수증 분석·기록 (S3+Textract AnalyzeExpense+환율+Bedrock)
```

> GPS 추천의 두 사용처: ① 일정 없이 그냥 주변 검색 ② 일정 변경 시 주변 재추천. ②는 일정 기능(2번)이 추천 부품(1번)을 호출하는 구조 → **추천 먼저가 맞음.**

---

## 3. 지금 작업: 메인 기능 #1 — GPS + Google Places 장소 추천

### 확정된 기술 결정
1. **Places API (New) `places:searchNearby`** (POST + 필드마스크로 토큰 절약). GPS 없을 땐 `places:searchText` fallback.
2. **M-6 추천이력 DynamoDB 저장은 이번 보류** — `trip_id` 부재. 응답에 `recommendation_id`(UUID)만 발급해두고 3번(로그인)에서 저장 연결.
3. **Bedrock은 JSON 반환** — 장소별 `ai_reason` + 전체 `ai_summary`. 카드 UI(plan M-5)에 부합.

### 구현 순서 (🧑 = 사용자 직접 작업)

**🧑 STEP 0 — Google Cloud 사전 준비 (가장 먼저)**
- "Places API (New)" 활성화 → API 키 발급 → 키 제한(API restriction: Places API (New)).
- 키는 로컬 보관, **git 절대 금지**.

**STEP 1 — 백엔드 `fn-recommend` 재작성** (노트북) · `backend/src/handlers/recommend/app.py`
- 입력: `{lat,lng,category,radius?,language?}`, fallback `{location,category}`.
- 처리: ① `os.environ["GOOGLE_PLACES_API_KEY"]` ② category→type 매핑(맛집→`restaurant`/숙소→`lodging`/관광지→`tourist_attraction`/카페→`cafe`) ③ **`urllib`(표준 라이브러리, 의존성 0)로 Places(New) 호출**, FieldMask로 id·displayName·rating·userRatingCount·location·formattedAddress·currentOpeningHours.openNow·priceLevel ④ haversine 거리(m) ⑤ rating 순 **Top 5** ⑥ 기존 `_invoke_claude` 재사용해 **JSON 응답** 요청(`{ai_summary, reasons:{place_id:이유}}`), 방어적 파싱.
- 응답: `{recommendation_id, category, ai_summary, places:[{place_id,name,rating,user_ratings,distance_m,address,open_now,ai_reason}]}`.
- 기존 `_CORS`/`_resp`/OPTIONS 유지.
- **★ 주변검색 로직은 일정(메인 B)이 재사용할 수 있게 함수로 분리**(공용 Place 형태).

**STEP 2 — 순수 로직 pytest** (노트북, AWS 불필요) · `backend/src/handlers/recommend/test_app.py`
- haversine·category 매핑·Places 응답 파싱·Bedrock JSON 방어 파싱 검증. 네트워크는 monkeypatch 모킹.

**STEP 3 — deploy.sh에 키 주입 추가 + 🧑 배포** · `scripts/deploy.sh`
- ★ **현 deploy.sh는 코드만 갱신하고 환경변수를 못 넣음 → 이게 빠지면 폰 요청이 502.** `update-function-configuration --environment "Variables={GOOGLE_PLACES_API_KEY=...}"` 분기 추가(환경변수 있을 때만, 키는 셸에서 읽음).
- 🧑 CloudShell: `export GOOGLE_PLACES_API_KEY=...` → `git pull && bash scripts/deploy.sh` → curl 스모크:
  ```bash
  curl -s -X POST ".../dev/recommend" -H "Content-Type: application/json" \
    -d '{"lat":35.6938,"lng":139.7034,"category":"맛집"}'
  ```

**STEP 4 — 프론트 GPS + 카드 UI** (노트북) · `app/lib/features/recommend/recommend_screen.dart`
- 기존 `app/lib/core/location/geolocator.dart`의 `LocationService.getCurrentPosition()` 재사용 → `{lat,lng,category}` 전송.
- GPS 거부/실패 시 텍스트 입력 fallback(plan M 수용기준).
- `places[]`를 카드 리스트(이름/별점★+리뷰수/거리/`ai_reason`)로, 상단에 `ai_summary`.
- `app/android/app/src/main/AndroidManifest.xml`에 `ACCESS_FINE_LOCATION` 확인/추가.

**🧑 STEP 5 — 실기기 E2E**
- 폰 USB 디버깅 → `flutter devices` 인식 → `cd app && flutter run` → 위치 권한 "허용" → 주변 실제 장소 카드 확인.

### 핵심 파일
| 파일 | 변경 |
|---|---|
| `backend/src/handlers/recommend/app.py` | 전면 재작성 (Places New + haversine + Bedrock JSON, 검색 로직 분리) |
| `backend/src/handlers/recommend/test_app.py` | 신규 pytest |
| `scripts/deploy.sh` | fn-recommend 환경변수 주입 분기 추가 |
| `app/lib/features/recommend/recommend_screen.dart` | 재작성 (GPS + 카드 + fallback) |
| `app/lib/core/location/geolocator.dart` | 그대로 재사용 |
| `app/android/.../AndroidManifest.xml` | 위치 권한 확인 |

### 검증
1. 노트북 `pytest backend/src/handlers/recommend/` 통과.
2. CloudShell curl → 실제 장소·별점·`ai_reason` 200 응답.
3. 폰: GPS 허용 후 카드 표시 / 거부 시 텍스트 입력으로도 추천.

---

## 4. 🧑 사용자 작업 요약 (한눈에)
- **STEP 0**: Google Cloud "Places API (New)" 활성화 + 키 발급/제한 (git 금지).
- **STEP 3**: CloudShell에서 `export GOOGLE_PLACES_API_KEY=...` → `git pull && bash scripts/deploy.sh` → curl 확인.
- **STEP 5**: 폰 USB 연결 → `flutter run` → 위치 권한 허용 → 카드 확인.
- 나머지(STEP 1·2·4 코드 작성/테스트)는 AI가 노트북에서 진행.

## 5. 잊지 말 것 — CLAUDE.md §6 (코드 설명 의무)
- 기능이 **완전히 동작하는 걸 확인한 뒤**, "왜 만들었나 / 무슨 역할인가"를 **중학생 눈높이**로 설명.
- 사용자가 "오류 난다"고 하면, **왜 발생했고 어떻게 고쳤는지**까지 설명.
- 논의 단계에서 다중선택 폼(AskUserQuestion) 대신 **인라인 대화형 질문** 선호.
