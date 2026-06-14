"""fn-schedule — '대화하며 하루 일정을 함께 짜는' AI 플래너 + 일정 저장/조회/삭제.

이 함수는 두 얼굴을 가진다:
  ① 단순 CRUD (담기/조회/삭제) — 추천 카드의 '담기', 타임라인 표시·삭제가 쓴다.
  ② 대화형 플래너 (action="chat") — 추천 기능과의 '차별점'. 이전 대화 + 현재 일정을
     함께 기억하고, 근처 장소를 검색해 '방문 순서(동선)'를 제안하며, 말로 일정을 고친다.

라우팅(HTTP 메서드 + action):
  POST /schedule {action:"chat", ...}     → 대화형 플래너          (_handle_chat)
  POST /schedule {action:"reorder", ...}  → 일정 순서 재정렬       (_handle_reorder)
  POST /schedule {action:"set_day", ...}  → 계획을 다른 날로 이동   (_handle_set_day)
  POST /schedule {action:"create_trip"}   → 새 여행 만들기         (_handle_create_trip)
  POST /schedule {action:"list_trips"}    → 여행 목록             (_handle_list_trips)
  POST /schedule {action:"update_trip"}   → 여행 이름·기간 수정    (_handle_update_trip)
  POST /schedule {action:"delete_trip"}   → 여행 삭제(일정·대화 포함)(_handle_delete_trip)
  POST /schedule {action:"get_profile"}   → 사용자 취향 조회        (_handle_get_profile)
  POST /schedule {action:"save_profile"}  → 사용자 취향 저장        (_handle_save_profile)
  POST /schedule {place_name, ...}        → 한 장소 담기           (_handle_post)
  GET  /schedule?trip_id=...              → 타임라인 조회          (_handle_get)
  DELETE /schedule {trip_id,start_time}   → 한 항목 삭제           (_handle_delete)

── 대화형 플래너(_handle_chat) 흐름 ──────────────────────────────────────────
  입력 : {action:"chat", trip_id, message, lat, lng, language}
  1) polylog-chats 에서 '이전 대화', polylog-schedules 에서 '현재 일정'을 로드.
  2) Bedrock #1(플래너 두뇌): 대화+일정+새 메시지 → {reply, region, searches, edits} 판단.
       - region  : 발화 속 지역/동선 앵커(예: "서울 광화문 북촌"). 없으면 "".
       - searches: '하루 동선'에 필요한 종류별 검색어 리스트(관광 + 식사 + 카페 …).
                   지역이 있으면 각 검색어에 지역명이 녹아 있다(예: "북촌 카페").
       - edits   : 기존 일정 편집(remove/reorder). 현재 일정 '번호(1-based)' 기준.
  3) edits 를 즉시 적용(삭제/순서변경은 사용자가 명령한 것이므로 바로 반영).
  4) searches 가 있으면 Google Places(텍스트검색) 를 검색어마다 호출해 후보를 모으고
     (place_id 중복 제거) → Bedrock #2(큐레이터)로 '관광·식사·카페를 섞어 방문 순서대로'
     4~6곳을 골라 proposed_plan(제안 동선)을 만든다(아직 저장 X).
     ※ region 이 있으면 현재 GPS 에 편향하지 않고 '그 지역'을 찾는다(다른 도시 일정 가능).
  5) 사용자 메시지 + AI 응답을 polylog-chats 에 저장(다음 턴의 기억).
  응답 : {type:"chat", reply, proposed_plan:[...], timeline:[...현재 일정...], edited:bool}

  ※ 제안(proposed_plan)은 '확정 전 미리보기'다. 사용자가 앱에서 '이대로 담기'를 누르면
    각 장소를 POST /schedule(담기, time_label 포함)로 저장한다 → 새 장소는 검토 후 추가,
    기존 일정 편집(빼기/순서)은 명령 즉시 반영 — 의도된 비대칭.

설계 메모:
- Places/Bedrock 부품은 fn-recommend 에도 있지만 '다른 배포 패키지'라 import 불가 →
  필요한 최소분(텍스트검색 + Claude 호출)만 이 파일에 복제한다(의존성 0 유지, 배포 위험 0).
- Bedrock 은 us-east-1(모델 액세스 승인), 그 외 자원은 ap-northeast-2. SafeRole-polylog 가
  DynamoDB(polylog*)·Bedrock 권한 보유(ADR-012) → 추가 IAM 불필요.
- 환경변수 GOOGLE_PLACES_API_KEY 주입 필요(deploy.sh). 키 없으면 검색 없이 대화만 동작.
"""
import json
import logging
import math
import os
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

_log = logging.getLogger()
_log.setLevel(logging.INFO)

_dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-2")
_TABLE_NAME = os.environ.get("SCHEDULES_TABLE", "polylog-schedules")
_CHATS_TABLE = os.environ.get("CHATS_TABLE", "polylog-chats")
_TRIPS_TABLE = os.environ.get("TRIPS_TABLE", "polylog-trips")
_USERS_TABLE = os.environ.get("USERS_TABLE", "polylog-users")

