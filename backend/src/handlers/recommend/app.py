"""fn-recommend — GPS + Google Places(New) 기반 실제 장소 추천.

POST /recommend
입력(우선) : {"lat": 35.69, "lng": 139.70, "category": "맛집", "radius": 1500, "language": "ko"}
입력(폴백) : {"location": "도쿄 신주쿠", "category": "맛집"}   # GPS 거부/실패 시
출력 : {
  "recommendation_id": "<uuid>",
  "category": "맛집",
  "ai_summary": "<전체 한 줄 요약>",
  "places": [
    {"place_id","name","rating","user_ratings","distance_m",
     "address","open_now","price_level","location","ai_reason"}, ...
  ]
}

설계 요지(왜 이렇게 했나):
- Google Places API (New) 를 표준 라이브러리 urllib 로만 호출한다 → Lambda 배포 패키지에
  외부 의존성(requirements.txt)이 0이라 빌드가 가볍고 깨질 일이 없다.
- 주변검색 로직(`search_nearby_places`)을 lambda_handler 와 분리한다 → 메인 기능 #2(일정)가
  '일정 변경 시 주변 재추천'에서 같은 부품을 그대로 호출할 수 있다(핸드오프 §3 ★).
- Bedrock(Claude 3 Haiku, us-east-1)에는 JSON 만 받도록 요청하고 방어적으로 파싱한다 →
  카드 UI(plan M-5)가 장소별 이유/요약을 안전하게 그릴 수 있다.

Places API 키는 환경변수 GOOGLE_PLACES_API_KEY 로 주입한다(git 금지, deploy.sh 가 주입).
Bedrock 리전은 us-east-1(모델 액세스 승인). boto3 는 Lambda 런타임 내장 → 의존성 불필요.
"""
import json
import math
import os
import urllib.error
import urllib.request
import uuid

import boto3

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨.
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

_PLACES_NEARBY_URL = "https://places.googleapis.com/v1/places:searchNearby"
_PLACES_TEXT_URL = "https://places.googleapis.com/v1/places:searchText"

# searchNearby/searchText 응답에서 받을 필드만 명시 → 토큰/대역폭 절약(FieldMask).
_FIELD_MASK = ",".join(
    f"places.{f}"
    for f in (
        "id",
        "displayName",
        "rating",
        "userRatingCount",
        "location",
        "formattedAddress",
        "currentOpeningHours.openNow",
        "priceLevel",
    )
)

# 한국어 카테고리 → Google Places type. 미지의 카테고리는 None → 타입 필터 없이 검색.
_CATEGORY_TO_TYPE = {
    "맛집": "restaurant",
    "음식점": "restaurant",
    "식당": "restaurant",
    "숙소": "lodging",
    "호텔": "lodging",
    "관광지": "tourist_attraction",
    "명소": "tourist_attraction",
    "카페": "cafe",
}

_DEFAULT_RADIUS_M = 1500     # 도보권(약 1.5km) 기본 반경
_MAX_RADIUS_M = 50000        # Places(New) 허용 상한
_TOP_N = 5                   # 별점순 상위 N개만 사용자에게

_CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


