"""fn-receipt 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/receipt/ -q
Bedrock 비전·S3·DynamoDB·환율API 는 monkeypatch 로 모킹한다.
(OCR 은 Textract 가 아니라 Bedrock 비전 — 한글/일본어 CJK 를 읽기 위해, 모듈 docstring 참조)

이 핸들러는 POST /receipt 에 action(analyze/list/update/delete)으로 분기한다(새 라우트 회피).
"""
import base64
import json

import app


def _event(body, method="POST"):
    return {"httpMethod": method, "body": json.dumps(body)}


# 1x1 PNG (디코드 성공용 더미 — 실제 비전 호출은 monkeypatch 로 대체).
_PNG_1x1 = base64.b64encode(bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000a49444154789c6300010000050001"
)).decode()


def _stub_aws(monkeypatch, vision=None, rate=None):
    """AWS 경계 헬퍼들을 인메모리로 대체.

    반환된 store 리스트로 put/delete 호출을 관찰한다(저장된 레코드는 store["puts"]).
    vision: _invoke_claude_vision 대체 (signature: prompt, image_bytes, max_tokens=...).
    rate:   _fetch_rate 반환값(None 이면 환율 조회 실패 흉내).
    """
    store = {"puts": [], "deletes": []}
    monkeypatch.setattr(app, "_store_image", lambda b, t: f"receipts/{t}/x.jpg")
    if vision is not None:
        monkeypatch.setattr(app, "_invoke_claude_vision", vision)
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: rate)
    monkeypatch.setattr(app, "_put_receipt", lambda rec: store["puts"].append(rec))
    monkeypatch.setattr(app, "_delete_receipt",
                        lambda trip_id, sk: store["deletes"].append((trip_id, sk)))
    return store


# ── 입력 검증 ────────────────────────────────────────────────
def test_options_preflight():
    r = app.lambda_handler({"httpMethod": "OPTIONS"}, None)
    assert r["statusCode"] == 200


def test_bad_json_body():
    r = app.lambda_handler({"httpMethod": "POST", "body": "{not json"}, None)
    assert r["statusCode"] == 400


def test_missing_image():
    r = app.lambda_handler(_event({"trip_id": "demo-trip"}), None)
    assert r["statusCode"] == 400


def test_bad_base64():
    r = app.lambda_handler(_event({"image_base64": "@@@not base64@@@"}), None)
    assert r["statusCode"] == 400


def test_oversize_image_rejected():
    big = base64.b64encode(b"x" * (app._MAX_IMAGE_BYTES + 1)).decode()
    r = app.lambda_handler(_event({"image_base64": big}), None)
    assert r["statusCode"] == 413


def test_decode_image_data_uri_prefix():
    raw = "data:image/png;base64," + _PNG_1x1
    assert app._decode_image(raw) == base64.b64decode(_PNG_1x1)


def test_media_type_png_vs_jpeg():
    png = base64.b64decode(_PNG_1x1)
    assert app._media_type(png) == "image/png"
    assert app._media_type(b"\xff\xd8\xff\xe0jpegdata") == "image/jpeg"


# ── 금액/통화 정규화 ─────────────────────────────────────────
def test_clean_amount():
    assert app._clean_amount("¥1,200") == "1200"
    assert app._clean_amount("12.50") == "12.50"
    assert app._clean_amount(1200) == "1200"
    assert app._clean_amount("free") is None
    assert app._clean_amount("") is None
    assert app._clean_amount(None) is None
    assert app._clean_amount(".") is None


def test_clean_currency():
    assert app._clean_currency("jpy") == "JPY"
    assert app._clean_currency("USD") == "USD"
    assert app._clean_currency("¥") is None
    assert app._clean_currency("") is None
    assert app._clean_currency(None) is None
    assert app._clean_currency("YENS") is None  # 3자 아님


# ── SK 고유화 / 응답 매핑 ────────────────────────────────────
def test_make_sk_unique_per_receipt():
    a = app._make_sk("2026-06-07", "id-1")
    b = app._make_sk("2026-06-07", "id-2")
    assert a != b               # 같은 날이어도 고유
    assert a.startswith("2026-06-07#")  # 날짜순 정렬 유지


def test_to_response_maps_sk_and_date():
    rec = {
        "trip_id": "t", "occurred_at": "2026-06-07#id-1", "display_date": "2026-06-07",
        "receipt_id": "id-1", "merchant": "M", "currency": "JPY", "total": "900",
        "total_krw": 8100, "rate": "9.0000", "home_currency": "KRW",
        "items": [{"item_id": "r0", "name_ko": "라멘", "amount": "900",
                   "amount_krw": 8100, "category": "식비"}],
    }
    out = app._to_response(rec)
    assert out["sk"] == "2026-06-07#id-1"   # update/delete 키
    assert out["occurred_at"] == "2026-06-07"  # 표시용 깔끔한 날짜
    assert out["rate"] == "9.0000"