# Bedrock 은 us-east-1(모델 액세스 승인 리전)에서 호출.
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
# 플래너의 두 콜은 성격이 달라 모델을 나눈다(속도·비용 최적화, API GW 29초 천장 회피):
#   ① 의도 판단(검색?/편집?/대화? 단순 분류) → Haiku(빠름, 이미 모델 액세스 승인됨).
#   ② 동선 큐레이션(진짜 '계획' 추론)        → Sonnet(품질↑, Opus보다 빠르고 저렴).
#   ⚠️ Sonnet 은 Bedrock 모델 액세스 승인 필요(미승인 → AccessDenied → 제안 안 나옴).
#   기본값은 Claude Sonnet 4.6 '인퍼런스 프로파일'(us.) — 최신 모델은 on-demand 직접
#   호출이 막혀 프로파일 ID 가 필요하다. 다른 모델로 바꾸려면 PLANNER_MODEL_ID env 만 교체.
_INTENT_MODEL_ID = os.environ.get(
    "INTENT_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
_CURATE_MODEL_ID = os.environ.get(
    "PLANNER_MODEL_ID", "us.anthropic.claude-sonnet-4-6")

_PLACES_TEXT_URL = "https://places.googleapis.com/v1/places:searchText"
# 플래너는 별점·거리·주소만 쓰므로 reviews 같은 비싼 필드는 뺀다(토큰·요금 절약).
_FIELD_MASK = ",".join(
    f"places.{f}"
    for f in ("id", "displayName", "rating", "userRatingCount",
              "location", "formattedAddress")
)

_DEFAULT_TRIP_ID = "demo-trip"   # 로그인/Trip 생성 전 PoC 고정값
_DEFAULT_USER_ID = "demo-user"   # 인가(authorizer) 비강제 상태의 PoC 고정 사용자
_DEFAULT_RADIUS_M = 2000         # 근처 모드일 때 위치 편향 반경(도보권 조금 넓게)
_MAX_SEARCHES = 4                # 의도판단이 뽑은 검색어 중 실제 호출할 상한(지연·요금 관리)
_PER_QUERY_LIMIT = 6            # 검색어 1개당 가져올 후보 수
_MAX_POOL = 16                  # 큐레이터에 넘길 후보 풀 상한(Bedrock 토큰 budget)
_HISTORY_TURNS = 12             # Bedrock 에 넣을 최근 대화 메시지 수(토큰 budget)

_CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
}


def lambda_handler(event, context):
    """API Gateway(프록시 통합) 진입점 — 메서드 + action 으로 분기."""
    method = (event or {}).get("httpMethod", "POST").upper()

    if method == "OPTIONS":
        return _resp(200, {"ok": True})
    if method == "GET":
        return _handle_get(event)
    if method == "DELETE":
        return _handle_delete(event)
    if method == "POST":
        body = _parse_body(event)
        action = (body.get("action") or "").lower()
        if action == "chat":
            return _handle_chat(body)
        if action == "reorder":
            return _handle_reorder(body)
        if action == "set_day":
            return _handle_set_day(body)
        if action == "set_time":
            return _handle_set_time(body)
        # 여행(trip) 관리 — 새 API 경로 대신 같은 POST 라우트에 action 분기(배포 비용 절감).
        if action == "create_trip":
            return _handle_create_trip(body)
        if action == "list_trips":
            return _handle_list_trips(body)
        if action == "update_trip":
            return _handle_update_trip(body)
        if action == "delete_trip":
            return _handle_delete_trip(body)
        # 사용자 취향(계정 관리) — 로그인 사용자별 1행(polylog-users). event 의 인가
        # 컨텍스트에서 user_id 를 얻으므로(없으면 PoC 고정) body 와 함께 event 도 넘긴다.
        if action == "get_profile":
            return _handle_get_profile(body, event)
        if action == "save_profile":
            return _handle_save_profile(body, event)
        return _handle_post(body)
    return _resp(405, {"error": f"지원하지 않는 메서드: {method}"})


# ─────────────────────────── 담기(POST, 단일 저장) ───────────────────────────
def _handle_post(body):
    """장소 하나를 일정에 추가한다(PutItem). proposed_plan '담기'도 이걸 곳마다 호출."""
    place_name = _clean(body.get("place_name") or body.get("name"))
    if not place_name:
        return _resp(400, {"error": "place_name(또는 name)은 필수입니다."})

    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    now = _now_iso()

    item = {
        "trip_id": trip_id,                       # PK
        "start_time": now,                        # SK — 추가 순서 = 타임라인 순서
        "schedule_id": str(uuid.uuid4()),
        "title": _clean(body.get("title")) or place_name,
        "place_name": place_name,
        "place_id": _clean(body.get("place_id")),
        "address": _clean(body.get("address")),
        "day": _clean(body.get("day")),                  # 어느 여행 날짜의 계획인지 'YYYY-MM-DD'(선택)
        "time_label": _clean(body.get("time_label")),   # AI 제안 방문 시각대(예: 14:00)
        "source": "ai_recommended",
        "created_at": now,
        "updated_at": now,
    }

    lat = _num(body.get("latitude", body.get("lat")))
    lng = _num(body.get("longitude", body.get("lng")))
    if lat is not None:
        item["latitude"] = lat
    if lng is not None:
        item["longitude"] = lng
    rating = _num(body.get("rating"))
    if rating is not None:
        item["rating"] = rating

    item = {k: v for k, v in item.items() if v not in ("", None)}

    _table().put_item(Item=item)
    return _resp(200, {"type": "added", "item": _json_safe(item)})


