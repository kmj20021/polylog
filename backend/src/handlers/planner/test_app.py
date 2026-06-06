"""fn-planner 단위 테스트 — DynamoDB/Bedrock/Places 를 가짜로 대체(실 호출 없음).

fn-schedule 에서 분리한 대화형 플래너(POST /planner) 전용. 진입점이 POST→chat 으로
단순해졌으므로(action 무시) 본문에 action 을 넣지 않는다.

실행: cd backend && python -m pytest src/handlers/planner/ -q
"""
import json

import app


# ─────────────────────────── 가짜 DynamoDB ───────────────────────────
class _FakeTable:
    """put/delete 를 기록하고, query 는 미리 정해둔 항목을 돌려주는 가짜 테이블."""

    def __init__(self, query_items=None):
        self.put_items = []
        self._query_items = query_items or []
        self.last_query_kwargs = None
        self.deleted_keys = []

    def put_item(self, Item):
        self.put_items.append(Item)
        return {}

    def query(self, **kwargs):
        self.last_query_kwargs = kwargs
        return {"Items": list(self._query_items)}

    def delete_item(self, Key):
        self.deleted_keys.append(Key)
        return {}


class _FakeResource:
    """이름→테이블 매핑. 매핑에 없으면 default 를 돌려준다."""

    def __init__(self, default, tables=None):
        self._default = default
        self._tables = tables or {}

    def Table(self, name):
        return self._tables.get(name, self._default)


def _install_tables(monkeypatch, schedules, chats):
    """대화 플래너 테스트용 — schedules/chats 를 분리해 설치."""
    monkeypatch.setattr(app, "_dynamodb", _FakeResource(
        schedules, {"polylog-schedules": schedules, "polylog-chats": chats}))


def _fake_claude(responses):
    """_invoke_claude 를 호출 순서대로 미리 정한 문자열을 돌려주도록 대체."""
    seq = iter(responses)

    def _inner(prompt, max_tokens, model_id=None, temperature=None):
        return next(seq)

    return _inner


def _chat(body):
    """POST /planner 요청(이 함수는 action 을 보지 않으므로 넣지 않는다)."""
    return {"httpMethod": "POST", "body": json.dumps(body)}


# ─────────────────────────── 순수 헬퍼 ───────────────────────────
def test_clean_trims_and_handles_none():
    assert app._clean("  hi  ") == "hi"
    assert app._clean(None) == ""
    assert app._clean(123) == "123"


def test_json_safe_decimal_to_number():
    from decimal import Decimal
    out = app._json_safe({"a": Decimal("4"), "b": Decimal("4.5"), "c": [Decimal("1")]})
    assert out == {"a": 4, "b": 4.5, "c": [1]}
    assert isinstance(out["a"], int)
    assert isinstance(out["b"], float)


def test_parse_body_variants():
    assert app._parse_body({"body": '{"x":1}'}) == {"x": 1}
    assert app._parse_body({"body": {"x": 1}}) == {"x": 1}
    assert app._parse_body({"body": None}) == {}
    assert app._parse_body({"body": "not json"}) == {}


def test_safe_json_extracts_object():
    assert app._safe_json('잡설 {"a":1} 더 잡설') == {"a": 1}
    assert app._safe_json("코드펜스 없음") == {}
    assert app._safe_json("") == {}


def test_wants_places_detects_request():
    assert app._wants_places("일정 짜줘") is True
    assert app._wants_places("근처 맛집 추천해줘") is True
    assert app._wants_places("다른 곳도 보여줘") is True
    assert app._wants_places("고마워, 잘 가") is False
    assert app._wants_places("") is False
    assert app._wants_places(None) is False


def test_normalize_searches_list_and_legacy():
    assert app._normalize_searches(
        {"searches": [" 광화문 경복궁 ", "", "북촌 카페"]}) == ["광화문 경복궁", "북촌 카페"]
    assert app._normalize_searches({"search": "조용한 카페"}) == ["조용한 카페"]
    assert app._normalize_searches({"searches": ["A"], "search": "B"}) == ["A"]
    assert app._normalize_searches({}) == []


