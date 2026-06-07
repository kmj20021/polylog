"""fn-menu — 메뉴판 사진을 Bedrock 비전으로 직접 읽어 번역 + AI 추천 (서브1).

POST /menu
입력: {"trip_id":"demo-trip",
       "image_base64":"<JPEG/PNG base64 (data URI 접두사 허용)>",
       "language":"ko",                 # 번역 목표 언어(기본 ko)
       "dietary_restrictions":["갑각류"]} # (선택) 알레르기·식이 제한

응답:
  {"type":"result","menu_id":"<uuid>","photo_s3_key":"menus/.../x.jpg",
   "items":[{"item_id":"m0","original_name":"ラーメン","translated_name":"라멘",
             "price":900,"description":"<AI 한 줄 설명>"}, ...],
   "recommended":["m0","m2"]}            # 식이 제한 제외한 추천 item_id

설계 요지(왜 이렇게 했나):
- ⭐ OCR 을 **Amazon Textract 가 아니라 Bedrock(Claude Haiku) 비전**으로 한다. Textract 의
  DetectDocumentText 는 라틴 문자(EN/ES/FR/DE/IT/PT)만 읽고 **한글·일본어(CJK)를 못 읽어**
  비라틴 메뉴판이 통째로 실패했다. Claude 비전은 사진을 직접 읽어 모든 언어를 처리하고,
  읽기·번역·설명·추천을 **한 콜**로 끝낸다(B-3 교훈의 연장 — Bedrock 에 맡긴다).
- 프론트가 아직 없어 **base64 인라인 이미지**를 한 POST 로 받는다(presigned 왕복 없이 curl 검증).
- 사진은 받는 즉시 polylog-media 에 SSE 로 보관. 저장 실패해도 분석 결과는 반환.
- Bedrock 에는 JSON 만 받도록 요청하고 방어적으로 파싱 → 실패해도 빈 목록으로 안전하게 처리.

리전: S3·DynamoDB = ap-northeast-2(서울), Bedrock(Haiku) = us-east-1.
권한은 공용 역할 SafeRole-polylog(Bedrock·S3·DynamoDB) — 환경변수 불필요.
boto3 는 Lambda 런타임 내장 → 배포 패키지 의존성 0.
"""
import base64
import binascii
import json
import uuid
from datetime import datetime, timezone

import boto3

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨(멀티모달 — 사진을 직접 읽음).
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

# 저장은 서울 리전.
_s3 = boto3.client("s3", region_name="ap-northeast-2")
_menus_table = boto3.resource("dynamodb", region_name="ap-northeast-2").Table("polylog-menus")

_MEDIA_BUCKET = "polylog-media"
_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 비전 입력 이미지 상한(요청 크기·비용 보호)

_CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def lambda_handler(event, context):
    # CORS preflight
    if (event.get("httpMethod") or "").upper() == "OPTIONS":
        return _resp(200, {})

    try:
        body = json.loads(event.get("body") or "{}")
    except (TypeError, ValueError):
        return _resp(400, {"error": "본문이 올바른 JSON이 아닙니다."})

    raw_b64 = body.get("image_base64") or ""
    if not raw_b64:
        return _resp(400, {"error": "image_base64 는 필수입니다."})

    image_bytes = _decode_image(raw_b64)
    if image_bytes is None:
        return _resp(400, {"error": "image_base64 디코드에 실패했습니다(올바른 base64 인지 확인)."})
    if len(image_bytes) > _MAX_IMAGE_BYTES:
        return _resp(413, {"error": "이미지가 5MB 를 초과합니다. 더 작게 촬영해 주세요."})

    trip_id = (body.get("trip_id") or "demo-trip").strip()
    language = (body.get("language") or "ko").strip()
    dietary = body.get("dietary_restrictions") or []

    # 1) 원본 보관(실패해도 분석은 계속).
    photo_s3_key = _store_image(image_bytes, trip_id)

    # 2) Bedrock 비전 한 콜로 사진에서 직접 항목 추출 + 번역 + 설명 + 추천.
    items, recommended = _analyze_menu(image_bytes, dietary, language)

    menu_id = str(uuid.uuid4())

    if not items:
        return _resp(200, {
            "type": "result",
            "menu_id": menu_id,
            "photo_s3_key": photo_s3_key,
            "items": [],
            "recommended": [],
            "message": "사진에서 메뉴를 읽지 못했어요. 더 또렷하게 다시 촬영해 주세요.",
        })

    created_at = _now_iso()

    # 3) 이력 저장(polylog-menus). 실패해도 결과는 그대로 반환.
    _save_menu(trip_id, created_at, menu_id, photo_s3_key, items, recommended)

    return _resp(200, {
        "type": "result",
        "menu_id": menu_id,
        "photo_s3_key": photo_s3_key,
        "items": items,
        "recommended": recommended,
    })


# ──────────────────────────────────────────────────────────────
# 입력 처리
# ──────────────────────────────────────────────────────────────
def _decode_image(raw_b64):
    """data URI 접두사를 떼고 base64 디코드. 실패 시 None."""
    s = raw_b64.strip()
    if s.startswith("data:"):
        comma = s.find(",")
        if comma != -1:
            s = s[comma + 1:]
    try:
        return base64.b64decode(s, validate=False)
    except (binascii.Error, ValueError):
        return None