# ─────────────────────────── 순서 재정렬(POST action="reorder") ───────────────────────────
def _handle_reorder(body):
    """타임라인 순서를 통째로 다시 맞춘다(드래그 재정렬).

    왜 '전체 순서'를 받나: DynamoDB 는 정렬키(SK=start_time)를 바꿀 수 없어, 순서를 바꾸려면
    delete 후 새 start_time 으로 put 해야 한다(`_rewrite_order`). 한 칸만 옮겨도 그 뒤 항목들의
    start_time 이 줄줄이 바뀌므로, 클라이언트가 '원하는 최종 순서'(start_time 목록)를 통째로
    보내는 편이 단순하고 안전하다(부분 계산보다 경합·누락에 강함).

    입력 : {action:"reorder", trip_id, order:["<start_time>", ...]}  ← order = 새 순서
    출력 : {type:"reordered", items:[...재배치된 타임라인...]}
    """
    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    order = body.get("order")
    if not isinstance(order, list) or not order:
        return _resp(400, {"error": "order(새 순서의 start_time 목록)는 필수입니다."})

    current = _load_schedule(trip_id)
    by_st = {it.get("start_time"): it for it in current}

    # order 가 가리키는 항목을 그 순서대로 모으되, 중복/존재하지 않는 키는 건너뛴다.
    seen = set()
    ordered = []
    for st in order:
        it = by_st.get(_clean(st))
        if it is not None and it["start_time"] not in seen:
            ordered.append(it)
            seen.add(it["start_time"])
    # order 에 빠진 기존 항목은 원래 순서대로 뒤에 보존(드래그 중 다른 기기가 추가했을 때 등 방어).
    for it in current:
        if it["start_time"] not in seen:
            ordered.append(it)
            seen.add(it["start_time"])

    new_items = _rewrite_order(trip_id, ordered)
    return _resp(200, {
        "type": "reordered",
        "trip_id": trip_id,
        "count": len(new_items),
        "items": [_json_safe(it) for it in new_items],
    })


# ─────────────────────────── 날짜 이동(POST action="set_day") ───────────────────────────
def _handle_set_day(body):
    """계획 한 개를 다른 여행 날짜로 옮긴다 — 항목의 day 속성만 갱신(순서·키 불변).

    메인 '내 여행' 화면이 계획을 날짜별로 조회하므로, 어느 날 계획인지를 항목에 저장한다.
    PK(trip_id)+SK(start_time)로 항목을 특정해 day 만 바꾼다(빈 day 면 미지정으로 되돌림).

    입력 : {action:"set_day", trip_id, start_time, day:"YYYY-MM-DD"}
    출력 : {type:"day_set", trip_id, start_time, day}
    """
    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    start_time = _clean(body.get("start_time"))
    if not start_time:
        return _resp(400, {"error": "start_time(대상 계획의 시각 키)은 필수입니다."})
    day = _clean(body.get("day"))

    key = {"trip_id": trip_id, "start_time": start_time}
    item = _table().get_item(Key=key).get("Item")
    if not item:
        return _resp(404, {"error": "해당 계획을 찾을 수 없습니다."})

    # day 만 바꾼다(SK 불변이라 안전하게 같은 키로 덮어쓰기). 빈 day 면 미지정으로 되돌림.
    item["day"] = day
    item["updated_at"] = _now_iso()
    item = {k: v for k, v in item.items() if v not in ("", None)}
    _table().put_item(Item=item)
    return _resp(200, {"type": "day_set", "trip_id": trip_id,
                       "start_time": start_time, "day": day})


# ─────────────────────────── 시간 지정(POST action="set_time") ───────────────────────────
def _handle_set_time(body):
    """계획 한 개의 방문 시각(time_label)만 바꾼다 — 순서·키(SK=start_time)는 불변.

    AI 플래너는 시각을 임의로 정하지 않으므로(담길 때 '미정'), 사용자가 이 액션으로
    직접 시간을 정하거나 비운다. PK(trip_id)+SK(start_time)로 항목을 특정해 time_label
    만 갱신한다(빈 값이면 '시간 미정'으로 되돌림). day 이동(set_day)과 같은 꼴이라
    안전하게 같은 키로 덮어쓴다.

    입력 : {action:"set_time", trip_id, start_time, time_label:"HH:MM"}  (빈 값=미정)
    출력 : {type:"time_set", trip_id, start_time, time_label}
    """
    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    start_time = _clean(body.get("start_time"))
    if not start_time:
        return _resp(400, {"error": "start_time(대상 계획의 시각 키)은 필수입니다."})
    time_label = _clean(body.get("time_label"))

    key = {"trip_id": trip_id, "start_time": start_time}
    item = _table().get_item(Key=key).get("Item")
    if not item:
        return _resp(404, {"error": "해당 계획을 찾을 수 없습니다."})

    # time_label 만 바꾼다(SK 불변이라 같은 키로 덮어쓰기). 빈 값이면 아래 필터에서
    # 제거되어 '시간 미정'이 된다.
    item["time_label"] = time_label
    item["updated_at"] = _now_iso()
    item = {k: v for k, v in item.items() if v not in ("", None)}
    _table().put_item(Item=item)
    return _resp(200, {"type": "time_set", "trip_id": trip_id,
                       "start_time": start_time, "time_label": time_label})


# ─────────────────────────── 조회(GET) ───────────────────────────
def _handle_get(event):
    """한 여행의 일정 전체를 시간순(오름차순)으로 돌려준다(Query)."""
    params = (event or {}).get("queryStringParameters") or {}
    trip_id = _clean(params.get("trip_id")) or _DEFAULT_TRIP_ID
    items = _load_schedule(trip_id)
    return _resp(200, {
        "type": "timeline",
        "trip_id": trip_id,
        "count": len(items),
        "items": [_json_safe(it) for it in items],
    })


# ─────────────────────────── 삭제(DELETE) ───────────────────────────
def _handle_delete(event):
    """일정에서 한 항목을 뺀다(DeleteItem). PK(trip_id)+SK(start_time) 둘 다 필요."""
    body = _parse_body(event)
    params = (event or {}).get("queryStringParameters") or {}

    trip_id = _clean(body.get("trip_id") or params.get("trip_id")) or _DEFAULT_TRIP_ID
    start_time = _clean(body.get("start_time") or params.get("start_time"))
    if not start_time:
        return _resp(400, {"error": "start_time(삭제할 일정의 시각 키)은 필수입니다."})

    _table().delete_item(Key={"trip_id": trip_id, "start_time": start_time})
    return _resp(200, {"type": "deleted", "trip_id": trip_id, "start_time": start_time})