def test_schedule_text_numbers_items():
    txt = app._schedule_text([
        {"place_name": "A", "time_label": "14:00"},
        {"place_name": "B"},
    ])
    assert "1. A (14:00)" in txt
    assert "2. B" in txt
    assert app._schedule_text([]) == "(아직 일정 없음)"


# ─────────────────────────── Places ───────────────────────────
def test_search_places_multi_query_dedupes(monkeypatch):
    # 두 검색어가 겹치는 후보(P2)를 반환해도 place_id 로 중복 제거된다.
    calls = []

    def _fake_post(url, payload, api_key):
        calls.append(payload)
        if "관광" in payload["textQuery"]:
            return {"places": [
                {"id": "P1", "displayName": {"text": "경복궁"},
                 "location": {"latitude": 37.5, "longitude": 126.9}},
                {"id": "P2", "displayName": {"text": "겹침장소"},
                 "location": {"latitude": 37.6, "longitude": 126.98}},
            ]}
        return {"places": [
            {"id": "P2", "displayName": {"text": "겹침장소"},  # 중복
             "location": {"latitude": 37.6, "longitude": 126.98}},
            {"id": "P3", "displayName": {"text": "북촌카페"},
             "location": {"latitude": 37.58, "longitude": 126.99}},
        ]}

    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "k")
    monkeypatch.setattr(app, "_places_post", _fake_post)

    out = app._search_places(["광화문 경복궁 관광", "북촌 카페"], "ko")

    ids = [p["place_id"] for p in out]
    assert ids == ["P1", "P2", "P3"]            # 입력 순서 보존 + 중복 1개 제거
    assert len(calls) == 2
    assert all("locationBias" not in c for c in calls)   # region 모드 → 편향 없음
    assert all(p["distance_m"] is None for p in out)


def test_search_places_biases_when_coords_given(monkeypatch):
    captured = {}

    def _fake_post(url, payload, api_key):
        captured.update(payload)
        return {"places": [
            {"id": "P1", "displayName": {"text": "근처카페"},
             "location": {"latitude": 43.6, "longitude": -79.3}},
        ]}

    monkeypatch.setenv("GOOGLE_PLACES_API_KEY", "k")
    monkeypatch.setattr(app, "_places_post", _fake_post)

    out = app._search_places(["카페"], "ko", 43.6453, -79.3806)
    assert "locationBias" in captured              # 근처 모드 → 위치 편향
    assert out[0]["distance_m"] is not None         # origin 있으니 거리 계산됨


def test_search_places_no_key_returns_empty(monkeypatch):
    monkeypatch.delenv("GOOGLE_PLACES_API_KEY", raising=False)
    assert app._search_places(["카페"], "ko") == []


# ─────────────────────────── 대화형 플래너 ───────────────────────────
def test_chat_search_proposes_plan(monkeypatch):
    schedules = _FakeTable(query_items=[])   # 아직 일정 없음
    chats = _FakeTable(query_items=[])        # 첫 대화
    _install_tables(monkeypatch, schedules, chats)

    # Bedrock #1(두뇌)=검색 필요, #2(큐레이터)=동선 제안
    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"네!","search":"조용한 카페","edits":[]}',
        '{"reply":"이렇게 짜봤어요","proposed_plan":'
        '[{"place_id":"A","time_label":"14:00","reason":"조용함"}]}',
    ]))
    monkeypatch.setattr(app, "_search_places", lambda *a, **k: [
        {"place_id": "A", "name": "카페 A", "rating": 4.6, "distance_m": 120,
         "address": "토론토 1번가", "location": {"lat": 43.6, "lng": -79.3}},
        {"place_id": "B", "name": "카페 B", "rating": 4.2, "distance_m": 300,
         "address": "토론토 2번가", "location": {"lat": 43.7, "lng": -79.4}},
    ])

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "조용한 카페 추천해줘",
        "lat": 43.6453, "lng": -79.3806,
    }), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["type"] == "chat"
    assert body["reply"] == "이렇게 짜봤어요"          # 큐레이터 답변 우선
    assert len(body["proposed_plan"]) == 1
    p = body["proposed_plan"][0]
    assert p["place_id"] == "A"
    assert p["place_name"] == "카페 A"                 # 후보 상세와 합쳐짐
    assert p["time_label"] == "14:00"
    assert p["latitude"] == 43.6
    # 대화 기억 저장(사용자+AI 2줄)
    assert len(chats.put_items) == 2
    assert chats.put_items[0]["role"] == "user"
    assert chats.put_items[1]["role"] == "assistant"


