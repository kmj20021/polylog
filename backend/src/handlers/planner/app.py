"""fn-planner — '대화하며 하루 일정을 함께 짜는' AI 플래너(fn-schedule 에서 분리).

왜 별도 함수인가:
  fn-schedule 은 ①일정 CRUD ②대화형 플래너 ③순서 재정렬 ④여행 CRUD 를 모두 했는데, ②플래너만
  성격이 다르다 — Bedrock(Haiku+Sonnet) + Google Places 를 부르는 '무거운(최대 30초)' 작업이라,
  가벼운 CRUD 와 한 함수에 묶이면 (a) 가벼운 호출도 30초 타임아웃·Bedrock/Places 권한을 떠안고
  (b) 플래너 버그가 일정·여행 조회까지 함께 죽인다(blast radius). 그래서 ②만 이 함수로 떼어
  자원·고장·권한을 격리한다. 라우트는 전용 POST /planner.

흐름(_handle_chat):
  입력 : {trip_id, message, lat, lng, language}   (action 은 있어도 무시 — 이 함수는 chat 전용)
  1) polylog-chats 에서 '이전 대화', polylog-schedules 에서 '현재 일정'을 로드.
  2) Bedrock #1(두뇌, Haiku): 대화+일정+새 메시지 → {reply, region, searches, edits} 판단.
  3) edits(삭제/순서변경)를 즉시 적용(사용자가 명령한 것이므로 바로 반영).
  4) searches 가 있으면 Google Places(텍스트검색)로 후보를 모으고(place_id 중복 제거)
     → Bedrock #2(큐레이터, Sonnet)가 '관광·식사·카페를 섞어 방문 순서대로' 동선을 제안(저장 X).
  5) 사용자 메시지 + AI 응답을 polylog-chats 에 저장(다음 턴의 기억).
  응답 : {type:"chat", reply, proposed_plan:[...], timeline:[...현재 일정...], edited:bool}

  ※ 제안(proposed_plan)은 '확정 전 미리보기'. 사용자가 앱에서 '담기'를 누르면 각 장소를
    POST /schedule(담기)로 저장한다 → 저장은 여전히 fn-schedule 담당(이 함수는 읽기+편집만).

설계 메모:
- Places/Bedrock 부품은 fn-recommend·fn-schedule 에도 있지만 '다른 배포 패키지'라 import 불가 →
  필요한 최소분만 이 파일에 복제한다(의존성 0, 배포 위험 0 — 이 코드베이스의 확립된 관례).
- Bedrock 은 us-east-1(모델 액세스 승인), 그 외 자원은 ap-northeast-2. SafeRole-polylog 가
  DynamoDB(polylog*)·Bedrock 권한 보유(ADR-012) → 추가 IAM 불필요. polylog-trips 는 안 건드림.
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
_DEFAULT_RADIUS_M = 2000         # 근처 모드일 때 위치 편향 반경(도보권 조금 넓게)
_MAX_SEARCHES = 4                # 의도판단이 뽑은 검색어 중 실제 호출할 상한(지연·요금 관리)
_PER_QUERY_LIMIT = 6            # 검색어 1개당 가져올 후보 수
_MAX_POOL = 16                  # 큐레이터에 넘길 후보 풀 상한(Bedrock 토큰 budget)
_HISTORY_TURNS = 12             # Bedrock 에 넣을 최근 대화 메시지 수(토큰 budget)

_CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def lambda_handler(event, context):
    """API Gateway(프록시 통합) 진입점 — 이 함수는 대화형 플래너 전용(POST /planner)."""
    method = (event or {}).get("httpMethod", "POST").upper()
    if method == "OPTIONS":
        return _resp(200, {"ok": True})
    if method == "POST":
        return _handle_chat(_parse_body(event))
    return _resp(405, {"error": f"지원하지 않는 메서드: {method}"})


# ════════════════════════════ 대화형 플래너 ════════════════════════════
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
                '그 지역'을 그대로 찾게 한다(다른 도시 일정 가능).
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
