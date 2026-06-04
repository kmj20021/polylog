"""fn-schedule — 추천받은 장소를 '여행 일정'에 담고 타임라인으로 돌려준다(서브3 MVP-A).

이 함수가 하는 일은 딱 둘이다(저장 / 조회). 대화형 수정은 다음 단계.

POST /schedule  — 일정에 한 장소를 추가한다(DynamoDB PutItem).
  입력 : {"trip_id":"demo-trip",         # 생략 시 demo-trip
          "place_id":"<google place id>",
          "place_name":"스타벅스 신주쿠점",  # name 도 허용
          "latitude":35.69,"longitude":139.70,  # lat/lng 도 허용
          "address":"도쿄도 신주쿠구 ...",   # 선택
          "rating":4.5,                    # 선택
          "title":"커피 한 잔"}            # 선택, 기본=place_name
  응답 : {"type":"added","item":{<저장된 항목>}}

GET /schedule?trip_id=demo-trip  — 그 여행의 일정 전체를 시간순으로 돌려준다(Query).
  응답 : {"type":"timeline","trip_id":"demo-trip","count":N,"items":[{...}, ...]}

설계 요지(왜 이렇게 했나):
- 테이블 polylog-schedules 는 PK=trip_id, SK=start_time(ISO 8601) 단일 테이블(ADR-014).
  타임라인 뷰가 "한 여행의 모든 일정을 시간순으로 한 번에" 보는 패턴이라, Query PK=trip_id
  한 번이면 정렬된 결과가 나온다(GSI·조인 불필요).
- MVP 는 사용자가 '시각'을 직접 고르지 않으므로, '추가한 순간의 시각'을 start_time(SK)에
  넣는다 → 추가한 순서대로 타임라인에 쌓이고, 마이크로초까지 찍어 같은 SK 충돌(덮어쓰기)도 막는다.
- boto3 는 Lambda 런타임 내장 → 의존성 0. DynamoDB 가 float 를 거부하므로 위/경도·평점은
  Decimal 로 저장하고, 응답으로 내보낼 때 다시 숫자(JSON)로 환원한다.
- 실행 역할 SafeRole-polylog 가 polylog* 테이블에 대한 DynamoDB 권한을 이미 보유(ADR-012,
  iam-guide §SafeRole) → 추가 IAM 작업 없이 동작한다.

테이블은 서울 리전(ap-northeast-2). Bedrock 호출 없음(저장만) → 비용 거의 0.
"""
import json
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

_dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-2")
_TABLE_NAME = os.environ.get("SCHEDULES_TABLE", "polylog-schedules")

_DEFAULT_TRIP_ID = "demo-trip"   # 로그인/Trip 생성 전 PoC 고정값

_CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
}


def lambda_handler(event, context):
    """API Gateway(프록시 통합) 진입점 — HTTP 메서드로 추가/조회를 가른다."""
    method = (event or {}).get("httpMethod", "POST").upper()

    if method == "OPTIONS":          # 브라우저 CORS 사전요청
        return _resp(200, {"ok": True})
    if method == "GET":
        return _handle_get(event)
    if method == "POST":
        return _handle_post(event)
    return _resp(405, {"error": f"지원하지 않는 메서드: {method}"})


def _handle_post(event):
    """장소 하나를 일정에 추가한다(PutItem)."""
    body = _parse_body(event)

    place_name = _clean(body.get("place_name") or body.get("name"))
    if not place_name:
        return _resp(400, {"error": "place_name(또는 name)은 필수입니다."})

    trip_id = _clean(body.get("trip_id")) or _DEFAULT_TRIP_ID
    now = _now_iso()

    item = {
        "trip_id": trip_id,                       # PK
        "start_time": now,                        # SK — 추가 순서 = 타임라인 순서
        "schedule_id": str(uuid.uuid4()),
        "title": _clean(body.get("title")) or place_name,
        "place_name": place_name,
        "place_id": _clean(body.get("place_id")),
        "address": _clean(body.get("address")),
        "source": "ai_recommended",
        "created_at": now,
        "updated_at": now,
    }

    lat = _num(body.get("latitude", body.get("lat")))
    lng = _num(body.get("longitude", body.get("lng")))
    if lat is not None:
        item["latitude"] = lat
    if lng is not None:
        item["longitude"] = lng
    rating = _num(body.get("rating"))
    if rating is not None:
        item["rating"] = rating

    # 빈 문자열 값은 굳이 저장하지 않는다(항목을 깔끔히).
    item = {k: v for k, v in item.items() if v not in ("", None)}

    _table().put_item(Item=item)
    return _resp(200, {"type": "added", "item": _json_safe(item)})


def _handle_get(event):
    """한 여행의 일정 전체를 시간순(오름차순)으로 돌려준다(Query)."""
    params = (event or {}).get("queryStringParameters") or {}
    trip_id = _clean(params.get("trip_id")) or _DEFAULT_TRIP_ID

    result = _table().query(
        KeyConditionExpression=Key("trip_id").eq(trip_id),
        ScanIndexForward=True,   # SK(start_time) 오름차순 → 추가한 순서
    )
    items = [_json_safe(it) for it in result.get("Items", [])]
    return _resp(200, {
        "type": "timeline",
        "trip_id": trip_id,
        "count": len(items),
        "items": items,
    })


# ─────────────────────────── 순수 로직(테스트 용이) ───────────────────────────
def _table():
    """매 호출 테이블 핸들을 얻는다(테스트에서 _dynamodb 를 갈아끼우기 쉽도록 지연 생성)."""
    return _dynamodb.Table(_TABLE_NAME)


def _parse_body(event):
    """API Gateway proxy 의 body(문자열/딕트/None)를 딕트로 정규화한다."""
    raw = (event or {}).get("body")
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except (ValueError, TypeError):
        return {}


def _now_iso():
    """현재 UTC 시각(마이크로초 포함) ISO 8601 — SK 충돌 방지 + 정렬 키."""
    return datetime.now(timezone.utc).isoformat()


def _clean(value):
    """문자열 다듬기. None/비문자열은 빈 문자열로."""
    if value is None:
        return ""
    return str(value).strip()


def _num(value):
    """위/경도·평점을 DynamoDB 가 받는 Decimal 로. 숫자가 아니면 None."""
    if value is None or value == "":
        return None
    try:
        return Decimal(str(value))
    except (ValueError, TypeError, ArithmeticError):
        return None


def _json_safe(obj):
    """DynamoDB 가 돌려준 Decimal 을 일반 숫자로 환원해 JSON 직렬화 가능하게."""
    if isinstance(obj, list):
        return [_json_safe(v) for v in obj]
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        # 정수면 int, 아니면 float (4.5 가 4 로 깎이지 않도록)
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    return obj


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
