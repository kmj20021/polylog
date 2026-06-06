"""fn-menu 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/menu/ -q
Textract·Bedrock·S3·DynamoDB 는 monkeypatch 로 모킹한다.
(번역은 Amazon Translate 대신 Bedrock 이 담당 — _analyze_menu)
"""
import base64
import json

import app


def _event(body, method="POST"):
    return {"httpMethod": method, "body": json.dumps(body)}


# 1x1 PNG (디코드 성공용 더미 — 실제 OCR 는 monkeypatch 로 대체).
_PNG_1x1 = base64.b64encode(bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000a49444154789c6300010000050001"
)).decode()


def _stub_aws(monkeypatch, lines, claude=None):
    """AWS 경계 헬퍼들을 인메모리로 대체. 반환된 dict 로 저장 호출을 관찰한다."""
    saved = {}
    monkeypatch.setattr(app, "_store_image", lambda b, t: f"menus/{t}/x.jpg")
    monkeypatch.setattr(app, "_ocr_lines", lambda b: list(lines))
    if claude is not None:
        monkeypatch.setattr(app, "_invoke_claude", claude)
    monkeypatch.setattr(
        app, "_save_menu",
        lambda *a: saved.update(zip(
            ("trip_id", "created_at", "menu_id", "photo_s3_key", "items", "recommended"), a,
        )),
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


# ── 가격 파싱 ────────────────────────────────────────────────
def test_parse_price():
    assert app._parse_price("ラーメン ¥900") == 900
    assert app._parse_price("불고기 5,500원") == 5500
    assert app._parse_price("Pasta") is None
    assert app._parse_price("") is None


# ── base64 data URI 접두사 허용 ──────────────────────────────
def test_decode_image_data_uri_prefix():
    raw = "data:image/png;base64," + _PNG_1x1
    assert app._decode_image(raw) == base64.b64decode(_PNG_1x1)


# ── OCR 결과가 빈 경우 ───────────────────────────────────────
def test_empty_ocr_returns_message(monkeypatch):
    _stub_aws(monkeypatch, lines=[])
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert "message" in body


# ── 정상 흐름: OCR→Bedrock(번역+설명+추천) 매핑 ──────────────
def test_happy_path(monkeypatch):
    claude = lambda p, max_tokens=3000: json.dumps({
        "items": {
            "m0": {"translated": "라멘", "description": "일본식 라멘"},
            "m1": {"translated": "튀김", "description": "튀김 요리"},
            "ghost": {"translated": "유령", "description": "무시돼야 함"},
        },
        "recommended": ["m0", "m2", "bogus"],   # bogus 는 무시돼야 함
    })
    saved = _stub_aws(
        monkeypatch,
        lines=["ラーメン ¥900", "天ぷら ¥1200", "コーヒー ¥400"],
        claude=claude,
    )
    r = app.lambda_handler(_event({
        "image_base64": _PNG_1x1, "trip_id": "demo-trip",
        "dietary_restrictions": ["갑각류"],
    }), None)
    body = json.loads(r["body"])

    assert r["statusCode"] == 200
    assert body["type"] == "result"
    assert len(body["items"]) == 3
    # m0: Bedrock 번역·설명이 덮어쓰고, 가격은 원문에서 파싱
    m0 = body["items"][0]
    assert m0["item_id"] == "m0"
    assert m0["original_name"] == "ラーメン ¥900"
    assert m0["translated_name"] == "라멘"
    assert m0["price"] == 900
    assert m0["description"] == "일본식 라멘"
    # m2: Bedrock 이 안 준 항목 → 원문으로 폴백, 설명 빈 값
    m2 = body["items"][2]
    assert m2["translated_name"] == "コーヒー ¥400"
    assert m2["description"] == ""
    # 추천: 유효 id 만(bogus 제외)
    assert body["recommended"] == ["m0", "m2"]
    # 저장 호출됨
    assert saved["trip_id"] == "demo-trip"
    assert len(saved["items"]) == 3


# ── Bedrock 실패해도 원문 목록은 반환(번역·추천만 빔) ────────
def test_bedrock_failure_is_safe(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("bedrock down")
    _stub_aws(monkeypatch, lines=["スシ", "うどん"], claude=boom)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert len(body["items"]) == 2
    assert body["recommended"] == []
    # 번역 실패 → translated_name 은 원문과 동일, 설명은 빈 값
    assert all(it["translated_name"] == it["original_name"] for it in body["items"])
    assert all(it["description"] == "" for it in body["items"])


# ── _analyze_menu: 유효 id 필터링 직접 검증 ──────────────────
def test_analyze_menu_filters_invalid_ids(monkeypatch):
    items = [
        {"item_id": "m0", "original_name": "Sushi"},
        {"item_id": "m1", "original_name": "Udon"},
    ]
    monkeypatch.setattr(app, "_invoke_claude", lambda p, max_tokens=3000: json.dumps({
        "items": {
            "m0": {"translated": "스시", "description": "초밥"},
            "m99": {"translated": "없는항목", "description": "무시"},
        },
        "recommended": ["m1", "m42"],
    }))
    translations, descriptions, recommended = app._analyze_menu(items, [], "ko")
    assert translations == {"m0": "스시"}
    assert descriptions == {"m0": "초밥"}
    assert recommended == ["m1"]   # m42 는 유효 id 아님 → 제외


# ── 5MB 초과 이미지 거부 ─────────────────────────────────────
def test_oversize_image_rejected(monkeypatch):
    big = base64.b64encode(b"x" * (app._MAX_IMAGE_BYTES + 1)).decode()
    r = app.lambda_handler(_event({"image_base64": big}), None)
    assert r["statusCode"] == 413
