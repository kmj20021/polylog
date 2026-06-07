"""fn-receipt — 영수증 사진을 Bedrock 비전으로 읽고, 지출 가계부(조회/수정/삭제)까지 (서브2).

POST /receipt  — action 으로 분기(새 라우트를 안 만들기 위해 fn-schedule 관례를 따름).

1) action="analyze"(기본): 사진 한 장을 분석해 저장.
   입력: {"trip_id":"demo-trip","image_base64":"<JPEG/PNG base64>","home_currency":"KRW"}
2) action="list": 한 여행의 영수증 전체 조회(대시보드·날짜별 목록용).
   입력: {"action":"list","trip_id":"demo-trip"}
3) action="update": 저장된 영수증 한 건을 수정(사용자가 OCR 결과를 직접 보정).
   입력: {"action":"update","trip_id":..,"receipt_id":..,"sk":<원래 SK>,
          "occurred_at":"YYYY-MM-DD","merchant":..,"currency":"JPY","total":"3500",
          "home_currency":"KRW","photo_s3_key":..,
          "items":[{"name_ko":"라멘","amount":"900","category":"식비"}]}
4) action="delete": 저장된 영수증 한 건 삭제.
   입력: {"action":"delete","trip_id":..,"sk":<삭제할 SK>}

응답(영수증 1건 공통 모양):
  {"receipt_id","sk","occurred_at"(표시용 날짜),"merchant","currency","total",
   "total_krw","rate"(적용 환율 문자열),"home_currency","photo_s3_key",
   "items":[{"item_id","name_ko","amount","amount_krw","category"}],"note"}

설계 요지(왜 이렇게 했나):
- ⭐ OCR = **Bedrock(Claude Haiku) 비전**. Textract(DetectDocumentText)는 한글·일본어(CJK)를
  못 읽어 한국 영수증이 통째로 실패 → 사진을 직접 읽는 비전으로 통일(모든 언어+통화기호 인식).
- ⭐ **정렬키(SK) 고유화**: 테이블 SK 속성명은 `occurred_at`(생성 시 고정)이라 못 바꾸지만,
  그 *값*을 `날짜#receipt_id` 로 두면 **같은 날 여러 장**이 안 덮어쓰이고 날짜순 정렬도 유지된다
  (**DynamoDB** — 복합키 Query). 표시용 깔끔한 날짜는 별도 속성 `display_date` 에 둔다.
- ⭐ **수정은 서버 영속**: update 가 환율을 다시 계산(**적용 환율 rate 를 저장·반환** — "환율 명시")
  하고 품목별 원화(amount_krw)까지 다시 계산 → 앱은 그대로 합산만 하면 카테고리별 대시보드 완성.
- 금액·환율은 소수라 DynamoDB float 거부를 피하려 **문자열로 저장**, 환산은 인메모리 float,
  원화 결과(total_krw·amount_krw)만 반올림 정수(원).

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
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

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

    action = (body.get("action") or "analyze").strip().lower()
    if action == "list":
        return _handle_list(body)
    if action == "update":
        return _handle_update(body)
    if action == "delete":
        return _handle_delete(body)
    return _handle_analyze(body)  # 기본(또는 action 미지정)


# ──────────────────────────────────────────────────────────────
# action: analyze — 사진 분석 + 저장
# ──────────────────────────────────────────────────────────────
def _handle_analyze(body):
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
    total = parsed.get("total")
    merchant = parsed.get("merchant", "")
    occurred_date = parsed.get("occurred_at") or _today()

    # 3) 원화 환산(합계 + 품목별). 적용 환율(rate)도 함께 받는다.
    total_krw, rate, items, note = _apply_conversion(
        currency, total, parsed.get("items", []), home_currency)

    # 아무것도 못 읽었으면 안내.
    if not merchant and total is None and not items and note is None:
        note = "사진에서 영수증 정보를 읽지 못했어요. 더 또렷하게 다시 촬영해 주세요."

    receipt_id = str(uuid.uuid4())
    sk = _make_sk(occurred_date, receipt_id)

    record = {
        "trip_id": trip_id,
        "occurred_at": sk,            # SK(고유·정렬용) = 날짜#receipt_id
        "display_date": occurred_date,  # 표시·수정·그룹핑용 깔끔한 날짜
        "receipt_id": receipt_id,
        "photo_s3_key": photo_s3_key,
        "merchant": merchant,
        "currency": currency,
        "total": total,
        "total_krw": total_krw,
        "rate": rate,
        "home_currency": home_currency,
        "items": items,
    }
    _put_receipt(record)

    out = _to_response(record)
    out["note"] = note
    return _resp(200, out)


# ──────────────────────────────────────────────────────────────
# action: list — 한 여행의 영수증 전체(대시보드·날짜별 목록)
# ──────────────────────────────────────────────────────────────
def _handle_list(body):
    trip_id = (body.get("trip_id") or "demo-trip").strip()
    items = _query_receipts(trip_id)
    # SK(날짜#id) 오름차순 → 최신이 위로 오도록 뒤집는다(프론트는 날짜로 다시 그룹핑).
    receipts = [_to_response(it) for it in reversed(items)]
    return _resp(200, {"type": "list", "trip_id": trip_id, "receipts": receipts})


# ──────────────────────────────────────────────────────────────
# action: update — 저장된 영수증 1건 보정(영속 저장)
# ──────────────────────────────────────────────────────────────
def _handle_update(body):
    trip_id = (body.get("trip_id") or "demo-trip").strip()
    receipt_id = (body.get("receipt_id") or "").strip()
    old_sk = (body.get("sk") or "").strip()
    if not receipt_id or not old_sk:
        return _resp(400, {"error": "update 에는 receipt_id 와 sk 가 필요합니다."})

    home_currency = (body.get("home_currency") or "KRW").strip().upper()
    occurred_date = _clean_str(body.get("occurred_at")) or _today()
    merchant = str(body.get("merchant") or "").strip()
    currency = _clean_currency(body.get("currency"))
    total = _clean_amount(body.get("total"))

    raw_items = body.get("items") or []
    items_in = []
    for it in raw_items:
        if not isinstance(it, dict):
            continue
        items_in.append({
            "item_id": str(it.get("item_id") or f"r{len(items_in)}"),
            "name_ko": str(it.get("name_ko") or "").strip(),
            "amount": _clean_amount(it.get("amount")),
            "category": it.get("category") if it.get("category") in _CATEGORIES else "기타",
        })

    # 환율 재계산(수정된 통화·금액 기준) — 적용 환율을 다시 명시해 저장.
    total_krw, rate, items, note = _apply_conversion(currency, total, items_in, home_currency)

    new_sk = _make_sk(occurred_date, receipt_id)
    record = {
        "trip_id": trip_id,
        "occurred_at": new_sk,
        "display_date": occurred_date,
        "receipt_id": receipt_id,
        "photo_s3_key": (body.get("photo_s3_key") or "").strip(),
        "merchant": merchant,
        "currency": currency,
        "total": total,
        "total_krw": total_krw,
        "rate": rate,
        "home_currency": home_currency,
        "items": items,
    }
    _put_receipt(record)
    # 날짜가 바뀌면 SK 도 바뀌므로 옛 행을 지운다(아니면 새 행만 덮어씀).
    if new_sk != old_sk:
        _delete_receipt(trip_id, old_sk)

    out = _to_response(record)
    out["note"] = note
    return _resp(200, {"type": "updated", **out})


# ──────────────────────────────────────────────────────────────
# action: delete
# ──────────────────────────────────────────────────────────────
def _handle_delete(body):
    trip_id = (body.get("trip_id") or "demo-trip").strip()
    sk = (body.get("sk") or "").strip()
    if not sk:
        return _resp(400, {"error": "delete 에는 sk 가 필요합니다."})
    _delete_receipt(trip_id, sk)
    return _resp(200, {"type": "deleted", "sk": sk})


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
       "total":str|None, "items":[{"item_id","name_ko","amount","category"}]}
    실패하면 빈 골격 — 호출부가 그대로 반환(note 로 안내).
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

    items = []
    for it in (data.get("items") or []):
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


def _put_receipt(record):
    """polylog-receipts 에 한 건 저장(덮어쓰기). 실패는 무시(결과 반환 우선)."""
    try:
        _receipts_table.put_item(Item=record)
    except Exception:
        pass


def _delete_receipt(trip_id, sk):
    """SK(occurred_at 속성 값)로 한 건 삭제."""
    try:
        _receipts_table.delete_item(Key={"trip_id": trip_id, "occurred_at": sk})
    except Exception:
        pass


def _query_receipts(trip_id):
    """한 여행의 영수증 전체를 SK 오름차순으로 조회. 실패하면 빈 목록."""
    try:
        res = _receipts_table.query(KeyConditionExpression=Key("trip_id").eq(trip_id))
        return res.get("Items", [])
    except Exception:
        return []


# ──────────────────────────────────────────────────────────────
# 순수 로직 (네트워크·AWS 불필요 — 단위테스트 직접 검증)
# ──────────────────────────────────────────────────────────────
def _apply_conversion(currency, total, items, home_currency):
    """합계 + 품목별 원화 환산. 적용 환율(rate)도 함께 돌려준다("환율 명시").

    반환: (total_krw:int|None, rate:str|None, items:list(amount_krw 추가), note:str|None)
      - rate = 1 currency 당 home_currency 금액(문자열, 소수 4자리). DynamoDB float 회피 위해 문자열.
      - 통화 미인식/환율 실패면 total_krw·amount_krw 는 None, note 로 이유 안내(결과 자체는 유효).
    """
    out_items = [dict(it) for it in items]  # 원본 보존(복사)
    note = None
    rate = None

    if not currency:
        note = "통화를 인식하지 못해 환산을 건너뛰었습니다."
    else:
        rate = _fetch_rate(currency, home_currency)
        if rate is None:
            note = f"{currency}→{home_currency} 환율을 가져오지 못해 환산을 건너뛰었습니다."

    total_krw = None
    if rate is not None and total is not None:
        try:
            total_krw = round(float(total) * rate)
        except (TypeError, ValueError):
            note = "합계 금액을 숫자로 해석하지 못했습니다."

    for it in out_items:
        it["amount_krw"] = None
        amt = it.get("amount")
        if rate is not None and amt is not None:
            try:
                it["amount_krw"] = round(float(amt) * rate)
            except (TypeError, ValueError):
                pass

    rate_str = f"{rate:.4f}" if rate is not None else None
    return total_krw, rate_str, out_items, note


def _clean_amount(value):
    """금액을 '숫자/소수점만' 문자열로 정규화. 숫자 없으면 None.

    예) '¥1,200' → '1200', '12.50' → '12.50', 'free' → None, 1200(int) → '1200'.
    DynamoDB 의 Decimal(읽기 결과) 도 str() 로 안전 처리.
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


