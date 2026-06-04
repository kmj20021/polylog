"""fn-schedule 단위 테스트 — DynamoDB 는 가짜 테이블로 대체(실 호출 없음).

실행: cd backend && python -m pytest src/handlers/schedule/ -q
"""
import json
from decimal import Decimal

import app


# ─────────────────────────── 가짜 DynamoDB ───────────────────────────
class _FakeTable:
    """put_item 을 기록하고, query 는 미리 정해둔 항목을 돌려주는 가짜 테이블."""

    def __init__(self, query_items=None):
        self.put_items = []
        self._query_items = query_items or []
        self.last_query_kwargs = None

    def put_item(self, Item):
        self.put_items.append(Item)
        return {}

    def query(self, **kwargs):
        self.last_query_kwargs = kwargs
        return {"Items": list(self._query_items)}


class _FakeResource:
    def __init__(self, table):
        self._table = table

    def Table(self, name):
        return self._table


def _install_table(monkeypatch, table):
    monkeypatch.setattr(app, "_dynamodb", _FakeResource(table))


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
    assert a <= b               # 시간순 정렬 가능(문자열 비교 = 시간 비교)
    assert "T" in a             # ISO 8601 형태


# ─────────────────────────── POST ───────────────────────────
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
    assert body["item"]["rating"] == 4.5                 # Decimal → 숫자 환원
    assert body["item"]["source"] == "ai_recommended"
    assert body["item"]["trip_id"] == "demo-trip"

    # 실제 저장된 항목 검증(PK/SK + Decimal 타입)
    assert len(table.put_items) == 1
    stored = table.put_items[0]
    assert stored["trip_id"] == "demo-trip"
    assert stored["start_time"] == stored["created_at"]  # SK = 추가 시각
    assert isinstance(stored["latitude"], Decimal)
    assert "schedule_id" in stored


def test_post_defaults_trip_id(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_post({"name": "편의점 A"}), None)  # name 별칭 + trip_id 생략
    body = json.loads(resp["body"])
    assert body["item"]["trip_id"] == "demo-trip"
    assert body["item"]["title"] == "편의점 A"            # title 생략 → place_name


def test_post_missing_name_400(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    resp = app.lambda_handler(_post({"place_id": "x"}), None)
    assert resp["statusCode"] == 400
    assert table.put_items == []                          # 저장 시도 안 함


def test_post_omits_empty_fields(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)

    app.lambda_handler(_post({"place_name": "공원"}), None)  # 좌표/주소/평점 없음
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
    assert body["items"][0]["place_name"] == "A"
    assert body["items"][0]["latitude"] == 35.6          # Decimal 환원
    assert body["items"][1]["rating"] == 4.5
    # 오름차순(시간순) 조회를 요청했는지
    assert table.last_query_kwargs["ScanIndexForward"] is True


def test_get_defaults_trip_id(monkeypatch):
    table = _FakeTable(query_items=[])
    _install_table(monkeypatch, table)

    resp = app.lambda_handler({"httpMethod": "GET", "queryStringParameters": None}, None)
    body = json.loads(resp["body"])
    assert body["trip_id"] == "demo-trip"
    assert body["count"] == 0


# ─────────────────────────── 메서드 라우팅 ───────────────────────────
def test_options_preflight(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)
    resp = app.lambda_handler({"httpMethod": "OPTIONS"}, None)
    assert resp["statusCode"] == 200


def test_unsupported_method(monkeypatch):
    table = _FakeTable()
    _install_table(monkeypatch, table)
    resp = app.lambda_handler({"httpMethod": "DELETE"}, None)
    assert resp["statusCode"] == 405
