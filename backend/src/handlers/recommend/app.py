"""fn-recommend — GPS + Google Places(New) 기반 실제 장소 추천(대화형).

POST /recommend
입력(대화/주력) : {"lat": 35.69, "lng": 139.70, "query": "근처 괜찮은 레스토랑", "radius": 1500, "language": "ko"}
입력(칩 버튼)   : {"lat": 35.69, "lng": 139.70, "category": "맛집"}
입력(폴백)      : {"location": "도쿄 신주쿠", "query": "라멘"}   # GPS 거부/실패 시

응답 2종(type 으로 구분):
  ① 카테고리 불명확 →
     {"type":"clarify","message":"숙소를 찾을까요, 맛집을 찾을까요?",
      "suggestions":["맛집","숙소","관광지","카페"]}
  ② 결과 →
     {"type":"result","recommendation_id":"<uuid>","category":"맛집",
      "ai_summary":"<전체 한 줄 요약>",
      "places":[{"place_id","name","rating","user_ratings","distance_m",
                 "address","open_now","price_level","location",
                 "review_good","review_bad","reviews_used"}, ...]}

설계 요지(왜 이렇게 했나):
- Google Places API (New) 를 표준 라이브러리 urllib 로만 호출한다 → Lambda 배포 패키지에
  외부 의존성(requirements.txt)이 0이라 빌드가 가볍고 깨질 일이 없다.
- 자연어 발화 → 카테고리 '추출'을 Bedrock 한 콜로 처리한다. 한 카테고리로 못 좁히면
  결과 대신 clarify(되묻기) 응답을 돌려준다 → 사용자가 그린 "AI가 카테고리 파악, 어려우면
  다시 물음" 흐름.
- 주변검색 로직(`search_nearby_places`)을 lambda_handler 와 분리한다 → 메인 기능 #2(일정)가
  '일정 변경 시 주변 재추천'에서 같은 부품을 그대로 호출할 수 있다(핸드오프 §3 ★).
- FieldMask 에 places.reviews 를 추가해 가게별 리뷰를 한 번의 검색 호출로 함께 받는다
  (가게마다 따로 부르지 않음 → 호출 수 1회 유지). 받은 리뷰(최대 5)를 작성시각 내림차순으로
  정렬해 최신 3개만 Bedrock 에 넘겨 '좋은 점/아쉬운 점'을 요약한다.
- Bedrock(Claude 3 Haiku, us-east-1)에는 JSON 만 받도록 요청하고 방어적으로 파싱한다 →
  카드 UI(plan M-5)가 장소별 리뷰 요약을 안전하게 그릴 수 있다.

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
# reviews 는 요금 등급이 높은 필드지만, 가게 5곳을 한 번의 호출로 함께 받으므로 호출 수는 1회.
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
        "reviews",
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

# 자연어 추출이 못 좁혔을 때 사용자에게 제시할 표준 카테고리 칩.
_CLARIFY_SUGGESTIONS = ["맛집", "숙소", "관광지", "카페"]

_DEFAULT_RADIUS_M = 1500     # 도보권(약 1.5km) 기본 반경
_MAX_RADIUS_M = 50000        # Places(New) 허용 상한
_TOP_N = 5                   # 별점순 상위 N개만 사용자에게
_MAX_REVIEWS = 3             # 장소별 Bedrock 에 넘길 최신 리뷰 개수
_REVIEW_CHARS = 300          # 리뷰 1개당 프롬프트에 넣을 최대 글자수(토큰 절약)

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

    api_key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not api_key:
        return _resp(500, {"error": "서버에 GOOGLE_PLACES_API_KEY 가 설정되지 않았습니다."})

    language = (body.get("language") or "ko").strip()
    category = (body.get("category") or "").strip()
    query = (body.get("query") or "").strip()

    # 카테고리 확정: 명시 category 우선, 없으면 자연어 query 에서 추출.
    if not category:
        if query:
            category, clarify = _extract_category(query, language)
            if not category:
                return _resp(200, {
                    "type": "clarify",
                    "message": clarify or "어떤 곳을 찾아드릴까요?",
                    "suggestions": _CLARIFY_SUGGESTIONS,
                })
        else:
            return _resp(400, {"error": "category 또는 query 중 하나는 필수입니다."})

    place_type = _category_to_type(category)

    lat, lng = body.get("lat"), body.get("lng")
    location_text = (body.get("location") or "").strip()
    # 검색어: 자연어 query 가 있으면 그대로, 없으면 카테고리로.
    search_term = query or category

    # 입력 분기: 좌표가 있으면 주변검색, 없으면 텍스트검색(폴백)
    try:
        if _is_number(lat) and _is_number(lng):
            radius = _clamp_radius(body.get("radius"))
            places = search_nearby_places(
                float(lat), float(lng), place_type, radius, language, api_key
            )
        elif location_text:
            places = search_text_places(
                f"{location_text} {search_term}".strip(), place_type, language, api_key
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
            "type": "result",
            "recommendation_id": str(uuid.uuid4()),
            "category": category,
            "ai_summary": "조건에 맞는 장소를 찾지 못했어요. 반경을 넓히거나 다른 카테고리를 시도해 보세요.",
            "places": [],
        })

    top_places = _top_by_rating(places, _TOP_N)

    # Bedrock 으로 전체 요약 + 장소별 리뷰 요약(좋은 점/아쉬운 점) 생성.
    # 실패해도 장소 목록은 그대로 반환(요약만 빈 값).
    ai_summary, details = _build_summaries(top_places, category, language)
    for p in top_places:
        d = details.get(p["place_id"]) or {}
        p["review_good"] = d.get("good", "")
        p["review_bad"] = d.get("bad", "")
        p["reviews_used"] = len(p.get("reviews", []))
        p.pop("reviews", None)  # 내부용 원본 리뷰는 응답 payload 에서 제외

    return _resp(200, {
        "type": "result",
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
       address, open_now, price_level, distance_m, reviews:[{text,rating,when}]}
    distance_m 은 (lat,lng) 기준 직선거리(미터, 정수).
    reviews 는 작성시각 내림차순 정렬 후 최신 _MAX_REVIEWS 개.
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


def search_text_places(text_query, place_type, language, api_key):
    """GPS 가 없을 때의 폴백 — '신주쿠 라멘' 같은 텍스트로 검색.

    좌표 기준점이 없으므로 distance_m 은 None 으로 둔다.
    """
    payload = {
        "textQuery": text_query,
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
        "reviews": _extract_reviews(raw.get("reviews")),
    }


def _extract_reviews(raw_reviews):
    """Places 리뷰 원본 → [{text, rating, when}] 최신순 최대 _MAX_REVIEWS 개.

    각 리뷰의 publishTime(RFC3339 문자열)으로 내림차순 정렬해 '받아온 것 중 최신'을 고른다.
    (Places(New)는 가게당 최대 5개만 주므로 '구글 전체 최신'은 보장하지 않음.)
    """
    out = []
    for rv in raw_reviews or []:
        text = (rv.get("text") or {}).get("text") \
            or (rv.get("originalText") or {}).get("text") or ""
        text = text.strip()
        if not text:
            continue
        out.append({
            "text": text,
            "rating": rv.get("rating"),
            "when": rv.get("relativePublishTimeDescription", ""),
            "_t": rv.get("publishTime", ""),
        })
    out.sort(key=lambda r: r["_t"], reverse=True)
    out = out[:_MAX_REVIEWS]
    for r in out:
        r.pop("_t", None)
    return out


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
# Bedrock — ① 자연어→카테고리 추출  ② 리뷰 요약(JSON 강제, 방어적 파싱)
# ──────────────────────────────────────────────────────────────
def _extract_category(query, language):
    """자연어 발화에서 표준 카테고리 하나를 고른다.

    반환: (category, clarify_message)
      - 한 카테고리로 좁혀지면 (그 카테고리, "")
      - 모호하면 ("", 되물을 질문 문자열)
    Bedrock 실패 시에도 앱이 죽지 않도록 ("", 기본 질문)으로 안전 폴백.
    """
    prompt = (
        "사용자의 여행 발화에서 장소 카테고리를 하나만 고르세요.\n"
        f"허용 카테고리: {', '.join(_CLARIFY_SUGGESTIONS)}\n"
        f'사용자 발화: "{query}"\n\n'
        "다음 형식의 JSON 만 출력하세요(설명·마크다운·코드펜스 금지):\n"
        '{"category":"맛집|숙소|관광지|카페 중 하나, 못 정하면 빈 문자열",'
        '"message":"category 가 빈 문자열일 때만, 어떤 곳을 찾을지 되묻는 친근한 질문"}\n'
        f"확실히 한 카테고리로 정할 수 있을 때만 category 를 채우고, 아니면 비우세요. 언어: {language}"
    )
    try:
        parsed = _parse_json_object(_invoke_claude(prompt, max_tokens=256))
    except Exception:  # noqa: BLE001 — 추출 실패는 곧 '되묻기'로 처리
        return "", ""

    cat = (parsed.get("category") or "").strip() if isinstance(parsed, dict) else ""
    msg = (parsed.get("message") or "").strip() if isinstance(parsed, dict) else ""
    if cat in _CATEGORY_TO_TYPE:
        return cat, ""
    return "", msg


def _build_summaries(places, category, language):
    """장소+리뷰 목록 → (ai_summary, {place_id: {"good","bad"}}) 를 반환.

    각 장소의 최신 리뷰를 읽고 '좋은 점/아쉬운 점'을 요약한다.
    Bedrock 실패/형식오류 시에도 앱이 죽지 않도록 빈 값으로 안전 폴백한다.
    """
    brief = [
        {
            "place_id": p["place_id"],
            "name": p["name"],
            "rating": p["rating"],
            "user_ratings": p["user_ratings"],
            "distance_m": p["distance_m"],
            "reviews": [r["text"][:_REVIEW_CHARS] for r in p.get("reviews", [])],
        }
        for p in places
    ]
    prompt = (
        "당신은 현지 사정에 밝은 여행 동행 가이드입니다.\n"
        f"아래는 '{category}' 카테고리로 찾은 실제 장소와 각 장소의 최신 리뷰(JSON)입니다.\n"
        f"{json.dumps(brief, ensure_ascii=False)}\n\n"
        "각 장소의 리뷰를 읽고 '좋은 점(good)'과 '아쉬운 점(bad)'을 요약하세요.\n"
        "리뷰가 비어 있으면 good 에 별점·리뷰수 기반의 한 줄, bad 에 "
        "'아직 리뷰 정보가 적어요' 류로 채우세요.\n"
        "다음 형식의 JSON 만 출력하세요(설명·마크다운·코드펜스 금지):\n"
        '{"ai_summary":"전체를 아우르는 한 줄 요약",'
        '"places":{"<place_id>":{"good":"좋은 점 한두 줄","bad":"아쉬운 점 한두 줄"}}}\n'
        "조건: 모든 place_id 를 채우고, 과장 없이 친근한 말투로, "
        f"답변 언어는 '{language}'."
    )

    try:
        parsed = _parse_json_object(_invoke_claude(prompt, max_tokens=1024))
    except Exception:  # noqa: BLE001 — 추천 본문은 살리고 요약만 비운다
        return "", {}

    summary = parsed.get("ai_summary", "") if isinstance(parsed, dict) else ""
    details = parsed.get("places", {}) if isinstance(parsed, dict) else {}
    if not isinstance(details, dict):
        details = {}
    return summary, details


def _invoke_claude(prompt, max_tokens=768):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.4,
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
