"""fn-recommend 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/recommend/ -q
네트워크(Places)·Bedrock 은 monkeypatch 로 모킹한다.
"""
import json

import app


# ── category → type 매핑 ──────────────────────────────────────
def test_category_mapping_known():
    assert app._category_to_type("맛집") == "restaurant"
    assert app._category_to_type("숙소") == "lodging"
    assert app._category_to_type("관광지") == "tourist_attraction"
    assert app._category_to_type("카페") == "cafe"
    assert app._category_to_type("편의점") == "convenience_store"
    assert app._category_to_type("약국") == "pharmacy"
    assert app._category_to_type("ATM") == "atm"  # 대소문자 무관


def test_category_mapping_unknown_returns_none():
    assert app._category_to_type("우주여행") is None
    assert app._category_to_type("") is None


def test_clarify_suggestions_are_all_mappable():
    # 칩 라벨은 탭 시 category 로 재요청되므로 반드시 매핑돼 있어야 한다.
    for s in app._CLARIFY_SUGGESTIONS:
        assert app._category_to_type(s) is not None


# ── radius 클램프 ────────────────────────────────────────────
def test_clamp_radius_default_when_missing():
    assert app._clamp_radius(None) == app._DEFAULT_RADIUS_M
    assert app._clamp_radius("abc") == app._DEFAULT_RADIUS_M


def test_clamp_radius_bounds():
    assert app._clamp_radius(0) == 1
    assert app._clamp_radius(999999) == app._MAX_RADIUS_M
    assert app._clamp_radius(2000) == 2000


# ── haversine 거리 ──────────────────────────────────────────
def test_haversine_zero_distance():
    assert app._haversine(35.0, 139.0, 35.0, 139.0) == 0


def test_haversine_known_distance():
    # 위도 1도 ≈ 111km. 오차 1% 이내면 통과.
    d = app._haversine(0.0, 0.0, 1.0, 0.0)
    assert abs(d - 111195) < 1112


# ── Places 응답 파싱(_normalize_place) ───────────────────────
_RAW_PLACE = {
    "id": "ChIJxxxx",
    "displayName": {"text": "스시 가게", "languageCode": "ko"},
    "rating": 4.6,
    "userRatingCount": 1200,
    "location": {"latitude": 35.6940, "longitude": 139.7040},
    "formattedAddress": "도쿄도 신주쿠구 ...",
    "currentOpeningHours": {"openNow": True},
    "priceLevel": "PRICE_LEVEL_MODERATE",
    "reviews": [
        {"text": {"text": "오래된 후기"}, "rating": 4,
         "publishTime": "2024-01-01T00:00:00Z", "relativePublishTimeDescription": "1년 전"},
        {"text": {"text": "최신 후기 — 신선해요"}, "rating": 5,
         "publishTime": "2026-05-01T00:00:00Z", "relativePublishTimeDescription": "한 달 전"},
    ],
}


def test_normalize_place_with_origin_sets_distance():
    p = app._normalize_place(_RAW_PLACE, origin_lat=35.6938, origin_lng=139.7034)
    assert p["place_id"] == "ChIJxxxx"
    assert p["name"] == "스시 가게"
    assert p["rating"] == 4.6
    assert p["user_ratings"] == 1200
    assert p["open_now"] is True
    assert p["address"].startswith("도쿄도")
    assert isinstance(p["distance_m"], int) and p["distance_m"] >= 0


# ── 리뷰 추출(_extract_reviews) ──────────────────────────────
def test_extract_reviews_sorts_newest_first_and_limits():
    p = app._normalize_place(_RAW_PLACE, origin_lat=None, origin_lng=None)
    texts = [r["text"] for r in p["reviews"]]
    # 최신 publishTime 이 먼저, 최대 _MAX_REVIEWS 개
    assert texts[0] == "최신 후기 — 신선해요"
    assert len(p["reviews"]) <= app._MAX_REVIEWS
    assert "_t" not in p["reviews"][0]  # 정렬용 내부 키는 제거됨


def test_extract_reviews_skips_empty_and_handles_none():
    assert app._extract_reviews(None) == []
    assert app._extract_reviews([{"text": {"text": "  "}}]) == []


def test_normalize_place_without_origin_distance_none():
    p = app._normalize_place(_RAW_PLACE, origin_lat=None, origin_lng=None)
    assert p["distance_m"] is None


def test_normalize_place_handles_missing_fields():
    p = app._normalize_place({"id": "x"}, origin_lat=None, origin_lng=None)
    assert p["place_id"] == "x"
    assert p["name"] == ""
    assert p["rating"] is None
    assert p["user_ratings"] == 0
    assert p["open_now"] is None