# ════════════════════════════ 여행(trip) 관리 ════════════════════════════
# 사용자가 여러 여행을 따로 만들어 관리한다(예: "강원도 여행", "부산 여행"). 부모 테이블
# polylog-trips 에 저장하고, 각 여행의 일정/대화는 trip_id 로 묶인다. 로그인 전 PoC 라
# '한 사용자' 가정으로 scan 한다(멀티유저 땐 user_id GSI 가 필요 — 추후).
def _handle_create_trip(body):
    """새 여행을 만든다 — trip_id 를 발급하고 이름·기간을 저장."""
    name = _clean(body.get("name"))
    if not name:
        return _resp(400, {"error": "name(여행 이름)은 필수입니다."})
    now = _now_iso()
    item = {
        "trip_id": str(uuid.uuid4()),
        "name": name,
        "start_date": _clean(body.get("start_date")),  # 표시용 'YYYY-MM-DD'(선택)
        "end_date": _clean(body.get("end_date")),
        "created_at": now,
        "updated_at": now,
    }
    item = {k: v for k, v in item.items() if v not in ("", None)}
    _trips_table().put_item(Item=item)
    return _resp(200, {"type": "trip_created", "trip": _json_safe(item)})


def _handle_list_trips(body):
    """여행 전체를 시작일(없으면 생성일) 순으로 돌려준다."""
    res = _trips_table().scan()
    items = list(res.get("Items", []))
    while "LastEvaluatedKey" in res:        # 대량 대비(PoC 규모엔 거의 불필요)
        res = _trips_table().scan(ExclusiveStartKey=res["LastEvaluatedKey"])
        items.extend(res.get("Items", []))
    items.sort(key=lambda t: t.get("start_date") or t.get("created_at") or "")
    return _resp(200, {
        "type": "trips",
        "count": len(items),
        "items": [_json_safe(it) for it in items],
    })


def _handle_update_trip(body):
    """여행 이름·기간을 수정한다(존재하는 필드만 갱신)."""
    trip_id = _clean(body.get("trip_id"))
    if not trip_id:
        return _resp(400, {"error": "trip_id 는 필수입니다."})
    existing = _trips_table().get_item(Key={"trip_id": trip_id}).get("Item")
    if not existing:
        return _resp(404, {"error": "해당 여행을 찾을 수 없습니다."})
    name = _clean(body.get("name"))
    if name:
        existing["name"] = name
    if "start_date" in body:
        existing["start_date"] = _clean(body.get("start_date"))
    if "end_date" in body:
        existing["end_date"] = _clean(body.get("end_date"))
    existing["updated_at"] = _now_iso()
    existing = {k: v for k, v in existing.items() if v not in ("", None)}
    _trips_table().put_item(Item=existing)
    return _resp(200, {"type": "trip_updated", "trip": _json_safe(existing)})


def _handle_delete_trip(body):
    """여행을 지운다 — 딸린 일정·대화 기억까지 함께 정리(고아 데이터 방지)."""
    trip_id = _clean(body.get("trip_id"))
    if not trip_id:
        return _resp(400, {"error": "trip_id 는 필수입니다."})
    for it in _load_schedule(trip_id):       # 1) 일정 전부
        _table().delete_item(
            Key={"trip_id": trip_id, "start_time": it["start_time"]})
    chats = _chats_table().query(            # 2) 대화 기억 전부
        KeyConditionExpression=Key("trip_id").eq(trip_id))
    for c in chats.get("Items", []):
        _chats_table().delete_item(
            Key={"trip_id": trip_id, "created_at": c["created_at"]})
    _trips_table().delete_item(Key={"trip_id": trip_id})  # 3) 여행 자체
    return _resp(200, {"type": "trip_deleted", "trip_id": trip_id})


# ════════════════════════════ 사용자 취향(계정 관리) ════════════════════════════
# 앱 '계정 관리' 화면이 고른 선호(여행 스타일·분위기·운동·예산·동행 등)를 사용자별로
# polylog-users(PK user_id)에 1행으로 저장한다. AI(추천·플래너)가 나중에 이 취향을
# 배경지식으로 읽어 개인화하는 것이 목적(프롬프트 연결은 후속 작업).
#
# 스키마를 백엔드에 고정하지 않는다 — 프론트가 보낸 `preferences`(맵)를 그대로 저장하므로,
# 카테고리를 추가/변경해도 이 함수는 손댈 필요가 없다(프론트가 스키마의 주인).
#   값: 복수 선택 = 문자열 리스트, 단일 선택 = 문자열. 빈 항목은 떨군다.
def _handle_get_profile(body, event):
    """사용자 취향을 돌려준다(없으면 빈 preferences)."""
    user_id = _resolve_user_id(event, body)
    item = _users_table().get_item(Key={"user_id": user_id}).get("Item") or {}
    prefs = item.get("preferences") or {}
    return _resp(200, {
        "type": "profile",
        "user_id": user_id,
        "preferences": _json_safe(prefs),
    })


def _handle_save_profile(body, event):
    """사용자 취향을 통째로 저장한다(전체 교체 — 프론트가 항상 완전한 맵을 보냄)."""
    user_id = _resolve_user_id(event, body)
    prefs = body.get("preferences")
    if not isinstance(prefs, dict):
        return _resp(400, {"error": "preferences(객체)는 필수입니다."})
    cleaned = _clean_preferences(prefs)
    _users_table().put_item(Item={
        "user_id": user_id,
        "preferences": cleaned,
        "updated_at": _now_iso(),
    })
    return _resp(200, {"type": "profile_saved",
                       "user_id": user_id, "preferences": cleaned})


