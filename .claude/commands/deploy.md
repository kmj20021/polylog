# polylog 백엔드 배포

`scripts/deploy.sh`를 실행해 Lambda 함수와 API Gateway를 배포합니다.

## 실행

```bash
cd /home/cloudshell-user/polylog && bash scripts/deploy.sh
```

## 이 스크립트가 하는 일

1. `sam build` — Lambda 코드 빌드
2. `sam package` — S3(`polylog-sam-deploy`)에 코드 업로드
3. 각 Lambda 함수 배포:
   - 신규 함수: `create-function` → `list-tags` 폴링으로 `group=polylog` 자동 태깅 확인 (5초 간격)
   - 기존 함수: `update-function-code`로 코드만 교체
4. API Gateway `dev` 스테이지 재배포
5. `/health` 헬스체크 자동 검증

## 주의사항

- `sam deploy`는 사용 불가 (`lambda:GetFunction` 계정 정책으로 차단)
- 신규 함수 생성 시 자동 태깅까지 20~30초 소요 — 스크립트가 자동 대기
- 새 Lambda 함수 추가 시 `scripts/deploy.sh` 섹션 5에 `deploy_lambda` 호출 한 줄 추가

## 배포 후 검증

```bash
BASE_URL="https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev"

# 헬스체크
curl -s "$BASE_URL/health"

# AI 추천 테스트
curl -s -X POST "$BASE_URL/recommend" \
  -H "Content-Type: application/json" \
  -d '{"location": "도쿄 신주쿠", "category": "맛집"}'
```
