"""fn-receipt 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/receipt/ -q
Bedrock 비전·S3·DynamoDB·환율API 는 monkeypatch 로 모킹한다.
(OCR 은 Textract 가 아니라 Bedrock 비전 — 한글/일본어 CJK 를 읽기 위해, 모듈 docstring 참조)
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
    """AWS 경계 헬퍼들을 인메모리로 대체. 반환된 dict 로 저장 호출을 관찰한다.

    vision: _invoke_claude_vision 대체 함수 (signature: prompt, image_bytes, max_tokens=...).
    rate:   _fetch_rate 반환값(None 이면 환율 조회 실패 흉내).
    """
    saved = {}
    monkeypatch.setattr(app, "_store_image", lambda b, t: f"receipts/{t}/x.jpg")
    if vision is not None:
        monkeypatch.setattr(app, "_invoke_claude_vision", vision)
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: rate)
    monkeypatch.setattr(
        app, "_save_receipt",
        lambda trip_id, occurred_at, fields: saved.update(
            {"trip_id": trip_id, "occurred_at": occurred_at, **fields}
        ),
    )
    return saved


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


# ── 환산 로직 ────────────────────────────────────────────────
def test_convert_total_success(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: 9.0)
    krw, note = app._convert_total("3500", "JPY", "KRW")
    assert krw == 31500
    assert note is None


def test_convert_total_no_currency():
    krw, note = app._convert_total("3500", None, "KRW")
    assert krw is None
    assert "통화" in note


def test_convert_total_rate_unavailable(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: None)
    krw, note = app._convert_total("3500", "JPY", "KRW")
    assert krw is None
    assert "환율" in note


def test_convert_total_none_total():
    krw, note = app._convert_total(None, "JPY", "KRW")
    assert krw is None
    assert note is None


def test_convert_total_rounds(monkeypatch):
    monkeypatch.setattr(app, "_fetch_rate", lambda frm, to: 1350.0)
    krw, _ = app._convert_total("12.50", "USD", "KRW")
    assert krw == 16875  # 12.50 * 1350 = 16875


# ── 비전이 빈 결과를 주면 안내 note ──────────────────────────
def test_empty_result_returns_note(monkeypatch):
    _stub_aws(monkeypatch, vision=lambda *a, **k: "{}")
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert body["total_krw"] is None
    assert body["note"]


# ── 정상 흐름: 비전 구조화→환산→저장 ────────────────────────
def test_happy_path(monkeypatch):
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
    saved = _stub_aws(monkeypatch, vision=vision, rate=9.0)
    r = app.lambda_handler(_event({
        "image_base64": _PNG_1x1, "trip_id": "demo-trip", "home_currency": "KRW",
    }), None)
    body = json.loads(r["body"])

    assert r["statusCode"] == 200
    assert body["type"] == "result"
    assert body["merchant"] == "라멘이치란"
    assert body["occurred_at"] == "2026-06-07"
    assert body["currency"] == "JPY"          # 대문자화
    assert body["total"] == "3500"            # 콤마 제거
    assert body["total_krw"] == 31500         # 3500 * 9.0
    assert body["note"] is None
    # 품목: dict 가 아닌 항목은 제외 → 3개
    assert len(body["items"]) == 3
    assert body["items"][0]["item_id"] == "r0"
    assert body["items"][0]["amount"] == "900"
    assert body["items"][1]["category"] == "식비"
    # 허용 목록 밖 카테고리 → '기타'
    assert body["items"][2]["category"] == "기타"
    # 저장 호출됨 (SK = occurred_at)
    assert saved["trip_id"] == "demo-trip"
    assert saved["occurred_at"] == "2026-06-07"
    assert saved["total_krw"] == 31500


# ── 통화 미인식 → 결과는 주되 환산만 비고 note ───────────────
def test_unknown_currency_keeps_result(monkeypatch):
    vision = lambda prompt, image_bytes, max_tokens=2000: json.dumps({
        "merchant": "Café",
        "currency": None,
        "total": "12.50",
        "items": [{"name_ko": "커피", "amount": "12.50", "category": "식비"}],
    })
    _stub_aws(monkeypatch, vision=vision, rate=9.0)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["currency"] is None
    assert body["total"] == "12.50"
    assert body["total_krw"] is None
    assert "통화" in body["note"]


# ── 비전 호출 실패해도 결과 골격은 반환 ──────────────────────
def test_vision_failure_is_safe(monkeypatch):
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
    assert body["occurred_at"]   # now_iso 폴백
    assert body["note"]          # 빈 결과 안내


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