def _clean_preferences(prefs):
    """프론트가 보낸 선호 맵을 정리한다: 값은 문자열 리스트(복수) 또는 문자열(단일)만,
    공백 정리 후 빈 값은 떨군다(저장 깔끔 + 깨진 입력 방어)."""
    out = {}
    for raw_key, raw_val in prefs.items():
        key = _clean(raw_key)
        if not key:
            continue
        if isinstance(raw_val, list):
            vals = [_clean(v) for v in raw_val if _clean(v)]
            if vals:
                out[key] = vals
        else:
            val = _clean(raw_val)
            if val:
                out[key] = val
    return out


def _resolve_user_id(event, body):
    """누구의 취향인지 식별한다. 우선순위: 인가 컨텍스트(authorizer)가 심은 user_id →
    body 의 user_id → PoC 고정값. (현재 인가 비강제라 대개 고정값으로 동작.)"""
    rc = (event or {}).get("requestContext") or {}
    authz = rc.get("authorizer") or {}
    uid = _clean(authz.get("user_id"))
    if uid:
        return uid
    return _clean(body.get("user_id")) or _DEFAULT_USER_ID


# ════════════════════════════ 대화형 플래너(action="chat") ════════════════════════════
def _handle_chat(body):
    """대화로 일정을 함께 짠다 — 기억(chats) + 현재 일정 + 동선 제안 + 대화 편집."""
    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    message = _clean(body.get("message"))
    if not message:
        return _resp(400, {"error": "message(사용자 발화)는 필수입니다."})

    language = _clean(body.get("language")) or "ko"
    lat = body.get("lat", body.get("latitude"))
    lng = body.get("lng", body.get("longitude"))
    has_gps = _is_number(lat) and _is_number(lng)

    history = _load_history(trip_id)             # 이전 대화(최근 N)
    schedule = _load_schedule(trip_id)           # 현재 일정(raw, Decimal 유지)

    # 1) 플래너 두뇌 — 무엇을 할지(검색 / 편집 / 그냥 대화) 판단.
    brain = _plan_intent(message, history, schedule, language)
    reply = brain.get("reply", "")
    region = _clean(brain.get("region"))         # 발화 속 지역/동선 앵커(없으면 "")
    searches = _normalize_searches(brain)        # 종류별 검색어 리스트(하위호환 흡수)
    edits = brain.get("edits") or []

    # 1-b) 안전망 — 의도판단(분류)이 가끔 흔들려 검색 스위치를 놓친다.
    #      사용자 메시지에 '장소를 원한다'는 기미가 뚜렷한데 searches·edits 가 둘 다 비었고,
    #      ★실제로 검색할 수 있을 때(지역명 또는 GPS 가 있을 때)만★ 기본 검색어를 강제해
    #      큐레이터가 동선을 내도록 한다(빈 제안 방지). 위치 단서가 전혀 없으면 두뇌가 한
    #      되묻기 답변을 그대로 둔다(불필요한 안내가 덧붙는 것을 막음).
    if (not searches and not edits and _wants_places(message)
            and (region or has_gps)):
        searches = ["근처 가볼만한 곳"]

    # 2) 기존 일정 편집(삭제/순서변경)을 즉시 반영.
    schedule, edited = _apply_edits(trip_id, schedule, edits)

    # 3) 새 장소가 필요하면 검색 → 큐레이터가 '관광·식사·카페를 섞어 방문 순서대로' 동선 제안.
    #    - region 이 있으면: 현재 GPS 에 편향하지 않고 '그 지역'을 그대로 찾는다(다른 도시 OK).
    #    - region 이 없고 GPS 만 있으면: 기존처럼 현재 위치 주변(근처 모드).
    proposed_plan = []
    if searches and (region or has_gps):
        bias_lat = None if region else float(lat)
        bias_lng = None if region else float(lng)
        candidates = _search_places(searches, language, bias_lat, bias_lng)
        if candidates:
            curated = _curate_plan(message, region, schedule, candidates, language)
            if curated.get("reply"):
                reply = curated["reply"]          # 큐레이터 답변을 우선 사용
            proposed_plan = _resolve_plan(curated.get("proposed_plan") or [], candidates)
    elif searches and not region and not has_gps:
        reply = (reply + " (어느 지역인지 알려주시면 거기로 일정을 짜드릴게요. "
                 "예: \"서울 광화문 쪽으로\".)").strip()

    if not reply:
        reply = "어떤 일정을 도와드릴까요?"

    # 4) 이번 턴(사용자/AI)을 기억에 저장.
    _save_turn(trip_id, message, reply)

    return _resp(200, {
        "type": "chat",
        "reply": reply,
        "proposed_plan": proposed_plan,
        "timeline": [_json_safe(it) for it in schedule],
        "edited": edited,
    })


# 안전망용 키워드 — '새 장소를 원한다'는 신호. 의도판단이 흔들려도 이게 잡히면
# 좌표가 있을 때 기본 검색을 강제한다(빈 제안 방지). 순수 함수라 테스트가 쉽다.
_WANTS_PLACES_KEYWORDS = (
    "짜줘", "짜 줘", "일정", "추천", "추가", "넣어", "가볼", "가 볼", "갈만", "갈 만",
    "근처", "주변", "어디", "맛집", "카페", "관광", "명소", "구경", "코스", "동선",
    "다른 곳", "또 ", "더 ", "찾아", "알려",
)