# ──────────────────────────────────────────────────────────────
# 엔트리포인트
# ──────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    # CORS preflight
    if (event.get("httpMethod") or "").upper() == "OPTIONS":
        return _resp(200, {})

    try:
        body = json.loads(event.get("body") or "{}")
    except (TypeError, ValueError):
        return _resp(400, {"error": "본문이 올바른 JSON이 아닙니다."})

    category = (body.get("category") or "").strip()
    if not category:
        return _resp(400, {"error": "category 는 필수입니다."})

    api_key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not api_key:
        return _resp(500, {"error": "서버에 GOOGLE_PLACES_API_KEY 가 설정되지 않았습니다."})

    place_type = _category_to_type(category)
    language = (body.get("language") or "ko").strip()

    lat, lng = body.get("lat"), body.get("lng")
    location_text = (body.get("location") or "").strip()

    # 입력 분기: 좌표가 있으면 주변검색, 없으면 텍스트검색(폴백)
    try:
        if _is_number(lat) and _is_number(lng):
            radius = _clamp_radius(body.get("radius"))
            places = search_nearby_places(
                float(lat), float(lng), place_type, radius, language, api_key
            )
        elif location_text:
            places = search_text_places(
                location_text, category, place_type, language, api_key
            )
        else:
            return _resp(400, {"error": "lat/lng 또는 location 중 하나는 필수입니다."})
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        return _resp(502, {"error": f"Places 호출 실패({exc.code}): {detail}"})
    except urllib.error.URLError as exc:
        return _resp(502, {"error": f"Places 네트워크 오류: {exc.reason}"})

    if not places:
        return _resp(200, {
            "recommendation_id": str(uuid.uuid4()),
            "category": category,
            "ai_summary": "조건에 맞는 장소를 찾지 못했어요. 반경을 넓히거나 다른 카테고리를 시도해 보세요.",
            "places": [],
        })

    top_places = _top_by_rating(places, _TOP_N)

    # Bedrock 으로 요약 + 장소별 이유 생성(실패해도 장소 목록은 반환).
    ai_summary, reasons = _build_reasons(top_places, category, language)
    for p in top_places:
        p["ai_reason"] = reasons.get(p["place_id"], "")

    return _resp(200, {
        "recommendation_id": str(uuid.uuid4()),
        "category": category,
        "ai_summary": ai_summary,
        "places": top_places,
    })


# ──────────────────────────────────────────────────────────────
# 주변검색 — ★ 메인 기능 #2(일정)가 재사용하는 공용 부품
# ──────────────────────────────────────────────────────────────
def search_nearby_places(lat, lng, place_type, radius, language, api_key):
    """좌표 주변의 장소를 검색해 '공용 Place 형태' 리스트로 반환한다.

    반환 각 항목(공용 Place 형태):
      {place_id, name, rating, user_ratings, location:{lat,lng},
       address, open_now, price_level, distance_m}
    distance_m 은 (lat,lng) 기준 직선거리(미터, 정수).
    """
    payload = {
        "maxResultCount": 20,
        "rankPreference": "POPULARITY",
        "languageCode": language,
        "locationRestriction": {
            "circle": {
                "center": {"latitude": lat, "longitude": lng},
                "radius": radius,
            }
        },
    }
    if place_type:
        payload["includedTypes"] = [place_type]

    data = _places_post(_PLACES_NEARBY_URL, payload, api_key)
    return [
        _normalize_place(raw, origin_lat=lat, origin_lng=lng)
        for raw in data.get("places", [])
    ]


def search_text_places(query, category, place_type, language, api_key):
    """GPS 가 없을 때의 폴백 — '신주쿠 맛집' 같은 텍스트로 검색.

    좌표 기준점이 없으므로 distance_m 은 None 으로 둔다.
    """
    payload = {
        "textQuery": f"{query} {category}".strip(),
        "languageCode": language,
        "maxResultCount": 20,
    }
    if place_type:
        payload["includedType"] = place_type

    data = _places_post(_PLACES_TEXT_URL, payload, api_key)
    return [
        _normalize_place(raw, origin_lat=None, origin_lng=None)
        for raw in data.get("places", [])
    ]


def _places_post(url, payload, api_key):
    """Places API (New) POST 호출 — urllib 표준 라이브러리만 사용."""
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
    with urllib.request.urlopen(req, timeout=10) as res:
        return json.loads(res.read().decode("utf-8"))


