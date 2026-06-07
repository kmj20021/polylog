"""fn-receipt — 영수증 사진을 Bedrock 비전으로 직접 읽어 품목/금액/통화/원화환산 (서브2).

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

설계 요지(왜 이렇게 했나):
- ⭐ OCR 을 **Amazon Textract 가 아니라 Bedrock(Claude Haiku) 비전**으로 한다. 이유: Textract
  의 DetectDocumentText 는 라틴 문자(EN/ES/FR/DE/IT/PT)만 읽고 **한글·일본어(CJK)를 못 읽어**
  한글 영수증의 통화·품목명이 통째로 사라지는 문제가 있었다. Claude 비전은 사진을 직접 읽어
  모든 언어 + 통화기호("원"·¥·$)를 보고 통화까지 추론한다(B-3 교훈의 연장 — Bedrock 에 맡긴다).
- 사진은 받는 즉시 polylog-media 에 SSE 로 보관(기록·재처리용). 저장 실패해도 분석은 계속.
- 읽기·구조화(가게명·날짜·통화·합계·품목)를 **비전 한 콜**로 처리(_analyze_receipt).
- 환율은 외부 API(exchangerate-api.com)를 urllib 로 GET. 키 없음/통화 미인식/조회 실패면
  결과는 그대로 주되 total_krw=null + note.
- 금액은 소수(12.50)라 DynamoDB float 거부를 피하려 **문자열로 저장**, 환산만 인메모리 float,
  total_krw 만 반올림 정수(원).

리전: S3·DynamoDB = ap-northeast-2(서울), Bedrock(Haiku) = us-east-1.
권한은 공용 역할 SafeRole-polylog(Bedrock·S3·DynamoDB). 환율 키만 env EXCHANGE_RATE_API_KEY.
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

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨(멀티모달 — 사진을 직접 읽음).
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

# 저장은 서울 리전.
_s3 = boto3.client("s3", region_name="ap-northeast-2")
_receipts_table = boto3.resource("dynamodb", region_name="ap-northeast-2").Table("polylog-receipts")

_MEDIA_BUCKET = "polylog-media"
_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 비전 입력 이미지 상한(요청 크기·비용 보호)

# 지출 카테고리(고정 6종) — Bedrock 이 이 중에서만 고르게 한다.
_CATEGORIES = ["식비", "교통", "쇼핑", "숙박", "관광", "기타"]

# ⚠️ 환율 제공자: exchangerate-api.com v6 pair 엔드포인트(실호출 검증됨).
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

    # 2) Bedrock 비전 한 콜로 사진에서 직접 가게명·날짜·통화·합계·품목 추출.
    parsed = _analyze_receipt(image_bytes, home_currency)

    currency = parsed.get("currency")
    total = parsed.get("total")          # 문자열(원본 통화 금액) 또는 None
    items = parsed.get("items", [])
    merchant = parsed.get("merchant", "")
    occurred_at = parsed.get("occurred_at") or _now_iso()

    # 3) 원화(home_currency) 환산 — 합계만. 실패해도 결과는 반환하고 note 로 알린다.
    total_krw, note = _convert_total(total, currency, home_currency)

    # 아무것도 못 읽었으면(빈 결과) 안내 문구.
    if not merchant and total is None and not items and note is None:
        note = "사진에서 영수증 정보를 읽지 못했어요. 더 또렷하게 다시 촬영해 주세요."

    receipt_id = str(uuid.uuid4())

    # 4) 이력 저장(polylog-receipts, PK trip_id / SK occurred_at). 실패해도 결과는 반환.
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


def _analyze_receipt(image_bytes, home_currency):
    """Bedrock(Claude Haiku 비전) 한 콜로 영수증 사진을 직접 읽어 구조화.

    반환 dict:
      {"merchant":str, "occurred_at":str|None(YYYY-MM-DD), "currency":str|None(ISO4217),
       "total":str|None, "items":[{"item_id":str,"name_ko":str,"amount":str|None,"category":str}]}
    실패하면 빈 골격 — 호출부가 그대로 반환(note 로 안내).

    Textract 대신 비전을 쓰는 이유는 모듈 상단 docstring 참조(CJK OCR 불가 → 한글/일본어 영수증
    통째 실패). 비전은 사진의 언어·통화기호를 직접 보고 통화·품목 한국어화·카테고리를 한 번에 낸다.
    """
    empty = {"merchant": "", "occurred_at": None, "currency": None, "total": None, "items": []}

    cats = " / ".join(_CATEGORIES)
    prompt = (
        "너는 해외 영수증을 정리해 주는 한국인 여행자용 가계부 도우미다.\n"
        "첨부한 영수증 사진을 읽어 품목·금액·통화·날짜·가게명을 JSON 으로 구조화하라.\n"
        "- 통화는 ISO 4217 코드로(예: KRW, JPY, USD, EUR, CAD). 영수증의 언어·통화기호"
        "(원/¥/$/€)·국가로 추론하라. 정말 알 수 없을 때만 null.\n"
        "- 금액은 숫자만 문자열로(통화기호·콤마 제거, 소수점 유지). 예: '1,200' → '1200', '12.50' → '12.50'.\n"
        "- 합계(total)는 세금·봉사료 포함 최종 결제액. 못 찾으면 null.\n"
        "- 날짜(occurred_at)는 YYYY-MM-DD. 없으면 null.\n"
        f"- 각 품목 카테고리는 다음 중 하나만: {cats}. 애매하면 '기타'.\n"
        "- 품목명(name_ko)은 한국어로 번역/표기. 세금·할인·합계 줄은 품목에서 제외한다.\n\n"
        "JSON 만 출력(설명·코드펜스 금지):\n"
        '{"merchant":"가게명","occurred_at":"YYYY-MM-DD 또는 null","currency":"KRW 또는 null",'
        '"total":"문자열 또는 null","items":[{"name_ko":"품목","amount":"문자열 또는 null","category":"카테고리"}]}'
    )
    try:
        text = _invoke_claude_vision(prompt, image_bytes, max_tokens=2000)
        data = _parse_json_object(text)
    except Exception:
        return empty

    raw_items = data.get("items") or []
    items = []
    for idx, it in enumerate(raw_items):
        if not isinstance(it, dict):
            continue
        items.append({
            "item_id": f"r{len(items)}",
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

    exchangerate-api.com v6 pair 엔드포인트(_RATE_URL). urllib 표준 라이브러리만 사용.
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
# 공용 유틸 (배포 패키지가 달라 import 불가 — 의존성 0 유지)
# ──────────────────────────────────────────────────────────────
def _invoke_claude_vision(prompt, image_bytes, max_tokens=768):
    """Claude Haiku(멀티모달)에 이미지 + 지시문을 보내 텍스트 응답을 받는다.

    content 블록에 image(base64) + text 를 함께 실어 보낸다(Anthropic Bedrock 메시지 형식).
    """
    b64 = base64.b64encode(image_bytes).decode("ascii")
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "temperature": 0.2,
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