def _wants_places(message):
    """사용자 메시지에 '장소를 원하는' 기미가 있으면 True(안전망 발동 조건)."""
    text = (message or "")
    return any(kw in text for kw in _WANTS_PLACES_KEYWORDS)


def _plan_intent(message, history, schedule, language):
    """Bedrock #1 — 대화+일정 맥락에서 {reply, region, searches, edits} 를 판단한다."""
    prompt = (
        "당신은 여행자와 '대화하며 하루 일정을 함께 짜는' 친근한 AI 플래너입니다.\n"
        f"[현재 일정(번호순)]\n{_schedule_text(schedule)}\n\n"
        f"[지금까지 대화]\n{_history_text(history)}\n\n"
        f'[사용자의 새 메시지]\n"{message}"\n\n'
        "다음 JSON 만 출력하세요(설명·마크다운·코드펜스 금지):\n"
        '{"reply":"사용자에게 할 친근한 한국어 답변. 필요하면 되물어도 됨",'
        '"region":"발화에 나온 지역/장소 앵커를 그대로(예: 서울 광화문 북촌). 없으면 빈 문자열",'
        '"searches":["하루 동선에 필요한 \'종류별\' 검색어들. '
        '예: 광화문 경복궁 관광, 광화문 칼국수 맛집, 북촌 카페"],'
        '"edits":[{"op":"remove","index":2},{"op":"reorder","order":[1,3,2]}]}\n'
        "규칙:\n"
        "- 사용자가 계획/일정/추천/구경거리/맛집/짜줘 등 '새 장소'를 원하면 searches 를 채운다.\n"
        "- ⭐ '하루 계획'이면 한 종류만 넣지 말고 필요한 종류를 스스로 분해한다"
        "(관광·구경거리 + 식사 + 카페 등). 각 종류를 searches 의 개별 항목으로 넣어라.\n"
        "- ⭐ 발화에 지역/동선이 있으면(예: 광화문→북촌) region 에 담고, "
        "각 검색어 앞에 그 지역명을 붙여라(예: '북촌 카페'). 그래야 그 지역에서 찾는다.\n"
        "- 되묻기는 최소화한다. 장소를 원하는 기미가 있으면 분위기·시간을 일일이 캐묻지 말고 "
        "합리적으로 가정해 바로 searches 를 채운다. 정말 알 수 없을 때만 reply 로 딱 한 번 "
        "되묻고 searches 는 비운다.\n"
        "- 빼줘/삭제/순서 바꿔/먼저/나중에 등 '기존 일정 편집'은 edits 에 넣는다"
        "(index·order 는 위 현재 일정 번호 1-based).\n"
        "- 해당 없으면 region=\"\", searches=[], edits=[].\n"
        f"- 답변 언어: {language}."
    )
    # 분류 작업이라 무작위성을 낮춰(0.1) '검색 스위치' 누락을 줄인다.
    # (예전 0.5 에선 같은 요청도 ~1/5 확률로 검색을 안 켜 동선 제안이 비었다.)
    parsed = _safe_json(_try_claude(prompt, 600, _INTENT_MODEL_ID, temperature=0.1))
    if not isinstance(parsed, dict):
        return {"reply": "", "region": "", "searches": [], "edits": []}
    return parsed


def _normalize_searches(brain):
    """두뇌가 준 searches(리스트)를 정리한다. 하위호환으로 옛 단일 'search' 키도 흡수.

    - searches 가 리스트면 공백 제거 후 빈 문자열을 거른다.
    - searches 가 비고 옛 'search'(문자열)만 있으면 [그것] 으로 감싼다.
    """
    out = []
    raw = brain.get("searches")
    if isinstance(raw, list):
        for s in raw:
            s = _clean(s)
            if s:
                out.append(s)
    single = _clean(brain.get("search"))
    if not out and single:
        out.append(single)
    return out


def _curate_plan(message, region, schedule, candidates, language):
    """Bedrock #2 — 섞인 후보 풀에서 '관광·식사·카페를 섞어 방문 순서대로' 동선을 짠다."""
    brief = [
        {"place_id": c["place_id"], "name": c["name"], "rating": c.get("rating"),
         "distance_m": c.get("distance_m"), "address": c.get("address", "")}
        for c in candidates
    ]
    prompt = (
        "당신은 여행 동선을 짜는 현지 가이드입니다.\n"
        f'[사용자 요청]\n"{message}"\n\n'
        f"[지역/동선]\n{region or '(현재 위치 주변)'}\n\n"
        f"[현재 일정]\n{_schedule_text(schedule)}\n\n"
        f"[실제 후보(JSON)]\n{json.dumps(brief, ensure_ascii=False)}\n\n"
        "사용자 요청·지역·현재 일정을 고려해, 하루 동선을 '방문 순서대로' 제안하세요. "
        "다음 JSON 만 출력(설명·코드펜스 금지):\n"
        '{"reply":"제안 동선을 설명하는 친근한 한국어 답변",'
        '"proposed_plan":[{"place_id":"후보의 place_id","time_label":"방문 시각대(예: 오전, 점심, 14:00)",'
        '"reason":"한 줄 추천 이유"}]}\n'
        "규칙:\n"
        "- place_id 는 반드시 위 후보의 것만(목록에 없는 장소를 지어내지 말 것).\n"
        "- ⭐ 하루 일정이면 종류를 섞어라(관광·구경거리 + 식사 + 카페). 같은 종류를 3곳 "
        "연속으로 넣지 말 것(사용자가 명시적으로 한 종류만 원하면 예외).\n"
        "- ⭐ 동선이 있으면(예: 광화문→북촌) 그 순서대로 배치하고, 식사는 끼니 시간대(점심·저녁)에 둬라.\n"
        "- 4~6곳 정도로 적당히. 이미 현재 일정에 있는 곳은 제외.\n"
        f"- 답변 언어: {language}."
    )
    parsed = _safe_json(_try_claude(prompt, 1000, _CURATE_MODEL_ID))
    return parsed if isinstance(parsed, dict) else {}