def test_to_response_legacy_row_without_display_date():
    # 옛 행(‘#’ 없는 SK, display_date 없음)도 깨지지 않게 유추.
    out = app._to_response({"occurred_at": "2026-01-02", "receipt_id": "x"})
    assert out["sk"] == "2026-01-02"
    assert out["occurred_at"] == "2026-01-02"


# ── 환산 로직(_apply_conversion) — 합계+품목별+환율명시 ──────
def test_apply_conversion_success(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: 9.0)
    items = [{"item_id": "r0", "name_ko": "라멘", "amount": "900", "category": "식비"}]
    total_krw, rate, out_items, note = app._apply_conversion("JPY", "3500", items, "KRW")
    assert total_krw == 31500          # 3500 * 9
    assert rate == "9.0000"            # 적용 환율 명시(문자열)
    assert out_items[0]["amount_krw"] == 8100  # 900 * 9
    assert note is None


def test_apply_conversion_no_currency():
    total_krw, rate, out_items, note = app._apply_conversion(
        None, "3500", [{"amount": "900"}], "KRW")
    assert total_krw is None
    assert rate is None
    assert out_items[0]["amount_krw"] is None
    assert "통화" in note


def test_apply_conversion_rate_unavailable(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: None)
    total_krw, rate, out_items, note = app._apply_conversion(
        "JPY", "3500", [{"amount": "900"}], "KRW")
    assert total_krw is None
    assert rate is None
    assert out_items[0]["amount_krw"] is None
    assert "환율" in note


def test_apply_conversion_none_total(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: 9.0)
    total_krw, rate, out_items, note = app._apply_conversion(
        "JPY", None, [{"amount": "900"}], "KRW")
    assert total_krw is None           # 합계가 없으면 환산 없음
    assert rate == "9.0000"
    assert out_items[0]["amount_krw"] == 8100  # 품목은 환산됨
    assert note is None


def test_apply_conversion_rounds(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: 1350.0)
    total_krw, _, _, _ = app._apply_conversion("USD", "12.50", [], "KRW")
    assert total_krw == 16875          # 12.50 * 1350


# ── action: analyze — 비전 구조화→환산→저장 ─────────────────
def test_analyze_happy_path(monkeypatch):
    vision = lambda prompt, image_bytes, max_tokens=2000: json.dumps({
        "merchant": "라멘이치란",
        "occurred_at": "2026-06-07",
        "currency": "jpy",
        "total": "3,500",
        "items": [
            {"name_ko": "돈코츠 라멘", "amount": "¥900", "category": "식비"},
            {"name_ko": "교자", "amount": "500", "category": "식비"},
            {"name_ko": "이상한카테고리", "amount": "100", "category": "우주여행"},
            "not-a-dict",
        ],
    })
    store = _stub_aws(monkeypatch, vision=vision, rate=9.0)
    r = app.lambda_handler(_event({
        "image_base64": _PNG_1x1, "trip_id": "demo-trip", "home_currency": "KRW",
    }), None)
    body = json.loads(r["body"])

    assert r["statusCode"] == 200
    assert body["merchant"] == "라멘이치란"
    assert body["occurred_at"] == "2026-06-07"   # 표시용 날짜
    assert body["currency"] == "JPY"             # 대문자화
    assert body["total"] == "3500"               # 콤마 제거
    assert body["total_krw"] == 31500            # 3500 * 9.0
    assert body["rate"] == "9.0000"              # 적용 환율 명시
    assert body["note"] is None
    assert body["sk"].startswith("2026-06-07#")  # 고유 SK
    # 품목: dict 가 아닌 항목 제외 → 3개, 원화 환산 포함
    assert len(body["items"]) == 3
    assert body["items"][0]["item_id"] == "r0"
    assert body["items"][0]["amount"] == "900"
    assert body["items"][0]["amount_krw"] == 8100
    assert body["items"][2]["category"] == "기타"  # 허용 밖 → 기타
    # 저장: SK 는 날짜#receipt_id, display_date 따로
    rec = store["puts"][0]
    assert rec["occurred_at"].startswith("2026-06-07#")
    assert rec["display_date"] == "2026-06-07"
    assert rec["total_krw"] == 31500


def test_analyze_unknown_currency_keeps_result(monkeypatch):
    vision = lambda prompt, image_bytes, max_tokens=2000: json.dumps({
        "merchant": "Café", "currency": None, "total": "12.50",
        "items": [{"name_ko": "커피", "amount": "12.50", "category": "식비"}],
    })
    _stub_aws(monkeypatch, vision=vision, rate=9.0)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["currency"] is None
    assert body["total"] == "12.50"
    assert body["total_krw"] is None
    assert body["rate"] is None
    assert "통화" in body["note"]


def test_analyze_empty_result_returns_note(monkeypatch):
    _stub_aws(monkeypatch, vision=lambda *a, **k: "{}")
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert body["total_krw"] is None
    assert body["note"]
    assert body["occurred_at"]   # 날짜 폴백(오늘)


