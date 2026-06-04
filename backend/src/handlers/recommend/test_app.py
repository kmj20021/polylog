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


def test_category_mapping_unknown_returns_none():
    assert app._category_to_type("우주여행") is None
    assert app._category_to_type("") is None


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


# ── _build_reasons: Bedrock 모킹 ─────────────────────────────
def test_build_reasons_success(monkeypatch):
    monkeypatch.setattr(
        app, "_invoke_claude",
        lambda prompt: '{"ai_summary":"근처 맛집 모음","reasons":{"a":"별점이 높아요"}}',
    )
    places = [{"place_id": "a", "name": "X", "rating": 4.5,
               "user_ratings": 10, "distance_m": 100}]
    summary, reasons = app._build_reasons(places, "맛집", "ko")
    assert summary == "근처 맛집 모음"
    assert reasons["a"] == "별점이 높아요"


def test_build_reasons_bedrock_failure_is_safe(monkeypatch):
    def boom(prompt):
        raise RuntimeError("Bedrock down")
    monkeypatch.setattr(app, "_invoke_claude", boom)
    summary, reasons = app._build_reasons([{"place_id": "a", "name": "X",
        "rating": 4.5, "user_ratings": 10, "distance_m": 100}], "맛집", "ko")
    assert summary == "" and reasons == {}


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


def test_handler_missing_category(monkeypatch):
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
        lambda prompt: '{"ai_summary":"근처 맛집","reasons":{"ChIJxxxx":"인기 많아요"}}',
    )
    r = app.lambda_handler(_event({"lat": 35.6938, "lng": 139.7034,
                                   "category": "맛집"}), None)
    assert r["statusCode"] == 200
    body = json.loads(r["body"])
    assert body["category"] == "맛집"
    assert body["ai_summary"] == "근처 맛집"
    assert body["places"][0]["ai_reason"] == "인기 많아요"
    assert "recommendation_id" in body
