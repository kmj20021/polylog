"""fn-menu — 메뉴판 사진 OCR + 번역 + AI 추천 (서브1).

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
- 프론트가 아직 없어 **base64 인라인 이미지**를 한 POST 로 받는다 → presigned 업로드 왕복 없이
  curl 한 방으로 검증된다. 같은 Textract '동기' API(≤5MB)를 영수증(서브2)도 그대로 재사용한다.
- 사진은 받는 즉시 polylog-media 에 SSE 로 보관(기록·재처리용). 저장 실패해도 분석 결과는 반환.
- OCR(Textract DetectDocumentText)·분석(Bedrock Haiku)을 각각 작은 헬퍼로 분리 → 단위테스트에서
  monkeypatch 로 갈아끼우기 쉽고(=AWS 없이 테스트), 영수증이 부품을 재사용한다.
- ⭐ 번역은 Amazon Translate 가 아니라 **Bedrock 이 담당**한다(번역+설명+추천을 한 콜로). 이유는
  Translate 의 언어 자동감지(auto)가 Amazon Comprehend 권한을 요구하는데 SafeRole 에 없어
  전부 실패했기 때문 — 자세한 근거는 _analyze_menu 주석 참조.
- Bedrock 에는 JSON 만 받도록 요청하고 방어적으로 파싱 → 실패해도 번역·추천만 비고 원문 목록은 그대로.

리전: Textract·S3·DynamoDB = ap-northeast-2(서울), Bedrock(Haiku) = us-east-1.
권한은 공용 역할 SafeRole-polylog(Textract·S3·Bedrock·DynamoDB) — 환경변수 불필요.
boto3 는 Lambda 런타임 내장 → 배포 패키지 의존성 0.
"""
import base64
import binascii
import json
import uuid
from datetime import datetime, timezone

import boto3

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨(추천·요약 공용 모델).
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

# OCR·저장은 서울 리전. (번역은 Amazon Translate 대신 Bedrock 이 담당 — 아래 _analyze_menu 주석 참조)
_textract = boto3.client("textract", region_name="ap-northeast-2")
_s3 = boto3.client("s3", region_name="ap-northeast-2")
_menus_table = boto3.resource("dynamodb", region_name="ap-northeast-2").Table("polylog-menus")

_MEDIA_BUCKET = "polylog-media"
_MAX_LINES = 40        # 메뉴판 한 장에서 다룰 최대 줄 수(토큰·시간 상한)
_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # Textract 동기 호출 상한(5MB)

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

    # 2) OCR — 메뉴 줄 목록.
    try:
        lines = _ocr_lines(image_bytes)
    except Exception as exc:  # Textract 호출 자체 실패 → 502
        return _resp(502, {"error": f"OCR 실패: {exc}"})

    lines = [ln for ln in lines if ln.strip()][:_MAX_LINES]
    if not lines:
        return _resp(200, {
            "type": "result",
            "menu_id": str(uuid.uuid4()),
            "photo_s3_key": photo_s3_key,
            "items": [],
            "recommended": [],
            "message": "사진에서 메뉴 텍스트를 찾지 못했어요. 더 또렷하게 다시 촬영해 주세요.",
        })

    # 3) 항목 구성 — 우선 원문으로 채운다(번역 실패 시 그대로 보이도록).
    items = []
    for idx, orig in enumerate(lines):
        items.append({
            "item_id": f"m{idx}",
            "original_name": orig,
            "translated_name": orig,   # 4)에서 번역으로 덮어씀
            "price": _parse_price(orig),
            "description": "",
        })

    # 4) Bedrock 한 콜로 번역 + 설명 + 추천을 동시에(실패해도 원문 목록은 반환).
    translations, descriptions, recommended = _analyze_menu(items, dietary, language)
    for it in items:
        it["translated_name"] = translations.get(it["item_id"], it["original_name"])
        it["description"] = descriptions.get(it["item_id"], "")

    menu_id = str(uuid.uuid4())
    created_at = _now_iso()

    # 6) 이력 저장(polylog-menus). 실패해도 결과는 그대로 반환.
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
        # "data:image/jpeg;base64,...." → 콤마 뒤만 사용
        comma = s.find(",")
        if comma != -1:
            s = s[comma + 1:]
    try:
        return base64.b64decode(s, validate=False)
    except (binascii.Error, ValueError):
        return None