def _media_type(image_bytes):
    """매직바이트로 PNG/JPEG 판별(Bedrock 이미지 블록의 media_type). 기본 jpeg."""
    if image_bytes[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    return "image/jpeg"


def _parse_price(value):
    """가격 값에서 숫자만 뽑아 정수로. 없으면 None.

    예) 'ラーメン ¥900' → 900, '5,500' → 5500, 900(int) → 900. (통화기호·콤마·점 무시)
    DynamoDB float 회피 위해 정수로 둔다.
    """
    if value is None:
        return None
    digits = "".join(ch for ch in str(value) if ch.isdigit())
    if not digits:
        return None
    try:
        return int(digits)
    except ValueError:
        return None


# ──────────────────────────────────────────────────────────────
# AWS 부품(각각 단위테스트에서 monkeypatch 대상)
# ──────────────────────────────────────────────────────────────
def _store_image(image_bytes, trip_id):
    """원본 이미지를 polylog-media 에 SSE 로 저장하고 s3 key 반환. 실패하면 빈 문자열."""
    key = f"menus/{trip_id}/{uuid.uuid4()}.jpg"
    try:
        _s3.put_object(
            Bucket=_MEDIA_BUCKET,
            Key=key,
            Body=image_bytes,
            ContentType="image/jpeg",
            ServerSideEncryption="AES256",
        )
        return key
    except Exception:
        return ""


def _analyze_menu(image_bytes, dietary, language):
    """Bedrock(Claude Haiku 비전) 한 콜로 메뉴판 사진을 직접 읽어 항목+번역+설명+추천.

    반환: (items list[dict], recommended list[str])
      items: [{item_id, original_name, translated_name, price(int|None), description}]
      recommended: 식이 제한을 피한 추천 item_id (최대 4개)
    실패하면 ([], []) — 호출부가 안내 메시지를 반환.

    Textract 대신 비전을 쓰는 이유는 모듈 상단 docstring 참조(CJK OCR 불가 → 한글/일본어 메뉴 실패).
    """
    lang_label = {"ko": "한국어", "en": "영어", "ja": "일본어"}.get(language, language or "한국어")
    diet = ", ".join(dietary) if dietary else "없음"
    prompt = (
        "너는 해외 식당에서 한국인 여행자를 돕는 메뉴 도우미다.\n"
        "첨부한 메뉴판 사진을 읽어 각 메뉴 항목을 추출하라.\n"
        f"- 각 항목의 원문 이름(original), {lang_label} 번역(translated), 무슨 음식인지 한 줄 "
        "설명(description), 가격(price: 숫자만, 없으면 null)을 낸다.\n"
        "- 카테고리 제목 줄, 가격·숫자만 있는 줄은 항목에서 제외한다.\n"
        "- 알레르기·식이 제한을 피해 추천 항목의 0-기반 인덱스를 최대 4개 고른다.\n"
        f"  식이 제한(반드시 제외): {diet}\n\n"
        "JSON 만 출력(설명·코드펜스 금지):\n"
        '{"items":[{"original":"원문","translated":"번역명","price":900,"description":"한 줄 설명"}],'
        '"recommended":[추천 항목의 0-기반 인덱스 최대 4개]}'
    )
    try:
        text = _invoke_claude_vision(prompt, image_bytes, max_tokens=3000)
        data = _parse_json_object(text)
    except Exception:
        return [], []

    items = []
    for it in (data.get("items") or []):
        if not isinstance(it, dict):
            continue
        orig = str(it.get("original") or "").strip()
        if not orig and not it.get("translated"):
            continue
        items.append({
            "item_id": f"m{len(items)}",
            "original_name": orig,
            "translated_name": str(it.get("translated") or orig),
            "price": _parse_price(it.get("price")),
            "description": str(it.get("description") or ""),
        })

    valid_ids = {it["item_id"] for it in items}
    recommended = []
    for x in (data.get("recommended") or []):
        try:
            rid = f"m{int(x)}"
        except (TypeError, ValueError):
            continue
        if rid in valid_ids and rid not in recommended:
            recommended.append(rid)
    return items, recommended[:4]


def _save_menu(trip_id, created_at, menu_id, photo_s3_key, items, recommended):
    """polylog-menus(PK trip_id, SK created_at) 에 이력 저장. 실패는 무시(결과 반환 우선)."""
    try:
        _menus_table.put_item(Item={
            "trip_id": trip_id,
            "created_at": created_at,
            "menu_id": menu_id,
            "photo_s3_key": photo_s3_key,
            "items": items,
            "recommended": recommended,
        })
    except Exception:
        pass


# ──────────────────────────────────────────────────────────────
# 공용 유틸 (배포 패키지가 달라 import 불가 — 의존성 0 유지)
# ──────────────────────────────────────────────────────────────
def _invoke_claude_vision(prompt, image_bytes, max_tokens=768):
    """Claude Haiku(멀티모달)에 이미지 + 지시문을 보내 텍스트 응답을 받는다."""
    b64 = base64.b64encode(image_bytes).decode("ascii")
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.3,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": _media_type(image_bytes),
                            "data": b64,
                        },
                    },
                    {"type": "text", "text": prompt},
                ],
            }
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


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
