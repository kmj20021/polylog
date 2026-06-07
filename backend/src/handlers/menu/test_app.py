"""fn-menu 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/menu/ -q
Bedrock 비전·S3·DynamoDB 는 monkeypatch 로 모킹한다.
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


def _stub_aws(monkeypatch, vision=None):
    """AWS 경계 헬퍼들을 인메모리로 대체. 반환된 dict 로 저장 호출을 관찰한다."""
    saved = {}
    monkeypatch.setattr(app, "_store_image", lambda b, t: f"menus/{t}/x.jpg")
    if vision is not None:
        monkeypatch.setattr(app, "_invoke_claude_vision", vision)
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


# ── 가격 파싱 ────────────────────────────────────────────────
def test_parse_price():
    assert app._parse_price("ラーメン ¥900") == 900
    assert app._parse_price("5,500") == 5500
    assert app._parse_price(900) == 900
    assert app._parse_price("Pasta") is None
    assert app._parse_price(None) is None


# ── 비전이 빈 결과를 주면 안내 메시지 ────────────────────────
def test_empty_menu_returns_message(monkeypatch):
    _stub_aws(monkeypatch, vision=lambda *a, **k: json.dumps({"items": []}))
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert "message" in body


# ── 정상 흐름: 비전 항목+번역+추천 매핑 ──────────────────────
def test_happy_path(monkeypatch):
    vision = lambda prompt, image_bytes, max_tokens=3000: json.dumps({
        "script": "latin",
        "items": [
            {"original": "ラーメン", "translated": "라멘", "price": 900,
             "description": "일본식 라멘"},
            {"original": "天ぷら", "translated": "튀김", "price": "1,200",
             "description": "튀김 요리"},
            {"original": "コーヒー", "translated": "커피", "price": None, "description": ""},
            "not-a-dict",
        ],
        "recommended": [0, 2, 99],   # 99 는 유효 인덱스 아님 → 무시
    })
    saved = _stub_aws(monkeypatch, vision=vision)
    r = app.lambda_handler(_event({
        "image_base64": _PNG_1x1, "trip_id": "demo-trip",
        "dietary_restrictions": ["갑각류"],
    }), None)
    body = json.loads(r["body"])

    assert r["statusCode"] == 200
    assert body["type"] == "result"
    # dict 가 아닌 항목 제외 → 3개
    assert len(body["items"]) == 3
    m0 = body["items"][0]
    assert m0["item_id"] == "m0"
    assert m0["original_name"] == "ラーメン"
    assert m0["translated_name"] == "라멘"
    assert m0["price"] == 900
    assert m0["description"] == "일본식 라멘"
    # 문자열 가격도 정수로 파싱
    assert body["items"][1]["price"] == 1200
    # price 없으면 None, 번역만
    assert body["items"][2]["price"] is None
    assert body["items"][2]["translated_name"] == "커피"
    # 추천: 유효 인덱스만 → m0, m2
    assert body["recommended"] == ["m0", "m2"]
    # 저장 호출됨
    assert saved["trip_id"] == "demo-trip"
    assert len(saved["items"]) == 3


# ── 비라틴(한/일/중) → 분석 대신 구글 렌즈 유도 신호 ─────────
def test_non_latin_returns_unsupported(monkeypatch):
    vision = lambda *a, **k: json.dumps({"script": "non_latin", "language": "일본어"})
    saved = _stub_aws(monkeypatch, vision=vision)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1, "trip_id": "demo-trip"}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["type"] == "unsupported_language"
    assert body["language"] == "일본어"
    assert "items" not in body          # 비라틴은 항목을 만들지 않음
    assert saved == {}                  # 이력 저장도 생략


# ── 비전 실패해도 안전(빈 목록 → 메시지) ─────────────────────
def test_vision_failure_is_safe(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("bedrock down")
    _stub_aws(monkeypatch, vision=boom)
    r = app.lambda_handler(_event({"image_base64": _PNG_1x1}), None)
    body = json.loads(r["body"])
    assert r["statusCode"] == 200
    assert body["items"] == []
    assert body["recommended"] == []
    assert "message" in body


# ── _analyze_menu: 추천 인덱스 필터링 직접 검증 ──────────────
def test_analyze_menu_filters_invalid_recommended(monkeypatch):
    monkeypatch.setattr(app, "_invoke_claude_vision",
                        lambda prompt, image_bytes, max_tokens=3000: json.dumps({
                            "script": "latin",
                            "items": [
                                {"original": "Sushi", "translated": "스시", "price": 1000,
                                 "description": "초밥"},
                                {"original": "Udon", "translated": "우동", "price": 800,
                                 "description": "면"},
                            ],
                            "recommended": [1, 42],   # 42 는 범위 밖 → 제외
                        }))
    script, lang, items, recommended = app._analyze_menu(b"fake-image", [], "ko")
    assert script == "latin"
    assert len(items) == 2
    assert items[0]["item_id"] == "m0"
    assert recommended == ["m1"]   # 42 제외
