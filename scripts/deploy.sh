#!/bin/bash
# polylog backend 배포 스크립트
#
# lambda:TagResource 차단으로 SAM/CloudFormation deploy 불가.
# AutoTagging-Function이 ~20초 후 태그를 비동기 부착하므로,
# Lambda 신규 생성 시 태그가 붙을 때까지 대기 후 다음 단계로 진행.
#
# 사용법:
#   cd polylog && bash scripts/deploy.sh

set -euo pipefail

REGION=ap-northeast-2
ACCOUNT_ID=443370697536
S3_BUCKET=polylog-sam-deploy
SAFE_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/SafeRole-polylog"
API_NAME="polylog-api"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
die()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# ────────────────────────────────────────────
# 1. sam build
# ────────────────────────────────────────────
log "sam build"
cd backend
sam build
cd ..

# ────────────────────────────────────────────
# 2. sam package — 코드 S3 업로드 + packaged.yaml 생성
# ────────────────────────────────────────────
log "S3 패키징 (sam package)"
cd backend
sam package \
  --s3-bucket "$S3_BUCKET" \
  --s3-prefix polylog-backend \
  --region "$REGION" \
  --output-template-file /tmp/polylog-packaged.yaml
cd ..

# ────────────────────────────────────────────
# 3. Lambda 배포 함수
#    - 신규: create → AutoTagging 대기
#    - 기존: update-function-code
# ────────────────────────────────────────────
deploy_lambda() {
    local FUNC_NAME=$1   # e.g. polylog-fn-health
    local S3_KEY=$2      # e.g. polylog-backend/abc123
    local HANDLER=$3     # e.g. app.lambda_handler
    local TIMEOUT=${4:-10}
    local MEMORY=${5:-128}

    log "Lambda: $FUNC_NAME"

    if aws lambda list-functions --region "$REGION" \
         --query "Functions[?FunctionName=='$FUNC_NAME'].FunctionName" \
         --output text 2>/dev/null | grep -q "$FUNC_NAME"; then
        # 기존 함수 — 코드만 교체
        log "  코드 업데이트"
        aws lambda update-function-code \
          --function-name "$FUNC_NAME" \
          --s3-bucket "$S3_BUCKET" \
          --s3-key "$S3_KEY" \
          --region "$REGION" --output text --query 'CodeSize' > /dev/null
        aws lambda wait function-updated \
          --function-name "$FUNC_NAME" --region "$REGION"
        log "  ✅ 업데이트 완료"
    else
        # 신규 함수 — 생성 후 AutoTagging 대기
        log "  신규 생성"
        aws lambda create-function \
          --function-name "$FUNC_NAME" \
          --runtime python3.12 \
          --role "$SAFE_ROLE" \
          --handler "$HANDLER" \
          --code "S3Bucket=$S3_BUCKET,S3Key=$S3_KEY" \
          --timeout "$TIMEOUT" \
          --memory-size "$MEMORY" \
          --tracing-config Mode=Active \
          --region "$REGION" --output text --query 'FunctionArn' > /dev/null

        warn "  AutoTagging-Function 대기 중 (group=polylog 태그)..."
        until aws lambda list-tags \
            --resource "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC_NAME}" \
            --region "$REGION" --query 'Tags.group' --output text 2>/dev/null \
            | grep -q "polylog"; do
          sleep 5
        done
        log "  ✅ 태그 적용 완료 → GetFunction 접근 허용됨"
    fi
}

# ────────────────────────────────────────────
# 4. packaged.yaml에서 S3 키 추출
# ────────────────────────────────────────────
get_s3_key() {
    local LOGICAL_ID=$1
    python3 - <<PYEOF
import yaml
with open('/tmp/polylog-packaged.yaml') as f:
    t = yaml.safe_load(f)
r = t.get('Resources', {}).get('$LOGICAL_ID', {})
uri = r.get('Properties', {}).get('CodeUri', '')
bucket = '$S3_BUCKET'
key = uri.split(bucket + '/')[1] if bucket + '/' in uri else ''
print(key)
PYEOF
}

# ────────────────────────────────────────────
# 5. 함수 목록 — 새 함수 추가 시 여기에만 추가
# ────────────────────────────────────────────
deploy_lambda "polylog-fn-health" \
  "$(get_s3_key FnHealth)" \
  "app.lambda_handler" 10 128

deploy_lambda "polylog-fn-recommend" \
  "$(get_s3_key FnRecommend)" \
  "app.lambda_handler" 30 128

deploy_lambda "polylog-fn-schedule" \
  "$(get_s3_key FnSchedule)" \
  "app.lambda_handler" 10 128

# ────────────────────────────────────────────
# 5-1. fn-recommend 환경변수 주입 (Google Places 키)
#   update-function-code 는 코드만 갱신하고 환경변수는 건드리지 않는다.
#   → 키가 없으면 Places 호출이 500. 셸에 키가 있을 때만 주입한다.
#   사용법(CloudShell): export GOOGLE_PLACES_API_KEY=... && bash scripts/deploy.sh
#   키는 셸 환경에서만 읽으며 스크립트·git 에 하드코딩하지 않는다.
# ────────────────────────────────────────────
if [ -n "${GOOGLE_PLACES_API_KEY:-}" ]; then
    log "fn-recommend 환경변수 주입 (GOOGLE_PLACES_API_KEY)"
    aws lambda update-function-configuration \
      --function-name "polylog-fn-recommend" \
      --environment "Variables={GOOGLE_PLACES_API_KEY=$GOOGLE_PLACES_API_KEY}" \
      --region "$REGION" --output text --query 'LastModified' > /dev/null
    aws lambda wait function-updated \
      --function-name "polylog-fn-recommend" --region "$REGION"
    log "  ✅ 키 주입 완료"
else
    warn "GOOGLE_PLACES_API_KEY 미설정 → fn-recommend 환경변수 주입 건너뜀"
    warn "   (이 상태로 /recommend 호출 시 500. export 후 다시 배포하세요.)"
fi

# 추후 추가 예시:
# deploy_lambda "polylog-fn-authorizer" "$(get_s3_key FnAuthorizer)" "app.lambda_handler" 10 128

# ────────────────────────────────────────────
# 6. API Gateway 재배포 (스테이지 갱신)
# ────────────────────────────────────────────
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id" --output text)

if [ -z "$API_ID" ]; then
    warn "API Gateway '$API_NAME' 없음. scripts/setup-apigw.sh를 먼저 실행하세요."
else
    log "API Gateway 재배포: $API_ID (dev 스테이지)"
    aws apigateway create-deployment \
      --rest-api-id "$API_ID" \
      --stage-name dev \
      --region "$REGION" --output text --query 'id' > /dev/null
    log "  ✅ 배포 완료"

    # ────────────────────────────────────────
    # 7. 헬스체크 검증
    # ────────────────────────────────────────
    HEALTH_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev/health"
    log "헬스체크: $HEALTH_URL"
    RESPONSE=$(curl -s "$HEALTH_URL")
    echo "$RESPONSE" | python3 -m json.tool
    echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); exit(0 if r.get('status')=='ok' else 1)" \
      && log "✅ Phase 3 배포 성공" \
      || die "헬스체크 실패: $RESPONSE"
fi