def _parse_price(text):
    """줄에서 숫자(가격)만 뽑아 정수로. 없으면 None.

    예) 'ラーメン ¥900' → 900, '석 5,500원' → 5500. (통화기호·콤마·점 무시)
    DynamoDB float 회피 위해 정수로 둔다.
    """
    digits = "".join(ch for ch in text if ch.isdigit())
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


def _ocr_lines(image_bytes):
    """Textract DetectDocumentText(동기) → LINE 블록 텍스트만 순서대로."""
    res = _textract.detect_document_text(Document={"Bytes": image_bytes})
    return [
        b.get("Text", "")
        for b in res.get("Blocks", [])
        if b.get("BlockType") == "LINE"
    ]


def _analyze_menu(items, dietary, language):
    """Bedrock(Claude Haiku) 한 콜로 번역 + 한 줄 설명 + 추천을 동시에 생성.

    왜 Amazon Translate 가 아니라 Bedrock 인가:
      Translate 의 SourceLanguageCode='auto'(언어 자동 감지)는 내부적으로 Amazon Comprehend
      (DetectDominantLanguage)를 호출하는데, 공용 역할 SafeRole-polylog 에는 Comprehend 권한이
      없어 호출이 AccessDenied 로 전부 실패 → 원문 그대로 폴백되는 버그가 있었다(B-3).
      메뉴는 다국어이고 source 언어를 미리 알 수 없어 explicit 지정도 어렵다. 그래서 이미
      쓰는 Bedrock 에 번역까지 맡긴다 → 새 IAM 권한 불필요 + 음식 맥락을 아는 더 나은 번역.

    반환: (translations dict[id->str], descriptions dict[id->str], recommended list[str])
    실패하면 ({}, {}, []) — 호출부는 원문 목록을 그대로 반환.
    """
    if not items:
        return {}, {}, []

    lang_label = {"ko": "한국어", "en": "영어", "ja": "일본어"}.get(language, language or "한국어")
    menu_lines = "\n".join(
        f'{it["item_id"]}: {it["original_name"]}' for it in items
    )
    diet = ", ".join(dietary) if dietary else "없음"
    prompt = (
        "너는 해외 식당에서 한국인 여행자를 돕는 메뉴 도우미다.\n"
        f"아래는 메뉴판 OCR 원문이다(item_id: 원문). 각 항목을 {lang_label}로 번역하고, "
        "무슨 음식인지 한 줄 설명을 붙여라. 가격·숫자·기호만 있는 줄은 원문을 그대로 둔다.\n"
        "그리고 알레르기·식이 제한을 피해 추천 메뉴를 최대 4개 골라라.\n"
        f"- 식이 제한(반드시 제외): {diet}\n"
        f"- 메뉴:\n{menu_lines}\n\n"
        "JSON 만 출력(설명·코드펜스 금지):\n"
        '{"items":{"m0":{"translated":"번역명","description":"한 줄 설명"}, ...},'
        '"recommended":["추천 item_id 최대 4개"]}'
    )
    try:
        text = _invoke_claude(prompt, max_tokens=3000)
        data = _parse_json_object(text)
    except Exception:
        return {}, {}, []

    valid_ids = {it["item_id"] for it in items}
    translations, descriptions = {}, {}
    for k, v in (data.get("items") or {}).items():
        if str(k) not in valid_ids or not isinstance(v, dict):
            continue
        if v.get("translated"):
            translations[str(k)] = str(v["translated"])
        if v.get("description"):
            descriptions[str(k)] = str(v["description"])
    recommended = [
        str(x) for x in (data.get("recommended") or [])
        if str(x) in valid_ids
    ][:4]
    return translations, descriptions, recommended


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
# 공용 유틸 (recommend/app.py 에서 복제 — 배포 패키지가 달라 import 불가, 의존성 0 유지)
# ──────────────────────────────────────────────────────────────
def _invoke_claude(prompt, max_tokens=768):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.3,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
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
