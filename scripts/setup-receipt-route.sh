#!/bin/bash
# polylog — /receipt 라우트(POST)를 fn-receipt 람다에 연결하는 1회용 셋업.
#
# 왜 필요한가:
#   deploy.sh 는 lambda:TagResource 차단으로 CloudFormation(sam deploy)을 못 써서,
#   람다는 CLI 로 직접 만들고 API Gateway 는 '이미 있는' 스테이지를 재배포만 한다.
#   → 새 경로(/receipt)의 리소스·메서드·통합·호출권한은 이렇게 한 번 만들어 줘야 한다.
#
# 사용법(CloudShell, 1회):
#   1) fn-receipt 람다가 먼저 배포돼 있어야 함 → bash scripts/deploy.sh 먼저.
#   2) bash scripts/setup-receipt-route.sh
#   (이미 만들어진 부분은 건너뛰므로 다시 실행해도 안전.)

set -euo pipefail

REGION=ap-northeast-2
ACCOUNT_ID=443370697536
API_NAME="polylog-api"
FUNC="polylog-fn-receipt"
PATH_PART="receipt"

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC}"
INTEGRATION_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
die()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

# ── 0. 람다 존재 확인 ─────────────────────────────────────────
aws lambda get-function --function-name "$FUNC" --region "$REGION" >/dev/null 2>&1 \
  || die "$FUNC 람다가 없습니다. 먼저 'bash scripts/deploy.sh' 로 배포하세요."

# ── 1. API ID / 루트 리소스 ───────────────────────────────────
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id" --output text)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] || die "API '$API_NAME' 없음."
log "API_ID=$API_ID"

ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/'].id" --output text)

# ── 2. /receipt 리소스(없으면 생성) ───────────────────────────
RES_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/${PATH_PART}'].id" --output text)
if [ -z "$RES_ID" ] || [ "$RES_ID" = "None" ]; then
    log "/${PATH_PART} 리소스 생성"
    RES_ID=$(aws apigateway create-resource \
      --rest-api-id "$API_ID" --parent-id "$ROOT_ID" \
      --path-part "$PATH_PART" --region "$REGION" \
      --query 'id' --output text)
else
    warn "/${PATH_PART} 리소스 이미 있음 ($RES_ID)"
fi

# ── 3. 메서드 + Lambda 프록시 통합 + 호출권한 ─────────────────
wire_method() {
    local METHOD=$1
    log "  $METHOD /${PATH_PART} 메서드/통합"

    # 메서드(있으면 건너뜀)
    if aws apigateway get-method --rest-api-id "$API_ID" --resource-id "$RES_ID" \
         --http-method "$METHOD" --region "$REGION" >/dev/null 2>&1; then
        warn "    메서드 $METHOD 이미 있음"
    else
        aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" \
          --http-method "$METHOD" --authorization-type NONE \
          --region "$REGION" >/dev/null
    fi

    # 통합(AWS_PROXY — 람다 프록시. 람다 호출은 항상 POST 로 보냄)
    aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" \
      --http-method "$METHOD" --type AWS_PROXY \
      --integration-http-method POST --uri "$INTEGRATION_URI" \
      --region "$REGION" >/dev/null

    # API Gateway 가 이 람다를 호출하도록 허용(이미 있으면 무시)
    aws lambda add-permission --function-name "$FUNC" \
      --statement-id "apigw-${PATH_PART}-${METHOD}" \
      --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
      --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/${METHOD}/${PATH_PART}" \
      --region "$REGION" >/dev/null 2>&1 \
      && log "    호출권한 부여" \
      || warn "    호출권한 이미 있음(건너뜀)"
}

wire_method POST

# ── 4. 스테이지 재배포 ────────────────────────────────────────
log "dev 스테이지 재배포"
aws apigateway create-deployment --rest-api-id "$API_ID" \
  --stage-name dev --region "$REGION" --query 'id' --output text >/dev/null

BASE="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev/${PATH_PART}"
log "✅ 완료 — 엔드포인트: $BASE"
echo ""
echo "검증(영수증 사진 receipt.jpg 준비 후):"
echo "  B64=\$(base64 -w0 receipt.jpg)"
echo "  curl -s -X POST \"$BASE\" -H 'Content-Type: application/json' \\"
echo "    -d \"{\\\"trip_id\\\":\\\"demo-trip\\\",\\\"image_base64\\\":\\\"\$B64\\\",\\\"home_currency\\\":\\\"KRW\\\"}\" | python3 -m json.tool"
