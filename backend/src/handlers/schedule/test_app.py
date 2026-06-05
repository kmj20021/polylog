"""fn-schedule 단위 테스트 — DynamoDB/Bedrock/Places 를 가짜로 대체(실 호출 없음).

실행: cd backend && python -m pytest src/handlers/schedule/ -q
"""
import json
from decimal import Decimal

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
    """이름→테이블 매핑. 매핑에 없으면 default 를 돌려준다(단일 테이블 테스트 호환)."""

    def __init__(self, default, tables=None):
        self._default = default
        self._tables = tables or {}

    def Table(self, name):
        return self._tables.get(name, self._default)


def _install_table(monkeypatch, table):
    """단일 테이블(POST/GET/DELETE 테스트용) — 모든 이름이 같은 table 을 가리킨다."""
    monkeypatch.setattr(app, "_dynamodb", _FakeResource(table))


def _install_tables(monkeypatch, schedules, chats):
    """대화 플래너 테스트용 — schedules/chats 를 분리해 설치."""
    monkeypatch.setattr(app, "_dynamodb", _FakeResource(
        schedules, {"polylog-schedules": schedules, "polylog-chats": chats}))


def _fake_claude(responses):
    """_invoke_claude 를 호출 순서대로 미리 정한 문자열을 돌려주도록 대체."""
    seq = iter(responses)

    def _inner(prompt, max_tokens, model_id=None):
        return next(seq)

    return _inner


# ─────────────────────────── 순수 헬퍼 ───────────────────────────
def test_num_converts_and_rejects():
    assert app._num(35.69) == Decimal("35.69")
    assert app._num("4.5") == Decimal("4.5")
    assert app._num(None) is None
    assert app._num("") is None
    assert app._num("abc") is None


def test_clean_trims_and_handles_none():
    assert app._clean("  hi  ") == "hi"
    assert app._clean(None) == ""
    assert app._clean(123) == "123"


def test_json_safe_decimal_to_number():
    out = app._json_safe({"a": Decimal("4"), "b": Decimal("4.5"), "c": [Decimal("1")]})
    assert out == {"a": 4, "b": 4.5, "c": [1]}
    assert isinstance(out["a"], int)
    assert isinstance(out["b"], float)


def test_parse_body_variants():
    assert app._parse_body({"body": '{"x":1}'}) == {"x": 1}
    assert app._parse_body({"body": {"x": 1}}) == {"x": 1}
    assert app._parse_body({"body": None}) == {}
    assert app._parse_body({"body": "not json"}) == {}


def test_now_iso_unique_and_sortable():
    a = app._now_iso()
    b = app._now_iso()
    assert a <= b
    assert "T" in a


def test_safe_json_extracts_object():
    assert app._safe_json('잡설 {"a":1} 더 잡설') == {"a": 1}
    assert app._safe_json("코드펜스 없음") == {}
    assert app._safe_json("") == {}


def test_schedule_text_numbers_items():
    txt = app._schedule_text([
        {"place_name": "A", "time_label": "14:00"},
        {"place_name": "B"},
    ])
    assert "1. A (14:00)" in txt
    assert "2. B" in txt
    assert app._schedule_text([]) == "(아직 일정 없음)"


# ─────────────────────────── POST(담기) ───────────────────────────
def _post(body):
    return {"httpMethod": "POST", "body": json.dumps(body)}