def _normalize_place(raw, origin_lat, origin_lng):
    """Google Places(New) 원본 → 공용 Place 형태로 정규화."""
    loc = raw.get("location") or {}
    plat, plng = loc.get("latitude"), loc.get("longitude")

    distance_m = None
    if origin_lat is not None and _is_number(plat) and _is_number(plng):
        distance_m = round(_haversine(origin_lat, origin_lng, plat, plng))

    return {
        "place_id": raw.get("id", ""),
        "name": (raw.get("displayName") or {}).get("text", ""),
        "rating": raw.get("rating"),
        "user_ratings": raw.get("userRatingCount", 0),
        "location": {"lat": plat, "lng": plng},
        "address": raw.get("formattedAddress", ""),
        "open_now": (raw.get("currentOpeningHours") or {}).get("openNow"),
        "price_level": raw.get("priceLevel"),
        "distance_m": distance_m,
    }


# ──────────────────────────────────────────────────────────────
# 순수 로직(테스트 대상)
# ──────────────────────────────────────────────────────────────
def _category_to_type(category):
    return _CATEGORY_TO_TYPE.get((category or "").strip())


def _clamp_radius(value):
    if not _is_number(value):
        return _DEFAULT_RADIUS_M
    return max(1, min(int(value), _MAX_RADIUS_M))


def _top_by_rating(places, n):
    """별점 내림차순 → 리뷰수 내림차순으로 정렬해 상위 n개."""
    return sorted(
        places,
        key=lambda p: (p.get("rating") or 0, p.get("user_ratings") or 0),
        reverse=True,
    )[:n]


def _haversine(lat1, lng1, lat2, lng2):
    """두 좌표 사이의 직선거리(미터). 지구를 구로 근사."""
    r = 6371000.0  # 지구 반지름(m)
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(a))


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# ──────────────────────────────────────────────────────────────
# Bedrock — 요약 + 장소별 이유(JSON 강제, 방어적 파싱)
# ──────────────────────────────────────────────────────────────
def _build_reasons(places, category, language):
    """장소 목록을 받아 (ai_summary, {place_id: reason}) 를 반환.

    Bedrock 실패/형식오류 시에도 앱이 죽지 않도록 빈 값으로 안전하게 폴백한다.
    """
    brief = [
        {
            "place_id": p["place_id"],
            "name": p["name"],
            "rating": p["rating"],
            "user_ratings": p["user_ratings"],
            "distance_m": p["distance_m"],
        }
        for p in places
    ]
    prompt = (
        "당신은 현지 사정에 밝은 여행 동행 가이드입니다.\n"
        f"아래는 '{category}' 카테고리로 찾은 실제 장소 목록(JSON)입니다.\n"
        f"{json.dumps(brief, ensure_ascii=False)}\n\n"
        "다음 형식의 JSON 만 출력하세요(설명·마크다운·코드펜스 금지):\n"
        '{"ai_summary":"전체를 아우르는 한 줄 요약",'
        '"reasons":{"<place_id>":"그 장소를 추천하는 이유 한 줄"}}\n'
        "조건: 모든 place_id 에 대해 reasons 를 채우고, 과장 없이 친근한 "
        f"말투로, 답변 언어는 '{language}'."
    )

    try:
        raw = _invoke_claude(prompt)
        parsed = _parse_json_object(raw)
    except Exception:  # noqa: BLE001 — 추천 본문은 살리고 이유만 비운다
        return "", {}

    summary = parsed.get("ai_summary", "") if isinstance(parsed, dict) else ""
    reasons = parsed.get("reasons", {}) if isinstance(parsed, dict) else {}
    if not isinstance(reasons, dict):
        reasons = {}
    return summary, reasons


def _invoke_claude(prompt):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 768,
        "temperature": 0.6,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
    }
    result = _bedrock.invoke_model(
        modelId=_MODEL_ID,
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


def _parse_json_object(text):
    """모델이 코드펜스나 잡설을 섞어도 첫 '{'~마지막 '}' 구간만 잘라 JSON 파싱."""
    if not text:
        return {}
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        return {}
    return json.loads(text[start:end + 1])


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
