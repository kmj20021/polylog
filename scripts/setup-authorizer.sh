#!/bin/bash
# polylog — Lambda Authorizer 설정·활성화·비활성화.
#
# 모드:
#   (인수 없음)  — Authorizer 를 API Gateway 에 등록. 경로는 NONE 유지(기존 기능 안 막힘).
#   enable       — /health 제외 모든 경로에 CUSTOM(Authorizer) 적용. 토큰 없는 호출 → 401.
#   disable      — 모든 경로를 NONE 으로 원복.
#
# 사전 조건:
#   1) fn-authorizer 람다가 배포돼 있어야 함 → bash scripts/deploy.sh 먼저.
#   2) GOOGLE_CLIENT_ID 가 fn-authorizer 에 주입돼 있어야 aud 검증이 동작함.
#
# 사용법(CloudShell):
#   bash scripts/setup-authorizer.sh           # 처음 한 번만
#   bash scripts/setup-authorizer.sh enable    # 토큰 강제 시작
#   bash scripts/setup-authorizer.sh disable   # 즉시 원복

set -euo pipefail

MODE=${1:-init}
REGION=ap-northeast-2
ACCOUNT_ID=443370697536
API_NAME="polylog-api"
FUNC="polylog-fn-authorizer"
AUTHORIZER_NAME="polylog-authorizer"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC}"
INTEGRATION_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
die()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

# ── 0. 사전 확인 ──────────────────────────────────────────────
aws lambda get-function --function-name "$FUNC" --region "$REGION" >/dev/null 2>&1 \
  || die "$FUNC 람다가 없습니다. 먼저 'bash scripts/deploy.sh' 로 배포하세요."

# ── 1. API ID ─────────────────────────────────────────────────
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id" --output text)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] || die "API '$API_NAME' 없음."
log "API_ID=$API_ID"

# ── 2. Lambda Authorizer 조회 또는 생성 ───────────────────────
AUTH_ID=$(aws apigateway get-authorizers --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?name=='$AUTHORIZER_NAME'].id" --output text 2>/dev/null || true)

if [ -z "$AUTH_ID" ] || [ "$AUTH_ID" = "None" ]; then
    log "Lambda Authorizer 생성: $AUTHORIZER_NAME (TOKEN 타입, TTL=0)"
    AUTH_ID=$(aws apigateway create-authorizer \
      --rest-api-id "$API_ID" \
      --name "$AUTHORIZER_NAME" \
      --type TOKEN \
      --authorizer-uri "$INTEGRATION_URI" \
      --identity-source "method.request.header.Authorization" \
      --authorizer-result-ttl-in-seconds 0 \
      --region "$REGION" \
      --query 'id' --output text)
    log "  생성됨: $AUTH_ID"

    # API Gateway 가 fn-authorizer 를 호출하도록 권한 부여
    aws lambda add-permission \
      --function-name "$FUNC" \
      --statement-id "apigw-authorizer-invoke" \
      --action lambda:InvokeFunction \
      --principal apigateway.amazonaws.com \
      --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/authorizers/*" \
      --region "$REGION" >/dev/null 2>&1 \
      && log "  호출권한 부여" \
      || warn "  호출권한 이미 있음(건너뜀)"
else
    warn "Authorizer 이미 있음: $AUTH_ID"
fi

# ── 3. init 모드면 여기서 종료 ────────────────────────────────
if [ "$MODE" = "init" ]; then
    log "✅ Authorizer 등록 완료 ($AUTH_ID)"
    log "   경로는 NONE 유지 — 기존 기능 영향 없음"
    log "   활성화: bash scripts/setup-authorizer.sh enable"
    exit 0
fi

# ── 4. enable / disable: 보호 대상 resource·method 추출 ───────
aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --output json > /tmp/polylog-apigw-resources.json

METHODS_FILE=$(mktemp)
trap "rm -f $METHODS_FILE" EXIT

python3 - <<'PYEOF' > "$METHODS_FILE"
import json

with open('/tmp/polylog-apigw-resources.json') as f:
    data = json.load(f)

# /health 는 모니터링용 — 토큰 없이 항상 열어 둬야 함.
# OPTIONS 는 CORS preflight 용 — 이 프로젝트에선 Lambda 내부 처리라 API GW 메서드 없음.
skip_paths = {'/', '/health'}

for item in data['items']:
    path = item.get('path', '')
    if path in skip_paths:
        continue
    for method in item.get('resourceMethods', {}):
        if method == 'OPTIONS':
            continue
        print(f"{item['id']} {method} {path}")
PYEOF

if [ "$MODE" = "enable" ]; then
    log "Authorizer ENABLE 시작 — 아래 경로에 CUSTOM 인증 적용:"
    while IFS=' ' read -r res_id method path; do
        log "  $method $path"
        aws apigateway update-method \
          --rest-api-id "$API_ID" --resource-id "$res_id" \
          --http-method "$method" \
          --patch-operations \
            "[{\"op\":\"replace\",\"path\":\"/authorizationType\",\"value\":\"CUSTOM\"},{\"op\":\"replace\",\"path\":\"/authorizerId\",\"value\":\"$AUTH_ID\"}]" \
          --region "$REGION" >/dev/null
    done < "$METHODS_FILE"

elif [ "$MODE" = "disable" ]; then
    log "Authorizer DISABLE 시작 — 아래 경로를 NONE 으로 원복:"
    while IFS=' ' read -r res_id method path; do
        log "  $method $path"
        aws apigateway update-method \
          --rest-api-id "$API_ID" --resource-id "$res_id" \
          --http-method "$method" \
          --patch-operations \
            "[{\"op\":\"replace\",\"path\":\"/authorizationType\",\"value\":\"NONE\"}]" \
          --region "$REGION" >/dev/null
    done < "$METHODS_FILE"

else
    die "알 수 없는 모드: $MODE (init | enable | disable)"
fi

# ── 5. 스테이지 재배포 ────────────────────────────────────────
log "dev 스테이지 재배포"
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name dev \
  --region "$REGION" --query 'id' --output text >/dev/null

if [ "$MODE" = "enable" ]; then
    log "✅ Authorizer ENABLED"
    log "   토큰 없는 호출 → 401 (/health 는 항상 통과)"
    log "   원복: bash scripts/setup-authorizer.sh disable"
else
    log "✅ Authorizer DISABLED — 모든 경로 auth=NONE (토큰 없이도 통과)"
fi