def test_chat_region_plans_without_gps(monkeypatch):
    """지역명을 말하면 GPS 없이도, 현재 위치 편향 없이 그 지역으로 동선을 짠다(멀티카테고리)."""
    schedules = _FakeTable(query_items=[])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"좋아요!","region":"서울 광화문 북촌",'
        '"searches":["광화문 경복궁 관광","광화문 칼국수 맛집","북촌 카페"],"edits":[]}',
        '{"reply":"광화문에서 북촌으로 이렇게 돌아요","proposed_plan":['
        '{"place_id":"G","time_label":"오전","reason":"대표 관광"},'
        '{"place_id":"K","time_label":"점심","reason":"칼국수"},'
        '{"place_id":"C","time_label":"오후","reason":"카페"}]}',
    ]))

    captured = {"queries": None, "lat": "unset", "lng": "unset"}

    def _fake_search(queries, language, lat=None, lng=None):
        captured["queries"] = queries
        captured["lat"] = lat
        captured["lng"] = lng
        return [
            {"place_id": "G", "name": "경복궁", "rating": 4.7, "distance_m": None,
             "address": "서울 광화문", "location": {"lat": 37.5, "lng": 126.97}},
            {"place_id": "K", "name": "황생가 칼국수", "rating": 4.4, "distance_m": None,
             "address": "서울 북촌", "location": {"lat": 37.58, "lng": 126.98}},
            {"place_id": "C", "name": "떼스 오트", "rating": 4.5, "distance_m": None,
             "address": "서울 북촌", "location": {"lat": 37.58, "lng": 126.99}},
        ]

    monkeypatch.setattr(app, "_search_places", _fake_search)

    # ⭐ lat/lng 를 전혀 보내지 않는다(GPS 꺼짐) — 그래도 지역명으로 동선이 나와야 함.
    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "서울 광화문 갔다가 북촌 갈 건데 밥이랑 구경거리 짜줘",
    }), None)

    body = json.loads(resp["body"])
    assert captured["queries"] == [
        "광화문 경복궁 관광", "광화문 칼국수 맛집", "북촌 카페"]
    assert captured["lat"] is None and captured["lng"] is None   # region → 편향 안 함
    names = [p["place_name"] for p in body["proposed_plan"]]
    assert names == ["경복궁", "황생가 칼국수", "떼스 오트"]       # 관광→식사→카페 섞임·순서
    assert body["proposed_plan"][0]["time_label"] == "오전"


def test_chat_edit_remove(monkeypatch):
    schedules = _FakeTable(query_items=[
        {"trip_id": "demo-trip", "start_time": "t1", "place_name": "A"},
        {"trip_id": "demo-trip", "start_time": "t2", "place_name": "B"},
    ])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"2번 뺐어요","search":"","edits":[{"op":"remove","index":2}]}',
    ]))

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "두 번째 일정 빼줘",
    }), None)

    body = json.loads(resp["body"])
    assert body["edited"] is True
    assert body["reply"] == "2번 뺐어요"
    assert schedules.deleted_keys == [{"trip_id": "demo-trip", "start_time": "t2"}]
    assert [it["place_name"] for it in body["timeline"]] == ["A"]
    assert body["proposed_plan"] == []


def test_chat_reorder(monkeypatch):
    schedules = _FakeTable(query_items=[
        {"trip_id": "demo-trip", "start_time": "t1", "place_name": "A"},
        {"trip_id": "demo-trip", "start_time": "t2", "place_name": "B"},
    ])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"순서 바꿨어요","search":"","edits":[{"op":"reorder","order":[2,1]}]}',
    ]))

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "B를 먼저로 바꿔줘",
    }), None)

    body = json.loads(resp["body"])
    assert body["edited"] is True
    assert [it["place_name"] for it in body["timeline"]] == ["B", "A"]
    assert len(schedules.put_items) == 2


