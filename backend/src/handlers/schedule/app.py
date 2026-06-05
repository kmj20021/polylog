"""fn-schedule — '대화하며 하루 일정을 함께 짜는' AI 플래너 + 일정 저장/조회/삭제.

이 함수는 두 얼굴을 가진다:
  ① 단순 CRUD (담기/조회/삭제) — 추천 카드의 '담기', 타임라인 표시·삭제가 쓴다.
  ② 대화형 플래너 (action="chat") — 추천 기능과의 '차별점'. 이전 대화 + 현재 일정을
     함께 기억하고, 근처 장소를 검색해 '방문 순서(동선)'를 제안하며, 말로 일정을 고친다.

라우팅(HTTP 메서드 + action):
  POST /schedule {action:"chat", ...}  → 대화형 플래너 (_handle_chat)
  POST /schedule {place_name, ...}     → 한 장소 담기            (_handle_post)
  GET  /schedule?trip_id=...           → 타임라인 조회           (_handle_get)
  DELETE /schedule {trip_id,start_time}→ 한 항목 삭제            (_handle_delete)

── 대화형 플래너(_handle_chat) 흐름 ──────────────────────────────────────────
  입력 : {action:"chat", trip_id, message, lat, lng, language}
  1) polylog-chats 에서 '이전 대화', polylog-schedules 에서 '현재 일정'을 로드.
  2) Bedrock #1(플래너 두뇌): 대화+일정+새 메시지 → {reply, search, edits} 판단.
       - search : 새 장소 후보가 필요하면 검색 키워드, 아니면 "".
       - edits  : 기존 일정 편집(remove/reorder). 현재 일정 '번호(1-based)' 기준.
  3) edits 를 즉시 적용(삭제/순서변경은 사용자가 명령한 것이므로 바로 반영).
  4) search 가 있으면 Google Places(텍스트검색) 호출 → Bedrock #2(큐레이터)로
     '방문 순서대로' 2~4곳을 골라 proposed_plan(제안 동선)을 만든다(아직 저장 X).
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
_DEFAULT_RADIUS_M = 2000         # 동선 후보 검색 반경(도보권 조금 넓게)
_MAX_CANDIDATES = 8              # Places 후보 중 큐레이터에 넘길 상한
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
        if (body.get("action") or "").lower() == "chat":
            return _handle_chat(body)
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

    history = _load_history(trip_id)             # 이전 대화(최근 N)
    schedule = _load_schedule(trip_id)           # 현재 일정(raw, Decimal 유지)

    # 1) 플래너 두뇌 — 무엇을 할지(검색 / 편집 / 그냥 대화) 판단.
    brain = _plan_intent(message, history, schedule, language)
    reply = brain.get("reply", "")
    search = (brain.get("search") or "").strip()
    edits = brain.get("edits") or []

    # 2) 기존 일정 편집(삭제/순서변경)을 즉시 반영.
    schedule, edited = _apply_edits(trip_id, schedule, edits)

    # 3) 새 장소가 필요하면 검색 → 큐레이터가 '방문 순서대로' 동선 제안.
    proposed_plan = []
    if search and _is_number(lat) and _is_number(lng):
        candidates = _search_places(search, float(lat), float(lng), language)
        if candidates:
            curated = _curate_plan(message, schedule, candidates, language)
            if curated.get("reply"):
                reply = curated["reply"]          # 큐레이터 답변을 우선 사용
            proposed_plan = _resolve_plan(curated.get("proposed_plan") or [], candidates)
    elif search and not (_is_number(lat) and _is_number(lng)):
        reply = (reply + " (위치를 못 잡아 후보 검색을 못 했어요. "
                 "메시지에 지역명을 함께 적어 주세요.)").strip()

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


def _plan_intent(message, history, schedule, language):
    """Bedrock #1 — 대화+일정 맥락에서 {reply, search, edits} 를 판단한다."""
    prompt = (
        "당신은 여행자와 '대화하며 하루 일정을 함께 짜는' 친근한 AI 플래너입니다.\n"
        f"[현재 일정(번호순)]\n{_schedule_text(schedule)}\n\n"
        f"[지금까지 대화]\n{_history_text(history)}\n\n"
        f'[사용자의 새 메시지]\n"{message}"\n\n'
        "다음 JSON 만 출력하세요(설명·마크다운·코드펜스 금지):\n"
        '{"reply":"사용자에게 할 친근한 한국어 답변. 필요하면 되물어도 됨",'
        '"search":"새 장소 후보가 필요하면 검색 키워드(예: 조용한 카페, 근처 관광지). 아니면 빈 문자열",'
        '"edits":[{"op":"remove","index":2},{"op":"reorder","order":[1,3,2]}]}\n'
        "규칙:\n"
        "- 사용자가 추천/추가/짜줘/넣어줘/다른 곳 등 '새 장소'를 원하면 search 를 채운다.\n"
        "- ⭐ 되묻기는 최소화한다. 장소를 원하는 기미가 조금이라도 있으면 분위기·시간을 "
        "일일이 캐묻지 말고 합리적으로 가정해 바로 search 를 채운다(예: '일정 짜줘'→search='근처 가볼만한 곳'). "
        "정말 무엇을 원하는지 전혀 알 수 없을 때만 reply 로 딱 한 번 되묻고 search 는 비운다.\n"
        "- 빼줘/삭제/순서 바꿔/먼저/나중에 등 '기존 일정 편집'은 edits 에 넣는다"
        "(index·order 는 위 현재 일정 번호 1-based).\n"
        "- 해당 없으면 search=\"\" 이고 edits=[].\n"
        f"- 답변 언어: {language}."
    )
    parsed = _safe_json(_try_claude(prompt, 512, _INTENT_MODEL_ID))
    if not isinstance(parsed, dict):
        return {"reply": "", "search": "", "edits": []}
    return parsed


