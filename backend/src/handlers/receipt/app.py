"""fn-receipt — 영수증 사진 OCR + 품목/금액/통화 인식 + 원화 환산 (서브2).

POST /receipt
입력: {"trip_id":"demo-trip",
       "image_base64":"<JPEG/PNG base64 (data URI 접두사 허용)>",
       "home_currency":"KRW"}            # (선택) 환산 목표 통화(기본 KRW)

응답:
  {"type":"result","receipt_id":"<uuid>","photo_s3_key":"receipts/.../x.jpg",
   "merchant":"<가게명>","occurred_at":"2026-06-07",
   "currency":"JPY","total":"3500","total_krw":31500,
   "items":[{"item_id":"r0","name_ko":"라멘","amount":"900","category":"식비"}, ...],
   "note":null}

설계 요지(왜 이렇게 했나 — 메뉴판 서브1과 같은 뼈대를 재사용):
- 사진→Textract OCR→Bedrock 파싱→S3/DynamoDB 저장 파이프라인을 fn-menu 와 동일하게 쓴다.
  프론트가 아직 없어 base64 인라인 이미지를 한 POST 로 받는다(presigned 왕복 없이 curl 검증).
- ⭐ OCR 은 영수증 전용 AnalyzeExpense 가 아니라 일반 **DetectDocumentText + Bedrock 파싱**이다.
  이유는 SafeRole-polylog 에 textract:AnalyzeExpense 권한이 확인되지 않았고, B-3(메뉴 번역)에서
  "권한을 가정하면 통째로 실패한다"는 교훈을 얻었기 때문 — 검증된 OCR 만 써서 새 IAM 요청을 0으로.
- 통화 인식·품목 한국어화·카테고리 분류·합계 추출을 **Bedrock 한 콜**로 처리한다(_analyze_receipt).
- 환율은 외부 API(exchangerate-api.com)를 urllib 로 GET 한다(recommend 의 HTTP 패턴 재사용).
  키(EXCHANGE_RATE_API_KEY)가 없거나 통화 미인식·조회 실패면 결과는 그대로 주되 total_krw=null + note.
- 금액은 소수(예 12.50)라 DynamoDB 가 float 를 거부 → **문자열로 저장**, 환산만 인메모리 float,
  total_krw 만 반올림 정수(원)로 둔다.

리전: Textract·S3·DynamoDB = ap-northeast-2(서울), Bedrock(Haiku) = us-east-1.
권한은 공용 역할 SafeRole-polylog(Textract·S3·Bedrock·DynamoDB).
환율 키만 환경변수 EXCHANGE_RATE_API_KEY 로 주입(없으면 환산만 비활성).
boto3 는 Lambda 런타임 내장 → 배포 패키지 의존성 0.
"""
import base64
import binascii
import json
import os
import urllib.request
import uuid
from datetime import datetime, timezone

import boto3

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨(추천·요약 공용 모델).
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

# OCR·저장은 서울 리전.
_textract = boto3.client("textract", region_name="ap-northeast-2")
_s3 = boto3.client("s3", region_name="ap-northeast-2")
_receipts_table = boto3.resource("dynamodb", region_name="ap-northeast-2").Table("polylog-receipts")

_MEDIA_BUCKET = "polylog-media"
_MAX_LINES = 60        # 영수증 한 장에서 다룰 최대 줄 수(메뉴판보다 길 수 있어 여유)
_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # Textract 동기 호출 상한(5MB)

# 지출 카테고리(고정 6종) — Bedrock 이 이 중에서만 고르게 한다.
_CATEGORIES = ["식비", "교통", "쇼핑", "숙박", "관광", "기타"]