def _resolve_plan(plan, candidates):
    """큐레이터가 고른 place_id 를 후보 상세(좌표·주소·별점)와 합쳐 앱이 담을 형태로."""
    by_id = {c["place_id"]: c for c in candidates}
    out = []
    for p in plan:
        if not isinstance(p, dict):
            continue
        cid = (p.get("place_id") or "").strip()
        c = by_id.get(cid)
        if not c:
            continue
        loc = c.get("location") or {}
        out.append({
            "place_id": cid,
            "place_name": c["name"],
            "time_label": _clean(p.get("time_label")),
            "reason": _clean(p.get("reason")),
            "latitude": loc.get("lat"),
            "longitude": loc.get("lng"),
            "address": c.get("address", ""),
            "rating": c.get("rating"),
        })
    return out


# ─────────────────────────── 기존 일정 편집(remove / reorder) ───────────────────────────
def _apply_edits(trip_id, items, edits):
    """edits 를 현재 일정(raw list)에 순서대로 적용. (새 list, 변경여부) 반환.

    - remove  : 1-based index 항목 삭제(DeleteItem).
    - reorder : order(1-based 순열)대로 재배치 → 새 start_time 을 순차 부여해 전부 재기록.
                (DynamoDB 는 SK 를 못 바꾸므로 delete 후 put. 항목 수가 적어 안전.)
    잘못된 index/order 는 무시한다(앱이 죽지 않도록 방어적으로)."""
    work = list(items)
    changed = False
    for e in edits or []:
        if not isinstance(e, dict):
            continue
        op = (e.get("op") or "").lower()
        if op == "remove":
            idx = e.get("index")
            if isinstance(idx, int) and 1 <= idx <= len(work):
                victim = work.pop(idx - 1)
                _table().delete_item(
                    Key={"trip_id": trip_id, "start_time": victim["start_time"]})
                changed = True
        elif op == "reorder":
            order = e.get("order")
            if (isinstance(order, list) and len(order) == len(work)
                    and sorted(order) == list(range(1, len(work) + 1))):
                new_work = [work[k - 1] for k in order]
                work = _rewrite_order(trip_id, new_work)
                changed = True
    return work, changed


def _rewrite_order(trip_id, ordered):
    """ordered 순서가 타임라인 정렬과 같아지도록 start_time 을 순차 부여(재기록)."""
    base = datetime.now(timezone.utc)
    out = []
    for i, it in enumerate(ordered):
        new_st = (base + timedelta(microseconds=i)).isoformat()
        if it.get("start_time") != new_st:
            _table().delete_item(
                Key={"trip_id": trip_id, "start_time": it["start_time"]})
            it = {**it, "start_time": new_st, "updated_at": _now_iso()}
            _table().put_item(Item=it)
        out.append(it)
    return out


# ─────────────────────────── DynamoDB 로드 ───────────────────────────
def _load_schedule(trip_id):
    """현재 일정을 시간순(오름차순) raw(Decimal 유지) list 로."""
    res = _table().query(
        KeyConditionExpression=Key("trip_id").eq(trip_id),
        ScanIndexForward=True,
    )
    return list(res.get("Items", []))


def _load_history(trip_id, limit=_HISTORY_TURNS):
    """이전 대화를 시간순으로 로드해 최근 limit 개만 반환(토큰 budget)."""
    res = _chats_table().query(
        KeyConditionExpression=Key("trip_id").eq(trip_id),
        ScanIndexForward=True,
    )
    items = list(res.get("Items", []))
    return items[-limit:]


def _save_turn(trip_id, user_msg, assistant_msg):
    """이번 턴의 사용자/AI 메시지를 저장. SK(created_at) 충돌(덮어쓰기)을 막으려고
    AI 메시지에 1μs 를 더해 '항상 사용자 뒤'로 정렬·구분되게 한다."""
    base = datetime.now(timezone.utc)
    _put_chat(trip_id, base.isoformat(), "user", user_msg)
    _put_chat(trip_id, (base + timedelta(microseconds=1)).isoformat(),
              "assistant", assistant_msg)


def _put_chat(trip_id, created_at, role, content):
    _chats_table().put_item(Item={
        "trip_id": trip_id,
        "created_at": created_at,
        "message_id": str(uuid.uuid4()),
        "role": role,
        "content": content,
    })


def _schedule_text(items):
    """현재 일정을 'N. 장소명 (시각대)' 번호 목록 문자열로(프롬프트용)."""
    if not items:
        return "(아직 일정 없음)"
    lines = []
    for i, it in enumerate(items, 1):
        name = it.get("place_name", "")
        tl = it.get("time_label", "")
        lines.append(f"{i}. {name}" + (f" ({tl})" if tl else ""))
    return "\n".join(lines)


def _history_text(items):
    """이전 대화를 '사용자/AI: ...' 줄들로(프롬프트용)."""
    if not items:
        return "(첫 대화)"
    label = {"user": "사용자", "assistant": "AI"}
    return "\n".join(
        f"{label.get(it.get('role'), it.get('role', ''))}: {it.get('content', '')}"
        for it in items
    )