def _make_sk(display_date, receipt_id):
    """SK(occurred_at 속성) 값 = '날짜#receipt_id' — 같은 날 여러 장도 고유·날짜순 정렬."""
    return f"{display_date}#{receipt_id}"


def _to_response(item):
    """저장 레코드(또는 DynamoDB 조회 결과)를 프론트용 1건 모양으로 변환.

    - "sk"        : 실제 SK 값(occurred_at 속성) — update/delete 의 키로 되돌려준다.
    - "occurred_at": 표시용 깔끔한 날짜(display_date). 옛 행(‘#’ 없음)은 SK 에서 유추.
    - 숫자(Decimal)는 _resp 의 default 가 정수/실수로 직렬화한다.
    """
    sk = str(item.get("occurred_at") or "")
    display_date = item.get("display_date") or (sk.split("#")[0] if sk else "")
    return {
        "receipt_id": item.get("receipt_id"),
        "sk": sk,
        "occurred_at": display_date,
        "merchant": item.get("merchant") or "",
        "currency": item.get("currency"),
        "total": item.get("total"),
        "total_krw": item.get("total_krw"),
        "rate": item.get("rate"),
        "home_currency": item.get("home_currency") or "KRW",
        "photo_s3_key": item.get("photo_s3_key") or "",
        "items": item.get("items") or [],
    }


# ──────────────────────────────────────────────────────────────
# 공용 유틸 (배포 패키지가 달라 import 불가 — 의존성 0 유지)
# ──────────────────────────────────────────────────────────────
def _invoke_claude_vision(prompt, image_bytes, max_tokens=768):
    """Claude Haiku(멀티모달)에 이미지 + 지시문을 보내 텍스트 응답을 받는다."""
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


def _today():
    return datetime.now(timezone.utc).date().isoformat()


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False, default=_json_default),
    }


def _json_default(o):
    """DynamoDB 조회 결과의 Decimal 을 JSON 으로(정수면 int, 아니면 float)."""
    if isinstance(o, Decimal):
        return int(o) if o % 1 == 0 else float(o)
    raise TypeError(f"not serializable: {type(o)}")
