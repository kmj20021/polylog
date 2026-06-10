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

  ※ 메뉴판이 라틴 문자(영/스/프/독/이/포 등)가 아니면(한/일/중 등) 분석 대신 신호만 반환:
    {"type":"unsupported_language","menu_id":..,"photo_s3_key":..,"language":"일본어"}
    → 앱이 "'일본어'는 앱 번역이 불가능 — 구글 렌즈로 검색" 안내로 유도(비전 CJK 번역 품질 낮음).

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
    """메인 핸들러: base64 이미지를 받아 Bedrock 비전으로 메뉴판을 분석하고 번역·추천을 반환."""
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

    # 2) Bedrock 비전 한 콜: 먼저 메뉴판의 '주(主) 문자 체계'를 판별한다.
    #    라틴 문자(영/스/프/독/이/포 등)면 항목 추출+번역+추천까지, 아니면 비라틴으로 표시만 한다.
    script, detected_lang, items, recommended = _analyze_menu(image_bytes, dietary, language)

    menu_id = str(uuid.uuid4())

    # 비라틴(한/일/중 등)은 비전 번역 품질이 낮아 앱에서 분석하지 않고,
    # 프론트가 "구글 렌즈로 검색" 안내로 유도하도록 신호만 돌려준다(이력 저장도 생략).
    if script == "non_latin":
        return _resp(200, {
            "type": "unsupported_language",
            "menu_id": menu_id,
            "photo_s3_key": photo_s3_key,
            "language": detected_lang,
        })

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
    """Base64 이미지 디코딩: data URI 접두사를 제거하고 base64를 디코드."""
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
    """이미지 포맷 판별: 매직바이트로 PNG/JPEG 타입을 구분하여 반환."""
    if image_bytes[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    return "image/jpeg"


def _parse_price(value):
    """가격 파싱: 문자열에서 숫자만 추출하여 정수로 반환.

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
    """이미지 저장: 원본 이미지를 S3(polylog-media)에 암호화하여 저장하고 키 반환."""
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
    """메뉴 분석: Bedrock 비전으로 메뉴판의 문자 체계를 판별하고 라틴 문자면 항목·번역·추천을 추출.

    반환: (script, detected_lang, items, recommended)
      script: "latin" | "non_latin"  (비라틴이면 items/recommended 는 빈 리스트)
      detected_lang: 감지한 주 언어의 한국어 명칭(예: "일본어") — 비라틴 안내 문구에 사용
      items: [{item_id, original_name, translated_name, price(int|None), description}]
      recommended: 식이 제한을 피한 추천 item_id (최대 4개)
    실패하면 ("latin", "", [], []) — 호출부가 '못 읽었어요' 안내 메시지를 반환.

    왜 문자 체계로 가르나: 비전(Haiku)이 비라틴(한/일/중) 메뉴는 번역 품질이 떨어져, 라틴 문자
    메뉴만 앱이 분석하고 비라틴은 '구글 렌즈로 검색' 안내로 유도한다(사용자 결정, 2026-06-07).
    """
    lang_label = {"ko": "한국어", "en": "영어", "ja": "일본어"}.get(language, language or "한국어")
    diet = ", ".join(dietary) if dietary else "없음"
    prompt = (
        "너는 해외 식당에서 한국인 여행자를 돕는 메뉴 도우미다. 첨부한 메뉴판 사진을 읽어라.\n"
        "1) 먼저 메뉴판의 '주(主) 문자 체계'를 판별한다.\n"
        "   - 라틴 문자 계열(영어·스페인어·프랑스어·독일어·이탈리아어·포르투갈어 등)이 '아니면'\n"
        "     (예: 한국어·일본어·중국어·태국어·아랍어·러시아어 등) 항목을 만들지 말고 정확히 이 JSON만 출력:\n"
        '     {"script":"non_latin","language":"<메뉴판 주 언어의 한국어 명칭, 예: 일본어>"}\n'
        "2) 라틴 문자 계열이면 각 메뉴 항목을 추출한다.\n"
        f"   - 각 항목의 원문 이름(original), {lang_label} 번역(translated), 무슨 음식인지 한 줄 "
        "설명(description), 가격(price: 숫자만, 없으면 null)을 낸다.\n"
        "   - 카테고리 제목 줄, 가격·숫자만 있는 줄은 항목에서 제외한다.\n"
        "   - 알레르기·식이 제한을 피해 추천 항목의 0-기반 인덱스를 최대 4개 고른다.\n"
        f"     식이 제한(반드시 제외): {diet}\n"
        "   출력 형식(JSON 만, 설명·코드펜스 금지):\n"
        '   {"script":"latin","items":[{"original":"원문","translated":"번역명","price":900,'
        '"description":"한 줄 설명"}],"recommended":[추천 항목의 0-기반 인덱스 최대 4개]}'
    )
    try:
        text = _invoke_claude_vision(prompt, image_bytes, max_tokens=3000)
        data = _parse_json_object(text)
    except Exception:
        return "latin", "", [], []   # 실패 시 라틴 경로로 폴백 → 빈 목록 → 기존 안내 메시지

    script = str(data.get("script") or "latin").strip().lower()
    detected_lang = str(data.get("language") or "").strip()
    if script == "non_latin":
        return "non_latin", detected_lang, [], []

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
    return "latin", detected_lang, items, recommended[:4]


def _save_menu(trip_id, created_at, menu_id, photo_s3_key, items, recommended):
    """메뉴 이력 저장: 분석 결과를 DynamoDB(polylog-menus)에 저장."""
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
    """Bedrock API 호출: Claude Haiku 비전 모델에 이미지와 프롬프트를 전송하여 응답 수신."""
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
    """JSON 파싱: 텍스트에서 첫 '{'부터 마지막 '}'까지의 JSON 객체를 추출하여 파싱."""
    if not text:
        return {}
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        return {}
    return json.loads(text[start:end + 1])


def _now_iso():
    """현재 시간 반환: UTC 시간을 ISO 8601 형식 문자열로 반환."""
    return datetime.now(timezone.utc).isoformat()


def _resp(status, payload):
    """HTTP 응답 생성: 상태 코드와 페이로드로 CORS 헤더를 포함한 Lambda 응답을 구성."""
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