# ─────────────────────────── Google Places (텍스트검색만) ───────────────────────────
def _search_places(queries, language, lat=None, lng=None):
    """검색어 '리스트'를 순회하며 텍스트검색 → place_id 중복 제거한 후보 풀.

    - queries : 종류별 검색어들(예: ["광화문 경복궁 관광", "북촌 카페"]). _MAX_SEARCHES 까지만.
    - lat/lng : 주면 위치 편향(근처 모드). 지역 발화일 땐 호출부가 None 을 줘서 편향 없이
                '그 지역'을 그대로 찾게 한다(다른 도시 일정 가능 — B-1 해결).
    한 검색이 키/네트워크 오류로 실패해도 나머지는 진행한다(부분 성공 허용)."""
    api_key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not api_key:
        return []
    biased = _is_number(lat) and _is_number(lng)
    pool = {}  # place_id → place (입력 순서 보존 = 종류 섞임 유지)
    for kw in queries[:_MAX_SEARCHES]:
        kw = _clean(kw)
        if not kw:
            continue
        payload = {
            "textQuery": kw,
            "languageCode": language,
            "maxResultCount": _PER_QUERY_LIMIT,
        }
        if biased:
            payload["locationBias"] = {
                "circle": {
                    "center": {"latitude": float(lat), "longitude": float(lng)},
                    "radius": _DEFAULT_RADIUS_M,
                }
            }
        try:
            data = _places_post(_PLACES_TEXT_URL, payload, api_key)
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError):
            continue
        for raw in data.get("places", []):
            place = _normalize_place(
                raw,
                float(lat) if biased else None,
                float(lng) if biased else None,
            )
            pid = place.get("place_id")
            if pid and pid not in pool:
                pool[pid] = place
    return list(pool.values())[:_MAX_POOL]


def _places_post(url, payload, api_key):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Goog-Api-Key": api_key,
            "X-Goog-FieldMask": _FIELD_MASK,
        },
    )
    with urllib.request.urlopen(req, timeout=8) as res:
        return json.loads(res.read().decode("utf-8"))


def _normalize_place(raw, origin_lat, origin_lng):
    loc = raw.get("location") or {}
    plat, plng = loc.get("latitude"), loc.get("longitude")
    distance_m = None
    # origin(현재 위치)이 있을 때만 거리 계산. 지역 검색(편향 없음)이면 origin 이 None 이라 건너뜀.
    if (_is_number(origin_lat) and _is_number(origin_lng)
            and _is_number(plat) and _is_number(plng)):
        distance_m = round(_haversine(origin_lat, origin_lng, plat, plng))
    return {
        "place_id": raw.get("id", ""),
        "name": (raw.get("displayName") or {}).get("text", ""),
        "rating": raw.get("rating"),
        "user_ratings": raw.get("userRatingCount", 0),
        "location": {"lat": plat, "lng": plng},
        "address": raw.get("formattedAddress", ""),
        "distance_m": distance_m,
    }


def _haversine(lat1, lng1, lat2, lng2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = (math.sin(dphi / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


# ─────────────────────────── Bedrock ───────────────────────────
def _try_claude(prompt, max_tokens, model_id, temperature=0.5):
    """Bedrock 호출 — 실패해도 앱이 죽지 않도록 빈 문자열로 폴백.

    단, 실패 원인은 CloudWatch 에 남긴다(AccessDenied/Validation 등을 눈으로 확인해야
    모델 ID·액세스 문제를 진단할 수 있다). 예전엔 조용히 삼켜 '살펴볼게요'만 남았었다.

    temperature: 호출 성격에 맞춰 무작위성을 조절. 분류(의도판단)는 낮게(결정적에 가깝게),
                 창작(동선 큐레이션)은 약간 높게 둔다."""
    try:
        return _invoke_claude(prompt, max_tokens, model_id, temperature)
    except Exception as exc:  # noqa: BLE001 — 모델/네트워크 오류는 빈 응답으로 흡수
        _log.warning("Bedrock 호출 실패 (model=%s): %s", model_id, exc)
        return ""


def _invoke_claude(prompt, max_tokens, model_id, temperature=0.5):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
    }
    result = _bedrock.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(payload),
    )
    parsed = json.loads(result["body"].read())
    return "".join(
        block.get("text", "")
        for block in parsed.get("content", [])
        if block.get("type") == "text"
    ).strip()


def _safe_json(text):
    """모델이 잡설/코드펜스를 섞어도 첫 '{'~마지막 '}' 만 잘라 JSON 파싱."""
    if not text:
        return {}
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1 or end < start:
        return {}
    try:
        return json.loads(text[start:end + 1])
    except (ValueError, TypeError):
        return {}


# ─────────────────────────── 공용 헬퍼 ───────────────────────────
def _table():
    return _dynamodb.Table(_TABLE_NAME)


def _chats_table():
    return _dynamodb.Table(_CHATS_TABLE)


def _trips_table():
    return _dynamodb.Table(_TRIPS_TABLE)


def _users_table():
    return _dynamodb.Table(_USERS_TABLE)


def _parse_body(event):
    """API Gateway proxy 의 body(문자열/딕트/None)를 딕트로 정규화."""
    raw = (event or {}).get("body")
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except (ValueError, TypeError):
        return {}


def _now_iso():
    """현재 UTC 시각(마이크로초 포함) ISO 8601 — SK 충돌 방지 + 정렬 키."""
    return datetime.now(timezone.utc).isoformat()


def _clean(value):
    if value is None:
        return ""
    return str(value).strip()


def _num(value):
    if value is None or value == "":
        return None
    try:
        return Decimal(str(value))
    except (ValueError, TypeError, ArithmeticError):
        return None


def _is_number(v):
    return isinstance(v, (int, float, Decimal)) and not isinstance(v, bool)


def _json_safe(obj):
    """DynamoDB Decimal → 일반 숫자로 환원(JSON 직렬화 가능)."""
    if isinstance(obj, list):
        return [_json_safe(v) for v in obj]
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    return obj


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