# ⚠️ 환율 제공자 가정: exchangerate-api.com v6 pair 엔드포인트.
#    응답 JSON 의 conversion_rate(=1 FROM 당 TO 금액)만 쓴다.
#    제공자가 다르면 이 상수와 _fetch_rate 의 응답 키 한 곳만 고치면 된다.
_RATE_URL = "https://v6.exchangerate-api.com/v6/{key}/pair/{frm}/{to}"

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
    home_currency = (body.get("home_currency") or "KRW").strip().upper()

    # 1) 원본 보관(실패해도 분석은 계속).
    photo_s3_key = _store_image(image_bytes, trip_id)

    # 2) OCR — 영수증 줄 목록.
    try:
        lines = _ocr_lines(image_bytes)
    except Exception as exc:  # Textract 호출 자체 실패 → 502
        return _resp(502, {"error": f"OCR 실패: {exc}"})

    lines = [ln for ln in lines if ln.strip()][:_MAX_LINES]
    if not lines:
        return _resp(200, {
            "type": "result",
            "receipt_id": str(uuid.uuid4()),
            "photo_s3_key": photo_s3_key,
            "merchant": "",
            "occurred_at": _now_iso(),
            "currency": None,
            "total": None,
            "total_krw": None,
            "items": [],
            "note": "사진에서 영수증 텍스트를 찾지 못했어요. 더 또렷하게 다시 촬영해 주세요.",
        })

    # 3) Bedrock 한 콜로 가게명·날짜·통화·합계·품목(한국어+카테고리) 추출.
    parsed = _analyze_receipt(lines, home_currency)

    currency = parsed.get("currency")
    total = parsed.get("total")          # 문자열(원본 통화 금액) 또는 None
    items = parsed.get("items", [])
    merchant = parsed.get("merchant", "")
    occurred_at = parsed.get("occurred_at") or _now_iso()

    # 4) 원화(home_currency) 환산 — 합계만. 실패해도 결과는 반환하고 note 로 알린다.
    total_krw, note = _convert_total(total, currency, home_currency)

    receipt_id = str(uuid.uuid4())

    # 5) 이력 저장(polylog-receipts, PK trip_id / SK occurred_at). 실패해도 결과는 반환.
    _save_receipt(trip_id, occurred_at, {
        "receipt_id": receipt_id,
        "photo_s3_key": photo_s3_key,
        "merchant": merchant,
        "currency": currency,
        "total": total,
        "total_krw": total_krw,
        "home_currency": home_currency,
        "items": items,
    })

    return _resp(200, {
        "type": "result",
        "receipt_id": receipt_id,
        "photo_s3_key": photo_s3_key,
        "merchant": merchant,
        "occurred_at": occurred_at,
        "currency": currency,
        "total": total,
        "total_krw": total_krw,
        "items": items,
        "note": note,
    })


# ──────────────────────────────────────────────────────────────
# 입력 처리 (fn-menu 와 동일 — 의존성 0 유지 위해 복제)
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


# ──────────────────────────────────────────────────────────────
# AWS 부품(각각 단위테스트에서 monkeypatch 대상)
# ──────────────────────────────────────────────────────────────
def _store_image(image_bytes, trip_id):
    """원본 이미지를 polylog-media 에 SSE 로 저장하고 s3 key 반환. 실패하면 빈 문자열."""
    key = f"receipts/{trip_id}/{uuid.uuid4()}.jpg"
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


def _analyze_receipt(lines, home_currency):
    """Bedrock(Claude Haiku) 한 콜로 영수증을 구조화.

    반환 dict:
      {"merchant":str, "occurred_at":str|None(YYYY-MM-DD), "currency":str|None(ISO4217),
       "total":str|None, "items":[{"item_id":str,"name_ko":str,"amount":str|None,"category":str}]}
    실패하면 빈 골격({merchant:"", currency:None, total:None, items:[]}) — 호출부가 그대로 반환.

    왜 한 콜인가: OCR 원문에는 품목·가격·세금·합계·날짜가 뒤섞여 있어 규칙 파싱이 깨지기 쉽다.
    맥락을 아는 LLM 에 통화 인식·한국어 품목명·카테고리 분류·합계 추출을 한 번에 맡긴다(B-3 교훈:
    번역/분류는 권한 가정 없는 Bedrock 으로). 금액은 소수가 있을 수 있어 모두 문자열로 받는다.
    """
    empty = {"merchant": "", "occurred_at": None, "currency": None, "total": None, "items": []}
    if not lines:
        return empty

    receipt_text = "\n".join(lines)
    cats = " / ".join(_CATEGORIES)
    prompt = (
        "너는 해외 영수증을 정리해 주는 한국인 여행자용 가계부 도우미다.\n"
        "아래는 영수증 OCR 원문이다. 품목·금액·통화·날짜·가게명을 읽어 JSON 으로 구조화하라.\n"
        f"- 통화는 ISO 4217 코드로(예: JPY, USD, EUR). 확실치 않으면 currency 를 null 로 둔다.\n"
        "- 금액은 숫자만 문자열로(통화기호·콤마 제거, 소수점은 유지). 예: '1,200' → '1200', '12.50' → '12.50'.\n"
        "- 합계(total)는 세금·봉사료 포함 최종 결제액. 못 찾으면 null.\n"
        "- 날짜(occurred_at)는 YYYY-MM-DD. 없으면 null.\n"
        f"- 각 품목 카테고리는 다음 중 하나만: {cats}. 애매하면 '기타'.\n"
        "- 품목명(name_ko)은 한국어로 번역/표기. 세금·할인·합계 줄은 품목에서 제외한다.\n\n"
        f"영수증 원문:\n{receipt_text}\n\n"
        "JSON 만 출력(설명·코드펜스 금지):\n"
        '{"merchant":"가게명","occurred_at":"YYYY-MM-DD 또는 null","currency":"JPY 또는 null",'
        '"total":"문자열 또는 null","items":[{"name_ko":"품목","amount":"문자열 또는 null","category":"카테고리"}]}'
    )
    try:
        text = _invoke_claude(prompt, max_tokens=2000)
        data = _parse_json_object(text)
    except Exception:
        return empty

    raw_items = data.get("items") or []
    items = []
    for idx, it in enumerate(raw_items):
        if not isinstance(it, dict):
            continue
        items.append({
            "item_id": f"r{idx}",
            "name_ko": str(it.get("name_ko") or "").strip(),
            "amount": _clean_amount(it.get("amount")),
            "category": it.get("category") if it.get("category") in _CATEGORIES else "기타",
        })

    return {
        "merchant": str(data.get("merchant") or "").strip(),
        "occurred_at": _clean_str(data.get("occurred_at")),
        "currency": _clean_currency(data.get("currency")),
        "total": _clean_amount(data.get("total")),
        "items": items,
    }


