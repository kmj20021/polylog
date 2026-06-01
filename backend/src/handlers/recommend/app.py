"""fn-recommend — AI 장소 추천 (Bedrock Claude 3 Haiku).

POST /recommend
입력 : {"location": "도쿄 신주쿠", "category": "맛집"}
출력 : {"location": "...", "category": "...", "recommendation": "<Claude 응답 텍스트>"}

Bedrock 리전은 us-east-1(모델 액세스 승인 완료). 함수 자체 리전과 무관하게
boto3 클라이언트에 region_name 을 명시한다(ADR: 모델 가용 리전 분리).
boto3 는 Lambda 런타임 내장 → requirements.txt 불필요.
앱에서 직접 호출하므로 모든 응답에 CORS 헤더를 포함한다.
"""
import json

import boto3

# us-east-1 에서만 Claude 3 Haiku 액세스가 승인됨.
_bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
_MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

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

    location = (body.get("location") or "").strip()
    category = (body.get("category") or "").strip()
    if not location or not category:
        return _resp(400, {"error": "location 과 category 는 필수입니다."})

    prompt = (
        f"당신은 현지 사정에 밝은 여행 동행 가이드입니다. "
        f"'{location}' 지역의 '{category}' 추천을 부탁합니다.\n"
        f"조건:\n"
        f"- 실제 있을 법한 곳 3곳을 골라 번호로 제시\n"
        f"- 각 항목마다 한 줄 특징과 추천 이유를 한국어로 설명\n"
        f"- 과장 없이 친근한 말투로, 전체 250자 내외"
    )

    try:
        recommendation = _invoke_claude(prompt)
    except Exception as exc:  # noqa: BLE001 — 발표 대비, 원인을 그대로 전달
        return _resp(502, {"error": f"Bedrock 호출 실패: {exc}"})

    return _resp(200, {
        "location": location,
        "category": category,
        "recommendation": recommendation,
    })


def _invoke_claude(prompt):
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 512,
        "temperature": 0.7,
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
    # messages API: {"content": [{"type":"text","text":"..."}], ...}
    return "".join(
        block.get("text", "")
        for block in parsed.get("content", [])
        if block.get("type") == "text"
    ).strip()


def _resp(status, payload):
    return {
        "statusCode": status,
        "headers": _CORS,
        "body": json.dumps(payload, ensure_ascii=False),
    }