def test_post_adds_item(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_post({
        "trip_id": "demo-trip",
        "place_name": "스타벅스 신주쿠점",
        "place_id": "ChIJabc",
        "latitude": 35.69, "longitude": 139.70,
        "rating": 4.5,
        "address": "도쿄도 신주쿠구",
    }), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["type"] == "added"
    assert body["item"]["place_name"] == "스타벅스 신주쿠점"
    assert body["item"]["rating"] == 4.5
    assert body["item"]["trip_id"] == "demo-trip"

    stored = table.put_items[0]
    assert stored["start_time"] == stored["created_at"]
    assert isinstance(stored["latitude"], Decimal)


def test_post_stores_time_label(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    app.lambda_handler(_post({"place_name": "카페", "time_label": "14:00"}), None)
    assert table.put_items[0]["time_label"] == "14:00"


def test_post_defaults_trip_id(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_post({"name": "편의점 A"}), None)
    body = json.loads(resp["body"])
    assert body["item"]["trip_id"] == "demo-trip"
    assert body["item"]["title"] == "편의점 A"


def test_post_missing_name_400(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_post({"place_id": "x"}), None)
    assert resp["statusCode"] == 400
    assert table.put_items == []


def test_post_omits_empty_fields(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    app.lambda_handler(_post({"place_name": "공원"}), None)
    stored = table.put_items[0]
    assert "latitude" not in stored
    assert "rating" not in stored
    assert "address" not in stored


# ─────────────────────────── GET ───────────────────────────
def test_get_returns_timeline(monkeypatch):
    items = [
        {"trip_id": "demo-trip", "start_time": "2026-06-04T01:00:00+00:00",
         "place_name": "A", "latitude": Decimal("35.6")},
        {"trip_id": "demo-trip", "start_time": "2026-06-04T02:00:00+00:00",
         "place_name": "B", "rating": Decimal("4.5")},
    ]
    table = _FakeTable(query_items=items)
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(
        {"httpMethod": "GET", "queryStringParameters": {"trip_id": "demo-trip"}}, None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["type"] == "timeline"
    assert body["count"] == 2
    assert body["items"][0]["latitude"] == 35.6
    assert body["items"][1]["rating"] == 4.5
    assert table.last_query_kwargs["ScanIndexForward"] is True


def test_get_defaults_trip_id(monkeypatch):
    table = _FakeTable(query_items=[])
    _install_table(monkeypatch, table)

    resp = app.lambda_handler({"httpMethod": "GET", "queryStringParameters": None}, None)
    body = json.loads(resp["body"])
    assert body["trip_id"] == "demo-trip"
    assert body["count"] == 0


# ─────────────────────────── DELETE ───────────────────────────
def _delete(body=None, qs=None):
    return {
        "httpMethod": "DELETE",
        "body": json.dumps(body) if body is not None else None,
        "queryStringParameters": qs,
    }


def test_delete_removes_item(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_delete({
        "trip_id": "demo-trip",
        "start_time": "2026-06-05T01:00:00.123456+00:00",
    }), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["type"] == "deleted"
    assert table.deleted_keys == [
        {"trip_id": "demo-trip", "start_time": "2026-06-05T01:00:00.123456+00:00"}
    ]


def test_delete_accepts_query_string(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(
        _delete(qs={"trip_id": "demo-trip", "start_time": "2026-06-05T02:00:00+00:00"}),
        None)
    assert resp["statusCode"] == 200
    assert table.deleted_keys[0]["start_time"] == "2026-06-05T02:00:00+00:00"


def test_delete_missing_start_time_400(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_delete({"trip_id": "demo-trip"}), None)
    assert resp["statusCode"] == 400
    assert table.deleted_keys == []


# ═══════════════════════════ 대화형 플래너(action="chat") ═══════════════════════════
def _chat(body):
    return {"httpMethod": "POST", "body": json.dumps({**body, "action": "chat"})}


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
    # Places 후보(검색 결과)를 가짜로
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
    # 2번(start_time=t2) 삭제됨, 타임라인엔 A만 남음
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
    # 재배치 후 타임라인 순서가 B, A
    assert [it["place_name"] for it in body["timeline"]] == ["B", "A"]
    # 재기록(delete 후 put)이 일어남
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

    # lat/lng 없음 → 검색을 시도하지 않고 안내 문구를 덧붙인다.
    resp = app.lambda_handler(_chat({
        "trip_id": "demo-trip", "message": "카페 추천",
    }), None)

    body = json.loads(resp["body"])
    assert called["search"] is False
    assert "위치" in body["reply"]
    assert body["proposed_plan"] == []


def test_chat_missing_message_400(monkeypatch):
    schedules = _FakeTable()
    chats = _FakeTable()
    _install_tables(monkeypatch, schedules, chats)

    resp = app.lambda_handler(_chat({"trip_id": "demo-trip"}), None)
    assert resp["statusCode"] == 400


# ─────────────────────────── 메서드 라우팅 ───────────────────────────
def test_options_preflight(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)
    resp = app.lambda_handler({"httpMethod": "OPTIONS"}, None)
    assert resp["statusCode"] == 200


def test_unsupported_method(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)
    resp = app.lambda_handler({"httpMethod": "PUT"}, None)
    assert resp["statusCode"] == 405