def _fetch_rate(frm, to):
    """1 frm 당 to 환율(float) 조회. 키 없음/통화 없음/실패 시 None.

    exchangerate-api.com v6 pair 엔드포인트를 가정(_RATE_URL). urllib 표준 라이브러리만 사용.
    """
    key = os.environ.get("EXCHANGE_RATE_API_KEY")
    if not key or not frm or not to:
        return None
    if frm == to:
        return 1.0
    url = _RATE_URL.format(key=key, frm=frm, to=to)
    try:
        with urllib.request.urlopen(url, timeout=8) as res:
            data = json.loads(res.read().decode("utf-8"))
    except Exception:
        return None
    if data.get("result") != "success":
        return None
    rate = data.get("conversion_rate")
    try:
        return float(rate)
    except (TypeError, ValueError):
        return None


def _save_receipt(trip_id, occurred_at, fields):
    """polylog-receipts(PK trip_id, SK occurred_at) 에 이력 저장. 실패는 무시(결과 반환 우선)."""
    item = {"trip_id": trip_id, "occurred_at": occurred_at}
    item.update(fields)
    try:
        _receipts_table.put_item(Item=item)
    except Exception:
        pass


# ──────────────────────────────────────────────────────────────
# 순수 로직 (네트워크·AWS 불필요 — 단위테스트 직접 검증)
# ──────────────────────────────────────────────────────────────
def _convert_total(total, currency, home_currency):
    """합계를 home_currency 로 환산 → (total_krw:int|None, note:str|None).

    환율 조회·통화 인식이 안 되면 total_krw 는 None 으로 두고 note 로 이유를 알린다(결과 자체는 유효).
    금액 문자열을 인메모리 float 로만 계산하고 반올림 정수로 반환(원 단위).
    """
    if total is None:
        return None, None
    if not currency:
        return None, "통화를 인식하지 못해 환산을 건너뛰었습니다."
    rate = _fetch_rate(currency, home_currency)
    if rate is None:
        return None, f"{currency}→{home_currency} 환율을 가져오지 못해 환산을 건너뛰었습니다."
    try:
        return round(float(total) * rate), None
    except (TypeError, ValueError):
        return None, "합계 금액을 숫자로 해석하지 못했습니다."


def _clean_amount(value):
    """모델이 준 금액을 '숫자/소수점만' 문자열로 정규화. 숫자 없으면 None.

    예) '¥1,200' → '1200', '12.50' → '12.50', 'free' → None, 1200(int) → '1200'.
    """
    if value is None:
        return None
    s = str(value).strip()
    cleaned = "".join(ch for ch in s if ch.isdigit() or ch == ".")
    # 소수점만 남거나 빈 경우 방어.
    if not any(ch.isdigit() for ch in cleaned):
        return None
    return cleaned


def _clean_currency(value):
    """ISO4217 형태(영문 3자)만 통과시키고 대문자화. 아니면 None."""
    if not value:
        return None
    s = str(value).strip().upper()
    return s if len(s) == 3 and s.isalpha() else None


def _clean_str(value):
    s = (str(value).strip() if value is not None else "")
    return s or None


# ──────────────────────────────────────────────────────────────
# 공용 유틸 (fn-menu / recommend 에서 복제 — 배포 패키지가 달라 import 불가, 의존성 0 유지)
# ──────────────────────────────────────────────────────────────
def _invoke_claude(prompt, max_tokens=768):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.2,
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