# ── 별점순 Top N ─────────────────────────────────────────────
def test_top_by_rating_orders_and_limits():
    places = [
        {"place_id": "a", "rating": 3.0, "user_ratings": 10},
        {"place_id": "b", "rating": 4.8, "user_ratings": 50},
        {"place_id": "c", "rating": 4.8, "user_ratings": 900},  # 동점 → 리뷰수 우선
        {"place_id": "d", "rating": None, "user_ratings": 0},
    ]
    top = app._top_by_rating(places, 2)
    assert [p["place_id"] for p in top] == ["c", "b"]


# ── Bedrock JSON 방어 파싱(_parse_json_object) ───────────────
def test_parse_json_plain():
    assert app._parse_json_object('{"ai_summary":"hi","reasons":{}}')["ai_summary"] == "hi"


def test_parse_json_with_code_fence_and_noise():
    text = '여기 결과입니다:\n```json\n{"ai_summary":"좋아요","reasons":{"a":"맛집"}}\n```끝'
    parsed = app._parse_json_object(text)
    assert parsed["reasons"]["a"] == "맛집"


def test_parse_json_garbage_returns_empty():
    assert app._parse_json_object("죄송하지만 JSON 이 없습니다") == {}
    assert app._parse_json_object("") == {}


# ── _build_summaries: Bedrock 모킹 ───────────────────────────
def test_build_summaries_success(monkeypatch):
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt, max_tokens=768: (
            '{"ai_summary":"근처 맛집 모음",'
            '"places":{"a":{"good":"신선해요","bad":"웨이팅 길어요"}}}'
        ),
    )
    places = [{"place_id": "a", "name": "X", "rating": 4.5,
               "user_ratings": 10, "distance_m": 100, "reviews": []}]
    summary, details = app._build_summaries(places, "맛집", "ko")
    assert summary == "근처 맛집 모음"
    assert details["a"]["good"] == "신선해요"
    assert details["a"]["bad"] == "웨이팅 길어요"


def test_build_summaries_bedrock_failure_is_safe(monkeypatch):
    def boom(prompt, max_tokens=768):
        raise RuntimeError("Bedrock down")
    monkeypatch.setattr(app, "_invoke_claude", boom)
    summary, details = app._build_summaries([{"place_id": "a", "name": "X",
        "rating": 4.5, "user_ratings": 10, "distance_m": 100, "reviews": []}],
        "맛집", "ko")
    assert summary == "" and details == {}


# ── _resolve_intent: 자연어 → Google 타입 ────────────────────
def test_resolve_intent_resolved(monkeypatch):
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt, max_tokens=768:
            '{"type":"convenience_store","label":"편의점","clarify":""}',
    )
    t, label, clarify = app._resolve_intent("근처 편의점 찾아줘", "ko")
    assert t == "convenience_store" and label == "편의점" and clarify == ""


def test_resolve_intent_ambiguous_returns_clarify(monkeypatch):
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt, max_tokens=768:
            '{"type":"","label":"","clarify":"숙소를 찾을까요?"}',
    )
    t, label, clarify = app._resolve_intent("여기 여행하고 싶어", "ko")
    assert t == "" and "숙소" in clarify


def test_resolve_intent_bedrock_failure_is_safe(monkeypatch):
    def boom(prompt, max_tokens=768):
        raise RuntimeError("down")
    monkeypatch.setattr(app, "_invoke_claude", boom)
    t, label, clarify = app._resolve_intent("아무거나", "ko")
    assert t == "" and label == "" and clarify == ""


# ── search_nearby_places: 네트워크 모킹 ──────────────────────
def test_search_nearby_places_parses_and_distances(monkeypatch):
    captured = {}

    def fake_post(url, payload, api_key):
        captured["url"] = url
        captured["payload"] = payload
        return {"places": [_RAW_PLACE]}

    monkeypatch.setattr(app, "_places_post", fake_post)
    out = app.search_nearby_places(
        35.6938, 139.7034, "restaurant", 1500, "ko", "FAKE_KEY"
    )
    assert captured["url"] == app._PLACES_NEARBY_URL
    assert captured["payload"]["includedTypes"] == ["restaurant"]
    assert captured["payload"]["locationRestriction"]["circle"]["radius"] == 1500
    assert len(out) == 1
    assert out[0]["distance_m"] is not None


# ── lambda_handler: 입력 검증 ────────────────────────────────
def _event(body, method="POST"):
    return {"httpMethod": method, "body": json.dumps(body)}


def test_handler_options_preflight():
    r = app.lambda_handler({"httpMethod": "OPTIONS"}, None)
    assert r["statusCode"] == 200


