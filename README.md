# polylog

AI 여행 앱 PoC. 기획·요구사항·아키텍처 결정은 다음 문서를 참조:

- `docs/polylog-plan.md` — 핵심 기획안 (단일 진실 원천)
- `docs/requirements.md` — 요구사항(FR/NFR/TR)
- `docs/wbs.md` — 작업 분해
- `docs/ADR.md` — 아키텍처 결정 기록
- `docs/bootstrap-plan.md` — 0→1 환경 구축 플랜 (Phase 0~4)
- `docs/polylog-iam-guide.md` — 관리자 IAM 발급 가이드(환경 제약의 출처)
- `docs/archive/` — 보존용(드물게 참조): vision, schedule, mk_DynamoDB_logic

---

## 자원 소유·격리 규칙 (중요)

shingu-cs 계정(`443370697536`)은 4명이 **같은 네임스페이스를 공유**한다(`docs/polylog-iam-guide.md` 격리 모델).
본 레포가 만든 모든 AWS 자원의 owner는 **`polylog-1`** 이다.

- 모든 자원 이름은 **`polylog` prefix 필수** (위반 시 생성 거부).
- 자동 부착 태그 `group=polylog`, `username` 은 **수동 변경 불가** — 그대로 둔다.
- 실행 역할은 공용 **`SafeRole-polylog`** 재사용. `iam:CreateRole` 차단(ADR-012).
- **Access Key 미발급** → 로컬 `sam deploy`/`sam local` 불가. **모든 배포는 콘솔 CloudShell**(ADR-013).
- Cognito 미제공 → 소셜 OAuth(**Google 단독**, Android) + `fn-authorizer`(ADR-007).
- CloudFront 차단 → S3 Presigned URL(ADR-008).
- Bedrock은 us-east-1 cross-region 호출(ADR-009). 그 외 자원은 ap-northeast-2.

---

## 배포 (CloudShell 전용)

> **주의**: `sam deploy` 대신 `scripts/deploy.sh`를 사용한다.
> `lambda:TagResource` 차단으로 SAM/CloudFormation이 Lambda 생성 직후 `GetFunction` 폴링에서 실패함.
> AutoTagging-Function이 약 20초 후 `group=polylog` 태그를 비동기 부착하므로, 스크립트에서 대기 후 진행.

```bash
# 사전: polylog-sam-deploy 버킷이 존재해야 함 (Phase 2.2)
cd polylog
bash scripts/deploy.sh
# → 빌드 → S3 업로드 → Lambda 생성/업데이트 → API 재배포 → 헬스체크 자동 검증
# → {"status": "ok", "service": "polylog"}
```

새 Lambda 함수 추가 시 `scripts/deploy.sh` 하단의 함수 목록에 한 줄 추가:
```bash
deploy_lambda "polylog-fn-xxx" "$(get_s3_key FnXxx)" "app.lambda_handler" 10 128
```

## 디렉토리 구조

```
backend/
├── template.yaml                  # SAM IaC (Globals.Function.Role = SafeRole-polylog)
├── samconfig.toml                 # stack=polylog-backend, bucket=polylog-sam-deploy
└── src/handlers/
    ├── health/app.py              # fn-health (200 OK)
    ├── authorizer/app.py          # fn-authorizer 골격 (Phase 4에서 Google JWKS 검증 구현)
    └── requirements.txt
app/                               # Flutter (Phase 4에서 생성)
```