def _curate_plan(message, schedule, candidates, language):
    """Bedrock #2 — 실제 후보들 중 '방문 순서대로' 동선을 골라 제안한다."""
    brief = [
        {"place_id": c["place_id"], "name": c["name"], "rating": c.get("rating"),
         "distance_m": c.get("distance_m"), "address": c.get("address", "")}
        for c in candidates
    ]
    prompt = (
        "당신은 여행 동선을 짜는 현지 가이드입니다.\n"
        f'[사용자 요청]\n"{message}"\n\n'
        f"[현재 일정]\n{_schedule_text(schedule)}\n\n"
        f"[근처 실제 후보(JSON)]\n{json.dumps(brief, ensure_ascii=False)}\n\n"
        "사용자 요청과 현재 일정을 고려해, 추가하면 좋을 곳을 '방문 순서대로' 골라 "
        "동선을 제안하세요. 다음 JSON 만 출력(설명·코드펜스 금지):\n"
        '{"reply":"제안 동선을 설명하는 친근한 한국어 답변",'
        '"proposed_plan":[{"place_id":"후보의 place_id","time_label":"방문 시각대(예: 14:00, 점심)",'
        '"reason":"한 줄 추천 이유"}]}\n'
        "규칙: place_id 는 반드시 위 후보의 것만. 2~4곳 적당히. 이미 일정에 있는 곳은 제외. "
        f"답변 언어: {language}."
    )
    parsed = _safe_json(_try_claude(prompt, 800, _CURATE_MODEL_ID))
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
def _search_places(keyword, lat, lng, language):
    """키워드 + 위치 편향 텍스트검색 → 공용 Place list. 키/네트워크 오류 시 빈 리스트."""
    api_key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not api_key:
        return []
    payload = {
        "textQuery": keyword,
        "languageCode": language,
        "maxResultCount": _MAX_CANDIDATES,
        "locationBias": {
            "circle": {
                "center": {"latitude": lat, "longitude": lng},
                "radius": _DEFAULT_RADIUS_M,
            }
        },
    }
    try:
        data = _places_post(_PLACES_TEXT_URL, payload, api_key)
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError):
        return []
    return [_normalize_place(raw, lat, lng) for raw in data.get("places", [])]


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
    if _is_number(plat) and _is_number(plng):
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
def _try_claude(prompt, max_tokens, model_id):
    """Bedrock 호출 — 실패해도 앱이 죽지 않도록 빈 문자열로 폴백.

    단, 실패 원인은 CloudWatch 에 남긴다(AccessDenied/Validation 등을 눈으로 확인해야
    모델 ID·액세스 문제를 진단할 수 있다). 예전엔 조용히 삼켜 '살펴볼게요'만 남았었다."""
    try:
        return _invoke_claude(prompt, max_tokens, model_id)
    except Exception as exc:  # noqa: BLE001 — 모델/네트워크 오류는 빈 응답으로 흡수
        _log.warning("Bedrock 호출 실패 (model=%s): %s", model_id, exc)
        return ""


def _invoke_claude(prompt, max_tokens, model_id):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.5,
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