def test_handler_missing_category_and_query(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    r = app.lambda_handler(_event({"lat": 1, "lng": 2}), None)
    assert r["statusCode"] == 400


def test_handler_missing_api_key(monkeypatch):
    monkeypatch.delenv("GOOGLE_PLACES_API_KEY", raising=False)
    r = app.lambda_handler(_event({"lat": 1, "lng": 2, "category": "맛집"}), None)
    assert r["statusCode"] == 500


def test_handler_no_coords_no_location(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    r = app.lambda_handler(_event({"category": "맛집"}), None)
    assert r["statusCode"] == 400


def test_handler_happy_path_with_gps(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    monkeypatch.setattr(app, "_places_post", lambda u, p, k: {"places": [_RAW_PLACE]})
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt, max_tokens=768: (
            '{"ai_summary":"근처 맛집",'
            '"places":{"ChIJxxxx":{"good":"신선해요","bad":"웨이팅"}}}'
        ),
    )
    r = app.lambda_handler(_event({"lat": 35.6938, "lng": 139.7034,
                                   "category": "맛집"}), None)
    assert r["statusCode"] == 200
    body = json.loads(r["body"])
    assert body["type"] == "result"
    assert body["category"] == "맛집"
    assert body["ai_summary"] == "근처 맛집"
    place = body["places"][0]
    assert place["review_good"] == "신선해요"
    assert place["review_bad"] == "웨이팅"
    assert place["reviews_used"] == 2
    assert "reviews" not in place  # 원본 리뷰는 응답에서 제외
    assert "recommendation_id" in body


def test_handler_natural_language_query_resolves_type(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    captured = {}

    def fake_post(u, p, k):
        captured["payload"] = p
        return {"places": [_RAW_PLACE]}

    def fake_claude(prompt, max_tokens=768):
        # 의도 추출 호출 vs 요약 호출을 프롬프트 내용으로 구분
        if "Google Places API" in prompt:
            return '{"type":"convenience_store","label":"편의점","clarify":""}'
        return '{"ai_summary":"근처 편의점","places":{"ChIJxxxx":{"good":"가까워요","bad":"-"}}}'

    monkeypatch.setattr(app, "_places_post", fake_post)
    monkeypatch.setattr(app, "_invoke_claude", fake_claude)
    r = app.lambda_handler(_event({"lat": 35.6938, "lng": 139.7034,
                                   "query": "근처 편의점 찾아줘"}), None)
    assert r["statusCode"] == 200
    body = json.loads(r["body"])
    assert body["type"] == "result"
    assert body["category"] == "편의점"
    # 알려진 타입이므로 정밀 주변검색(includedTypes)으로 나갔는지
    assert captured["payload"]["includedTypes"] == ["convenience_store"]


def test_handler_unknown_type_falls_back_to_text_search(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    captured = {}

    def fake_post(u, p, k):
        captured["url"] = u
        captured["payload"] = p
        return {"places": [_RAW_PLACE]}

    def fake_claude(prompt, max_tokens=768):
        if "Google Places API" in prompt:
            # 검증목록에 없는 희귀 타입을 모델이 내놓은 상황
            return '{"type":"made_up_type","label":"방탈출카페","clarify":""}'
        return '{"ai_summary":"방탈출","places":{"ChIJxxxx":{"good":"재밌어요","bad":"-"}}}'

    monkeypatch.setattr(app, "_places_post", fake_post)
    monkeypatch.setattr(app, "_invoke_claude", fake_claude)
    r = app.lambda_handler(_event({"lat": 35.6938, "lng": 139.7034,
                                   "query": "근처 방탈출카페"}), None)
    assert r["statusCode"] == 200
    # 타입 검증 실패 → 키워드 텍스트 검색(searchText)으로 우회 + 위치 편향
    assert captured["url"] == app._PLACES_TEXT_URL
    assert captured["payload"]["textQuery"] == "방탈출카페"
    assert "locationBias" in captured["payload"]


def test_handler_ambiguous_query_returns_clarify(monkeypatch):
    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "K")
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt, max_tokens=768:
            '{"type":"","label":"","clarify":"맛집을 찾을까요, 숙소를 찾을까요?"}',
    )
    r = app.lambda_handler(_event({"lat": 35.6938, "lng": 139.7034,
                                   "query": "여기 여행하고 싶어"}), None)
    assert r["statusCode"] == 200
    body = json.loads(r["body"])
    assert body["type"] == "clarify"
    assert body["suggestions"] == app._CLARIFY_SUGGESTIONS
    assert "맛집" in body["message"]
