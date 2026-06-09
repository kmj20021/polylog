# ploylog 프론트엔드 아키텍처 (`main.jpg` 구조)

`docs/ref-image/main.jpg`(태스크 매니저 UI)를 기준으로 한 **상단 중심 내비게이션** 구조다.
하단 탭바를 없애고, **메인 = '내 여행'(날짜별 계획 조회)**, **좌측 메뉴 = 다른 여행 전환**,
**우측 로고 원형 = 기능 내비게이션(계획·메뉴·영수증·근처)** 으로 재편했다.

---

## 1. 화면 트리

```
AuthGate (로그인 게이트)
└─ MainShell  ─ lib/features/home/main_shell.dart   ← 단일 셸(상단 내비)
   ├─ [좌] Drawer: 다른 여행          (_OtherTripsDrawer)
   │        └─ "내 여행 관리" → TripsScreen (생성·수정·삭제·로그아웃)
   ├─ [우] 로고 원형 → 펼침 메뉴       (_ExpandingNavMenu)
   │        ├─ 계획   → ScheduleScreen   (편집·AI 플래너)
   │        ├─ 메뉴   → MenuScreen
   │        ├─ 영수증 → ReceiptScreen
   │        └─ 근처   → RecommendScreen
   └─ [본문] MyTripHome ─ lib/features/home/my_trip_home.dart
            (날짜 스트립 + 날짜별 계획 카드, 읽기 전용)
```

## 2. 내비게이션 흐름

| 트리거 | 동작 | 구현 |
|---|---|---|
| 좌측 햄버거 | 드로어 열기 → '다른 여행'(오늘이 기간 밖) 탭하면 현재 여행 전환 | `Scaffold.openDrawer` + `_OtherTripsDrawer` |
| 우측 로고 원형 | 아래로 펼쳐지는 메뉴(슬라이드+페이드) | `_menuOpen` 토글 + `_ExpandingNavMenu` |
| 펼침 메뉴 항목 | 기능 화면을 현재 여행으로 `push`(복귀 시 홈 새로고침) | `_openFeature(screen)` |
| 드로어 "내 여행 관리" | `TripsScreen` push(여행 CRUD/로그아웃) | `onManage` |

- **선택 날짜(`_selectedDay`)는 셸이 소유**한다. 메인 홈의 날짜 칩이 이 값을 표시·변경하고,
  '계획'·'근처'를 열 때 그대로 넘겨 **담는 계획이 보고 있던 날짜에 저장**된다(아래 4·5절).

- **현재 여행(`_current`)**: 모든 기능 화면이 한 여행에 속한 데이터를 다룬다. 앱 시작 시
  '여행 중'(오늘이 기간 안)인 여행을 자동 선택(`Trip.isOngoing`). 없으면 안내 → 드로어로 유도.
- 기능 화면 4종은 **변경 없이 그대로 재사용**(각자 독립 Scaffold). 셸은 `push`만 한다.

## 3. 메인 홈 — 날짜별 계획 '조회' (`MyTripHome`)

읽기 전용. 추가/삭제/순서변경은 '계획' 화면(`ScheduleScreen`)이 담당한다.

- **날짜 스트립**: `Trip.days()`(시작일~종료일, 양끝 포함)로 칩(`01`+요일) 생성. 기본 선택은
  오늘(기간 밖이면 첫날). 기간 미정 여행이면 스트립을 숨기고 전체 계획을 보여준다.
- **계획 카드**: 선택 날짜에 속한 계획만. 흰 라운드 카드 + 시간대 '검은 알약'(`time_label`).
  카드 탭 → 구글 지도(`shared/maps_link.dart`의 `openPlaceInMaps` 재사용).
- **데이터 흐름**:
  ```
  GET /schedule?trip_id=<id>  →  items[]  →  _Plan
  날짜 매칭: _Plan.day('YYYY-MM-DD') == 선택 날짜
            day 없는(기존/미배정) 계획은 '첫날'에 흡수(사라지지 않게)
  ```
  당겨서 새로고침(`RefreshIndicator`).

## 4. 백엔드 계약 — 계획의 `day` 필드

`backend/src/handlers/schedule/app.py` (신규 테이블/라우트 없음 — 기존 항목에 속성만 추가).

| 동작 | 요청 | 비고 |
|---|---|---|
| 담기 | `POST /schedule {place_name, day?, ...}` | `day`('YYYY-MM-DD') 저장(선택) |
| 조회 | `GET /schedule?trip_id=` | 항목에 `day` 포함 반환 |
| 날짜 이동 | `POST /schedule {action:"set_day", trip_id, start_time, day}` | 계획을 다른 날로(빈 `day`=미지정) |

- **담기 시 `day` 주입 경로**: 셸 `_selectedDay` → `ScheduleScreen.day`/`RecommendScreen.day`
  → `SchedulePlanner._addOne` / `RecommendScreen._addToSchedule` 의 POST 바디 `day`.
  즉 메인 홈에서 'Day 2'를 보다가 계획/근처로 담으면 그 장소는 Day 2에 들어간다.

- 순서 재정렬(`reorder`)은 항목을 통째 재기록하지만 `day`는 자동 보존(`{**it, ...}`).
- 단위 테스트: `src/handlers/schedule/test_app.py` (day 저장/조회/set_day, 총 47개 통과).

## 5. 파일 맵

| 파일 | 역할 | 상태 |
|---|---|---|
| `lib/features/home/main_shell.dart` | 셸·상단 내비·드로어·펼침 메뉴 | 재작성 |
| `lib/features/home/my_trip_home.dart` | 메인 홈(날짜별 조회) | 신규 |
| `lib/features/trips/trip.dart` | `Trip` + `days()`·`ymd()`·`defaultDayYmd()` | 수정 |
| `lib/features/schedule/schedule_screen.dart` · `schedule_planner.dart` | 계획 편집·AI 플래너(+`day` 담기) | 수정 |
| `lib/features/recommend/recommend_screen.dart` | 근처(+`day` 담기) | 수정 |
| `lib/features/{menu,receipt}/*` | 메뉴·영수증 | 재사용 |
| `backend/src/handlers/schedule/app.py` | `day` 필드·`set_day` | 수정 |

## 6. 디자인 토큰

색상은 `lib/core/theme/app_colors.dart`의 **4색만** 사용한다(`AppColors`).

| 토큰 | 값 | 용도 |
|---|---|---|
| `base` | `#FFFFFF` | 배경·카드·선택 칩 글자 |
| `blue` | `#1E98D8` | 주요 강조(선택 칩, 로고 테두리, 강조 바, 메뉴 아이콘) |
| `mid` | `#4EC1B6` | 보조 강조/전환 |
| `green` | `#A9E198` | 보조 강조 |

- 로고 원형: `assets/logo/polylog_logo.png`(`pubspec.yaml` 선언됨)을 `CircleAvatar`로.
- 시간 배지의 어두운 알약(`#1A2233`)은 레퍼런스 톤 재현용 국소 색(토큰 외).

## 7. 검증

```bash
cd app     && flutter analyze            # 변경 파일 무이슈
cd backend && python -m pytest src/handlers/schedule/ -q   # 47 passed
```

- 실기기(SM S906N): 로고 탭 → 4메뉴 펼침/이동, 햄버거 → 다른 여행 전환,
  날짜 칩 전환 시 해당 날 계획만 표시.
- 기존 데드코드 `lib/core/storage/sqflite_queue.dart`는 미사용(분석 에러는 본 작업과 무관).