def test_chat_plain_conversation(monkeypatch):
    schedules = _FakeTable(query_items=[])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"몇 시부터 시작해요?","search":"","edits":[]}',
    ]))

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "일정 짜고 싶어",
    }), None)

    body = json.loads(resp["body"])
    assert body["reply"] == "몇 시부터 시작해요?"
    assert body["proposed_plan"] == []
    assert body["edited"] is False
    assert schedules.deleted_keys == []
    assert len(chats.put_items) == 2


def test_chat_safety_net_forces_search(monkeypatch):
    """두뇌가 search 스위치를 놓쳐도(빈 제안), 메시지에 장소 기미+좌표가 있으면
    기본 검색어로 강제해 동선이 비지 않게 한다(간헐적 빈 제안 버그 방지)."""
    schedules = _FakeTable(query_items=[])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"음...","search":"","edits":[]}',
        '{"reply":"이렇게 짜봤어요","proposed_plan":'
        '[{"place_id":"A","time_label":"14:00","reason":"좋음"}]}',
    ]))
    captured = {"queries": None, "lat": "unset"}

    def _fake_search(queries, language, lat=None, lng=None):
        captured["queries"] = queries
        captured["lat"] = lat
        return [{"place_id": "A", "name": "장소 A", "rating": 4.5, "distance_m": 100,
                 "address": "토론토", "location": {"lat": 43.6, "lng": -79.3}}]

    monkeypatch.setattr(app, "_search_places", _fake_search)

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "일정 짜줘",
        "lat": 43.6453, "lng": -79.3806,
    }), None)

    body = json.loads(resp["body"])
    assert captured["queries"] == ["근처 가볼만한 곳"]   # 안전망이 기본 검색어 강제
    assert captured["lat"] == 43.6453                   # region 없음 → 근처 모드(편향)
    assert len(body["proposed_plan"]) == 1


def test_chat_safety_net_skips_when_no_intent_keyword(monkeypatch):
    """장소 기미가 없는 인사말이면 좌표가 있어도 안전망은 발동하지 않는다."""
    schedules = _FakeTable(query_items=[])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    called = {"search": False}

    def _no_search(*a, **k):
        called["search"] = True
        return []

    monkeypatch.setattr(app, "_search_places", _no_search)
    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"천만에요!","search":"","edits":[]}',
    ]))

    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "고마워, 잘 가",
        "lat": 43.6453, "lng": -79.3806,
    }), None)

    body = json.loads(resp["body"])
    assert called["search"] is False
    assert body["proposed_plan"] == []
    assert body["reply"] == "천만에요!"


def test_chat_search_without_location_skips(monkeypatch):
    schedules = _FakeTable(query_items=[])
    chats = _FakeTable(query_items=[])
    _install_tables(monkeypatch, schedules, chats)

    called = {"search": False}

    def _no_search(*a, **k):
        called["search"] = True
        return []

    monkeypatch.setattr(app, "_search_places", _no_search)
    monkeypatch.setattr(app, "_invoke_claude", _fake_claude([
        '{"reply":"좋아요","search":"카페","edits":[]}',
    ]))

    # lat/lng 없고 지역명도 없음 → 검색을 시도하지 않고 '지역을 알려달라' 안내를 덧붙인다.
    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "카페 추천",
    }), None)

    body = json.loads(resp["body"])
    assert called["search"] is False
    assert "지역" in body["reply"]
    assert body["proposed_plan"] == []


def test_chat_missing_message_400(monkeypatch):
    schedules = _FakeTable()
    chats = _FakeTable()
    _install_tables(monkeypatch, schedules, chats)

    resp = app.lambda_handler(_chat({"trip_id": "demo-trip"}), None)
    assert resp["statusCode"] == 400


# ─────────────────────────── 메서드 라우팅 ───────────────────────────
def test_options_preflight():
    resp = app.lambda_handler({"httpMethod": "OPTIONS"}, None)
    assert resp["statusCode"] == 200


def test_unsupported_method():
    resp = app.lambda_handler({"httpMethod": "GET"}, None)
    assert resp["statusCode"] == 405