def test_analyze_vision_failure_is_safe(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("bedrock down")
    _stub_aws(monkeypatch, vision=boom, rate=9.0)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert body["currency"] is None
    assert body["total"] is None
    assert body["total_krw"] is None
    assert body["occurred_at"]   # 오늘 날짜 폴백
    assert body["note"]


# ── action: list ────────────────────────────────────────────
def test_list_returns_receipts_newest_first(monkeypatch):
    # _query_receipts 는 SK 오름차순 → 핸들러가 뒤집어 최신 우선으로 준다.
    rows = [
        {"occurred_at": "2026-06-05#a", "display_date": "2026-06-05",
         "receipt_id": "a", "merchant": "A", "total_krw": 100, "items": []},
        {"occurred_at": "2026-06-07#b", "display_date": "2026-06-07",
         "receipt_id": "b", "merchant": "B", "total_krw": 200, "items": []},
    ]
    monkeypatch.setattr(app, "_query_receipts", lambda trip_id: rows)
    r = app.lambda_handler(_event({"action": "list", "trip_id": "demo-trip"}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["type"] == "list"
    assert [x["receipt_id"] for x in body["receipts"]] == ["b", "a"]  # 최신 우선
    assert body["receipts"][0]["sk"] == "2026-06-07#b"


# ── action: update — 보정 영속, 환율 재계산 ─────────────────
def test_update_recomputes_and_persists(monkeypatch):
    store = _stub_aws(monkeypatch, rate=10.0)
    r = app.lambda_handler(_event({
        "action": "update", "trip_id": "demo-trip", "receipt_id": "id-1",
        "sk": "2026-06-07#id-1", "occurred_at": "2026-06-07",
        "merchant": "수정가게", "currency": "jpy", "total": "1000",
        "home_currency": "KRW", "photo_s3_key": "receipts/demo-trip/x.jpg",
        "items": [
            {"item_id": "r0", "name_ko": "교자", "amount": "1000", "category": "교통"},
            {"name_ko": "팁", "amount": "abc", "category": "없는카테고리"},
        ],
    }), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["type"] == "updated"
    assert body["total_krw"] == 10000        # 1000 * 10 재계산
    assert body["rate"] == "10.0000"
    assert body["items"][0]["amount_krw"] == 10000
    assert body["items"][0]["category"] == "교통"   # 사용자 보정 반영
    assert body["items"][1]["amount"] is None        # 'abc' → None
    assert body["items"][1]["category"] == "기타"    # 허용 밖 → 기타
    # SK 동일(날짜 안 바뀜) → delete 호출 없음
    assert store["deletes"] == []
    assert store["puts"][0]["occurred_at"] == "2026-06-07#id-1"


def test_update_date_change_deletes_old_sk(monkeypatch):
    store = _stub_aws(monkeypatch, rate=10.0)
    r = app.lambda_handler(_event({
        "action": "update", "trip_id": "demo-trip", "receipt_id": "id-1",
        "sk": "2026-06-07#id-1",          # 원래 날짜
        "occurred_at": "2026-06-09",       # 사용자가 날짜 변경
        "currency": "JPY", "total": "1000", "items": [],
    }), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["sk"] == "2026-06-09#id-1"        # 새 SK
    # 옛 SK 행 삭제됨
    assert ("demo-trip", "2026-06-07#id-1") in store["deletes"]


def test_update_requires_keys():
    r = app.lambda_handler(_event({"action": "update", "trip_id": "demo-trip"}), None)
    assert r["statusCode"] == 400


# ── action: delete ──────────────────────────────────────────
def test_delete(monkeypatch):
    store = _stub_aws(monkeypatch)
    r = app.lambda_handler(_event({
        "action": "delete", "trip_id": "demo-trip", "sk": "2026-06-07#id-1",
    }), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["type"] == "deleted"
    assert ("demo-trip", "2026-06-07#id-1") in store["deletes"]


def test_delete_requires_sk():
    r = app.lambda_handler(_event({"action": "delete", "trip_id": "demo-trip"}), None)
    assert r["statusCode"] == 400


# ── _analyze_receipt: 직접 구조화 검증(이미지 입력) ──────────
def test_analyze_receipt_structures(monkeypatch):
    monkeypatch.setattr(app, "_invoke_claude_vision",
                        lambda prompt, image_bytes, max_tokens=2000: json.dumps({
                            "merchant": "Shop",
                            "occurred_at": "2026-01-02",
                            "currency": "EUR",
                            "total": "20.00",
                            "items": [{"name_ko": "기념품", "amount": "20.00", "category": "쇼핑"}],
                        }))
    out = app._analyze_receipt(b"fake-image-bytes", "KRW")
    assert out["currency"] == "EUR"
    assert out["total"] == "20.00"
    assert out["items"][0]["item_id"] == "r0"
    assert out["items"][0]["category"] == "쇼핑"


def test_analyze_receipt_failure_returns_empty(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("down")
    monkeypatch.setattr(app, "_invoke_claude_vision", boom)
    out = app._analyze_receipt(b"fake", "KRW")
    assert out["items"] == []
    assert out["currency"] is None
