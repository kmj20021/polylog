#!/bin/bash
# polylog — Google ID 토큰 Lambda Authorizer(fn-authorizer)를 API Gateway 에 연결.
#
# 왜 필요한가:
#   deploy.sh 는 lambda:TagResource 차단으로 CloudFormation 을 못 써서, authorizer
#   리소스 생성·메서드 부착을 CLI 로 한 번 해줘야 한다(setup-*-route.sh 와 같은 이유).
#
# 단계(ADR-007 (다): 부품만 만들고 강제는 나중에):
#   bash scripts/setup-authorizer.sh           # ① authorizer 생성 + 호출권한만 (아직 강제 X)
#   bash scripts/setup-authorizer.sh enable    # ② 전 라우트에 강제(/health·OPTIONS 제외)
#   bash scripts/setup-authorizer.sh disable   # 강제 해제 → 다시 NONE
#
# 선행: fn-authorizer 람다가 배포돼 있어야 함 → 먼저 bash scripts/deploy.sh.
# 다시 실행해도 안전(이미 만들어진 부분은 건너뜀).

set -euo pipefail

REGION=ap-northeast-2
ACCOUNT_ID=443370697536
API_NAME="polylog-api"
FUNC="polylog-fn-authorizer"
AUTHORIZER_NAME="polylog-google-authorizer"
MODE="${1:-create}"   # create | enable | disable

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC}"
# authorizer 가 람다를 호출할 때 쓰는 invocation URI(라우트 통합 URI 와 형식 동일).
AUTHORIZER_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
die()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

# ── 0. 람다 존재 확인 ─────────────────────────────────────────
aws lambda get-function --function-name "$FUNC" --region "$REGION" >/dev/null 2>&1 \
  || die "$FUNC 람다가 없습니다. 먼저 'bash scripts/deploy.sh' 로 배포하세요."

# ── 1. API ID ─────────────────────────────────────────────────
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id" --output text)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] || die "API '$API_NAME' 없음."
log "API_ID=$API_ID  (mode=$MODE)"

# ── 2. authorizer 생성(없으면) ────────────────────────────────
AUTHORIZER_ID=$(aws apigateway get-authorizers --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?name=='$AUTHORIZER_NAME'].id" --output text)

if [ -z "$AUTHORIZER_ID" ] || [ "$AUTHORIZER_ID" = "None" ]; then
    log "authorizer 생성: $AUTHORIZER_NAME (TOKEN, Authorization 헤더)"
    AUTHORIZER_ID=$(aws apigateway create-authorizer \
      --rest-api-id "$API_ID" \
      --name "$AUTHORIZER_NAME" \
      --type TOKEN \
      --authorizer-uri "$AUTHORIZER_URI" \
      --identity-source "method.request.header.Authorization" \
      --authorizer-result-ttl-in-seconds 300 \
      --region "$REGION" --query 'id' --output text)
else
    warn "authorizer 이미 있음 ($AUTHORIZER_ID)"
fi

# ── 3. API Gateway 가 authorizer 람다를 호출하도록 권한 부여 ──
aws lambda add-permission --function-name "$FUNC" \
  --statement-id "apigw-authorizer-invoke" \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/authorizers/${AUTHORIZER_ID}" \
  --region "$REGION" >/dev/null 2>&1 \
  && log "authorizer 호출권한 부여" \
  || warn "authorizer 호출권한 이미 있음(건너뜀)"

# ── 4. enable/disable 시 메서드 인가 일괄 변경 ────────────────
apply_methods() {
    local TARGET_TYPE=$1   # CUSTOM(강제) | NONE(해제)
    aws apigateway get-resources --rest-api-id "$API_ID" --embed methods \
      --region "$REGION" > /tmp/polylog-resources.json

    # /health 와 OPTIONS 는 제외(헬스체크 무인증 + CORS preflight 보호 회피).
    python3 - <<'PYEOF' | while read -r RID METHOD; do
import json
with open('/tmp/polylog-resources.json') as f:
    data = json.load(f)
for it in data.get('items', []):
    if it.get('path') == '/health':
        continue
    for m in (it.get('resourceMethods') or {}):
        if m == 'OPTIONS':
            continue
        print(it['id'], m)
PYEOF
        if [ "$TARGET_TYPE" = "CUSTOM" ]; then
            aws apigateway update-method --rest-api-id "$API_ID" --resource-id "$RID" \
              --http-method "$METHOD" --region "$REGION" \
              --patch-operations \
                op=replace,path=/authorizationType,value=CUSTOM \
                op=replace,path=/authorizerId,value="$AUTHORIZER_ID" >/dev/null
            log "  ✓ $METHOD (res $RID) → CUSTOM(인증 필요)"
        else
            aws apigateway update-method --rest-api-id "$API_ID" --resource-id "$RID" \
              --http-method "$METHOD" --region "$REGION" \
              --patch-operations op=replace,path=/authorizationType,value=NONE >/dev/null
            log "  ✓ $METHOD (res $RID) → NONE(공개)"
        fi
    done
}

case "$MODE" in
  enable)
    log "전 라우트에 authorizer 강제(/health·OPTIONS 제외)"
    apply_methods CUSTOM
    log "dev 스테이지 재배포"
    aws apigateway create-deployment --rest-api-id "$API_ID" \
      --stage-name dev --region "$REGION" --query 'id' --output text >/dev/null
    log "✅ 인증 강제 활성화 — 이제 유효한 Google 토큰 없는 요청은 401."
    ;;
  disable)
    log "authorizer 강제 해제(모든 메서드 NONE)"
    apply_methods NONE
    log "dev 스테이지 재배포"
    aws apigateway create-deployment --rest-api-id "$API_ID" \
      --stage-name dev --region "$REGION" --query 'id' --output text >/dev/null
    log "✅ 인증 강제 해제 — 모든 라우트 공개(auth=NONE)."
    ;;
  *)
    log "✅ authorizer 준비 완료(id=$AUTHORIZER_ID). 아직 강제하지 않음."
    echo ""
    echo "토큰 흐름 확인 후 강제하려면:  bash scripts/setup-authorizer.sh enable"
    echo "되돌리려면:                    bash scripts/setup-authorizer.sh disable"
    ;;
esac
