# Polylog — 프로젝트 착수(Bootstrap) 플랜

> 본 플랜은 **코드 작성 단계로 진입하기 위한 모든 기초 구성**을 정리합니다.
> 메인 기능(fn-recommend) 구현 직전까지의 "0→1 환경 구축"이 범위입니다.

---

## Context

### 왜 이 플랜이 필요한가
- 현재 `C:\Users\user\my_pj\polylog`에는 기획·요구사항·WBS·ADR·일정·비전 문서만 존재하고 **코드(SAM 템플릿, Lambda, Flutter)는 0줄**입니다.
- `polylog-iam-guide.md`(2026-05-27)가 환경 제약을 확정했기 때문에, WBS 1.2의 추상적인 "AWS 환경 구축" 항목들이 **구체적 절차**로 풀려야 첫 코드를 안전하게 짤 수 있습니다.
- IAM 가이드가 강제하는 5개의 결정 — ① `polylog` prefix 강제 ② `iam:CreateRole` 차단(공용 `SafeRole-polylog` 강제) ③ Access Key 미발급(로컬 `sam deploy` 불가, CloudShell 전용) ④ Cognito 미제공(소셜 OAuth+`fn-authorizer`) ⑤ CloudFront 차단(Presigned URL) — 이 작업 순서·도구 선택을 모두 바꿉니다.

### 의도한 결과 (Exit State)
이 플랜이 끝나면 다음이 모두 만족됩니다.
1. `polylog-1` IAM 콘솔에 MFA 보호 상태로 로그인 가능 (Access Key 없이)
2. CloudShell에서 `sam deploy`로 `fn-health` 1종이 배포되어 API Gateway URL로 200 응답
3. `polylog-media`, `polylog-sam-deploy` S3 버킷과 DynamoDB 7종(`polylog-*`) 테이블 존재
4. Bedrock(Claude Haiku) us-east-1 모델 액세스 승인 완료
5. Google OAuth 클라이언트(Android) 등록 완료(redirect URI/scheme 포함) — Kakao 보류(ADR-007)
6. Flutter 3.x 프로젝트 스켈레톤(Android 전용) + 4탭 네비게이션 + dio API 클라이언트 + `polylog-1` 계정으로 fn-health 호출 성공
7. Git 저장소 초기 커밋(`template.yaml`, Flutter 앱, `.gitignore`, README) 완료

이 시점부터 WBS 1.4(메인 기능)로 즉시 진입 가능.

---

## 작업 흐름 (5 Phase)

```
Phase 0  ─ Day 0   IAM 수령·MFA·비밀번호 변경 (오프라인 가능)
Phase 1  ─ Day 0~1 외부 의존성 트리거 (Bedrock 액세스·OAuth 등록 — 승인/대기 시간 확보)
Phase 2  ─ Day 1~2 콘솔/CloudShell 인프라 프로비저닝 (S3, DynamoDB)
Phase 3  ─ Day 2~3 SAM 첫 배포 (fn-health + Authorizer skeleton)
Phase 4  ─ Day 3~5 Flutter 스켈레톤 + 인증 흐름 + E2E 관통
```

병렬 가능: Phase 1의 외부 승인 대기 동안 Phase 2~4 진행.

---

## Phase 0 — IAM 수령 및 보안 기본 (Day 0)

WBS 1.2.1.1 / 가이드 §1~2

| # | 작업 | 비고 |
|---|---|---|
| 0.1 | `https://shingu-cs.signin.aws.amazon.com/console`에서 본인 IAM(예: `polylog-1`)으로 로그인. 초기 PW = username | Account ID `443370697536` |
| 0.2 | **비밀번호 즉시 변경** | 가이드 §2 |
| 0.3 | **MFA(가상 디바이스, Authenticator 앱) 등록** | NFR-S 기본기 |
| 0.4 | 리전 셀렉터를 **서울(ap-northeast-2)로 고정** | Bedrock 호출만 코드에서 us-east-1 지정 |
| 0.5 | Console에서 **`iam:CreateRole` 차단·Access Key 미발급** 사실 시각 확인 (시도해서 거부되는지 1회 체험) | 향후 디버깅 시 헷갈리지 않기 위함 |

> **Access Key는 절대 발급되지 않습니다.** `aws configure`로 로컬 자격증명을 시도하지 마세요. 모든 배포는 CloudShell.

---

## Phase 1 — 외부 의존성 트리거 (Day 0~1, 승인 대기 발생)

이 단계는 **타인의 승인이 걸려 있는 비동기 작업**이므로 가장 먼저 트리거합니다.

### 1.1 Bedrock 모델 액세스 요청 — WBS 1.2.6.1 / ADR-009
- 콘솔 리전을 **us-east-1**로 전환
- Bedrock → "Model access" → **Claude 3 Haiku** Request access
- 승인 ETA: 수 시간 ~ 1일 (관리자 승인 필요할 수 있음). 미승인 시 Mock 응답으로 우회 가능(archive/schedule.md R-2)

### 1.2 Google OAuth 클라이언트 등록 — WBS 1.2.5.1 / ADR-007 (2026-06-01 Google 단독 확정)
- Google Cloud Console → OAuth 2.0 클라이언트 ID 생성(**Android 전용** — iOS 범위 밖)
- Kakao는 보류(ADR-007 2026-06-01 갱신). 필요 시 후속 ADR로 재개.
- redirect URI는 Flutter 클라이언트 SDK가 처리하므로 SDK 문서의 default scheme을 그대로 등록
- 발급된 키는 일단 **로컬 메모장**에 보관(가이드상 별도 Secret 저장소 없이 Lambda 환경변수로 일원화 — ADR-006 갱신)

### 1.3 Google Places API & ExchangeRate-API 키 발급 — WBS 외(외부)
- Google Cloud → Places API 활성화 → API Key 생성 → **HTTP referer/IP 제한**(또는 API restriction = Places API만)
- ExchangeRate-API 무료 키 등록
- 동일하게 로컬 보관(나중에 Lambda 환경변수로 주입)

### 1.4 (필요 시) 추가 권한 요청 채널 확인
- **#999-general-tech-qna** 채널 위치/접근 확인
- 향후 막힐 가능성 있는 항목: 새 AWS 서비스, `SafeRole-polylog` 권한 확장(이 단계에서는 요청할 필요 없음)

---

## Phase 2 — 인프라 프로비저닝 (CloudShell + Console)

콘솔 우상단 CloudShell 아이콘을 열고 모든 명령을 거기서 실행합니다.

### 2.1 사전 점검 — 가이드 §3
다음 사실들을 콘솔에서 눈으로 1회 확인(생성 절차 X, 존재 확인):
- IAM → Roles → **`SafeRole-polylog`** 존재 확인 (ARN 메모: `arn:aws:iam::443370697536:role/SafeRole-polylog`)
- (선택) EC2 사용 시 `SafeInstanceProfile-polylog` 존재 확인

### 2.2 S3 버킷 2종 생성 — WBS 1.2.2 / ADR-013
**모든 자원 이름은 `polylog`로 시작해야 합니다.** prefix 미준수 시 생성 자체가 거부됩니다.

CloudShell에서:
```bash
# 배포 산출물 버킷 (sam deploy --guided 기본 이름은 prefix 위반 → 직접 생성 필수)
aws s3 mb s3://polylog-sam-deploy --region ap-northeast-2

# 미디어 버킷 (메뉴판/영수증 사진)
aws s3 mb s3://polylog-media --region ap-northeast-2

# SSE 암호화 (NFR-S1)
aws s3api put-bucket-encryption --bucket polylog-media \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 퍼블릭 액세스 차단 (CloudFront 미사용 → Presigned URL 전제, ADR-008)
aws s3api put-public-access-block --bucket polylog-media \
  --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'
```

### 2.3 DynamoDB 테이블 7종 생성 — WBS 1.2.3 / DR-1~8
| 테이블 | PK | SK | GSI |
|---|---|---|---|
| `polylog-users` | `user_id` (S, = OAuth sub) | — | `email-index` |
| `polylog-trips` | `trip_id` (S) | — | `user_id-index` (user_id PK, start_date SK) |
| `polylog-recommendations` | `trip_id` (S) | `created_at` (S) | — |
| `polylog-menus` | `trip_id` (S) | `menu_id` (S) | — |
| `polylog-expenses` | `trip_id` (S) | `occurred_at` (S) | `category-index` |
| `polylog-schedules` | `trip_id` (S) | `start_time` (S) | — |
| `polylog-chatmessages` | `trip_id` (S) | `created_at` (S) | — |

**On-Demand 모드** (NFR-C 무료티어 활용). 콘솔에서 1개 만들어 보고 나머지는 SAM 템플릿으로 IaC화하는 것을 권장.

### 2.4 비용 모니터링
- Budgets 알람은 가이드상 **관리자 영역**(NFR-C3) → 본인은 콘솔 Cost Explorer에서 그룹 사용량만 주기 점검

---

## Phase 3 — SAM 첫 배포 (`fn-health` + Authorizer 골격)

### 3.1 SAM 프로젝트 스켈레톤
로컬에 다음 구조 생성(아직 코드 X, 골격만):
```
polylog/
├── backend/
│   ├── template.yaml            # SAM IaC (DynamoDB·API GW·Lambda 정의)
│   ├── samconfig.toml           # s3_bucket=polylog-sam-deploy, region=ap-northeast-2
│   └── src/
│       ├── handlers/
│       │   ├── health/app.py
│       │   └── authorizer/app.py   # JWKS 검증 스켈레톤 (지금은 deny-all)
│       └── requirements.txt
├── app/                         # Flutter (Phase 4에서 생성)
├── .gitignore                   # __pycache__, .aws-sam/, build/, .env 등
└── README.md
```

### 3.2 `template.yaml` 핵심 설정 — ADR-010·ADR-012
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Globals:
  Function:
    Runtime: python3.12
    Timeout: 10
    Role: !Sub arn:aws:iam::${AWS::AccountId}:role/SafeRole-polylog   # ★ 공용 역할 강제
    Tracing: Active
Resources:
  PolylogApi:
    Type: AWS::Serverless::Api
    Properties:
      StageName: dev
      # Authorizer는 Phase 4 인증 작업에서 활성화. 지금은 NONE.
  FnHealth:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: src/handlers/health/
      Handler: app.lambda_handler
      Events:
        Get:
          Type: Api
          Properties: { RestApiId: !Ref PolylogApi, Path: /health, Method: get }
Outputs:
  ApiUrl:
    Value: !Sub https://${PolylogApi}.execute-api.${AWS::Region}.amazonaws.com/dev
```

> `Globals.Function.Role` 한 줄이 ADR-012의 핵심 — `iam:CreateRole` 차단을 우회하지 않고 정공으로 푸는 방법.

### 3.3 CloudShell 배포 — ADR-013
로컬에서 git push → CloudShell에서 git clone (또는 zip 업로드) 후:
```bash
cd polylog/backend
sam build
sam deploy --guided \
  --s3-bucket polylog-sam-deploy \
  --stack-name polylog-backend \
  --region ap-northeast-2 \
  --capabilities CAPABILITY_IAM
```
- `--guided`는 첫 1회만. 응답 후 `samconfig.toml`에 기록되면 이후 `sam deploy`만으로 OK
- 함수 생성 직후 5초 정도 콘솔 반영 지연 (가이드 §3 마지막 항목)

### 3.4 헬스체크 검증
```bash
curl "$(aws cloudformation describe-stacks --stack-name polylog-backend \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)/health"
# → {"status":"ok"} 류 응답 확인
```

---

## Phase 4 — Flutter 스켈레톤 + E2E 관통

WBS 1.3 전반. 인증은 Phase 4에서 **skeleton만** 깔고, 실제 JWKS 검증 로직 완성은 메인 기능 이후로 미뤄도 무방(`fn-authorizer`는 무상태라 후행 추가 가능).

### 4.1 프로젝트 생성 — WBS 1.3.1
```powershell
flutter create app --org com.shingu.polylog --platforms=android
cd app
flutter pub add dio geolocator camera image_picker sqflite path_provider `
                google_sign_in connectivity_plus
```
> ADR-007(2026-06-01): Google 단독·Android 전용. `kakao_flutter_sdk_user`·iOS 타깃은 보류.

### 4.2 패키지 구조 (feature 기반) — WBS 1.3.1.3
```
lib/
├── main.dart
├── core/
│   ├── api/dio_client.dart        # baseUrl = ApiUrl, ID 토큰 인터셉터 (Phase 4.4)
│   ├── storage/sqflite_queue.dart # 오프라인 큐 (ADR-011, 골격만)
│   └── location/geolocator.dart
├── features/
│   ├── auth/                      # 소셜 로그인 화면
│   ├── recommend/                 # 메인 탭 (1.4에서 채움)
│   ├── menu/                      # 서브1
│   ├── receipt/                   # 서브2
│   └── schedule/                  # 서브3
└── shared/widgets/                # 카드/로딩/에러
```

### 4.3 네비게이션·테마 — WBS 1.3.2
- `BottomNavigationBar` 4탭 (추천·메뉴판·영수증·일정), Material 3 (`useMaterial3: true`)
- 각 탭은 placeholder Scaffold로 충분 — 실제 화면은 WBS 1.4~1.7에서 구현

### 4.4 dio 클라이언트 — WBS 1.3.4.1
- baseUrl을 Phase 3.4의 ApiUrl로 설정
- `InterceptorsWrapper`에서 `Authorization: Bearer <social_id_token>` 자동 첨부 스텁(토큰은 아직 없으니 옵셔널)
- `/health` 호출 버튼을 추천 탭 상단에 임시로 두고 200 OK 확인 → **E2E 관통 완료**

### 4.5 소셜 로그인 골격 — WBS 1.3.3 / ADR-007
- 로그인 화면(Google 버튼)만 만들고 `google_sign_in`으로 ID 토큰까지 받기 (Kakao 보류 — ADR-007)
- 받은 토큰을 콘솔에 print → 다음 단계에서 `fn-authorizer`가 JWKS 검증

---

## 핵심 파일 (모두 신규 생성)

| 위치 | 목적 |
|---|---|
| `backend/template.yaml` | SAM IaC — Globals.Function.Role 한 줄이 ADR-012의 결정을 코드화 |
| `backend/samconfig.toml` | `s3_bucket = polylog-sam-deploy`, region 고정 (ADR-013) |
| `backend/src/handlers/health/app.py` | 첫 Lambda. `{"statusCode":200,"body":"{\"status\":\"ok\"}"}` |
| `backend/src/handlers/authorizer/app.py` | JWKS 검증 골격(처음엔 `deny` 반환) |
| `app/lib/main.dart` + `app/lib/core/api/dio_client.dart` | E2E 관통 진입점 |
| `.gitignore` | `__pycache__/`, `.aws-sam/`, `build/`, `.dart_tool/`, `**/.env`, `**/google-services.json` |
| `README.md` | 가이드 §"격리 모델"에 따라 **이 자원은 polylog-1 owning** 컨벤션 명시 |

> 1인 개발(CON-6)이지만 그룹 4명이 같은 네임스페이스를 공유하므로(가이드 §"격리 모델"), 만든 자원의 owner를 README와 태그 컨벤션으로 자기 보호하는 것을 권장.

---

## 검증 (Verification)

각 Phase 종료 시 다음으로 확인.

| Phase | 검증 방법 | 통과 기준 |
|---|---|---|
| 0 | 콘솔 재로그인 + MFA 코드 입력 | 로그인 성공 + 우상단 사용자명 = `polylog-1` |
| 1 | Bedrock 콘솔(us-east-1) Model access 페이지 | Claude 3 Haiku = **"Access granted"** |
| 2 | `aws s3 ls`, `aws dynamodb list-tables` | 2버킷·7테이블 모두 `polylog-` prefix로 출력 |
| 3 | `curl <ApiUrl>/health` | HTTP 200 + JSON body |
| 4 | Flutter 앱(Android 에뮬레이터)에서 헬스 버튼 탭 | 화면에 200 OK 표시 |

추가 보호:
- 모든 자원 생성 직후 콘솔 "Tags" 탭에서 `group=polylog`, `username=polylog-1` 자동 태그가 부착됐는지 1회 확인(가이드: 자동 부착·수동 변경 불가)

---

## 명시적으로 다루지 않는 것 (Out of Scope)

이 플랜은 **착수**까지만 다룹니다. 다음은 의도적으로 후행:
- `fn-recommend` / `fn-menu` / `fn-receipt` / `fn-schedule` 비즈니스 로직 → WBS 1.4~1.7
- `fn-authorizer`의 JWKS 검증 실구현 → Phase 4 이후 별도 작업
- 오프라인 큐잉 동기화 로직 → WBS 1.4.3 (메인 기능 완성 후)
- 비용 알람 세팅 → 관리자 영역(NFR-C3)
- CI/CD(GitHub Actions) → 15주차 마무리 단계
- E2E 테스트 자동화 → WBS 1.8

---

## 막힘 가능 포인트와 사전 대응

| 막힘 | 원인 | 대응 |
|---|---|---|
| `aws s3 mb` 거부 | `polylog` prefix 누락 | 이름 재확인. 다른 prefix는 가이드가 거부 |
| `sam deploy` 실패: NoSuchBucket | `polylog-sam-deploy` 미생성 | Phase 2.2 먼저 수행 |
| `sam deploy` 실패: AccessDenied on iam:CreateRole | 함수에 `Role:` 지정 누락 → SAM이 새 역할 만들려고 시도 | `Globals.Function.Role` 또는 함수별 `Role` 명시 |
| `sam local invoke` 시도 시 자격증명 오류 | Access Key 미발급 | 로컬 실행 포기, CloudShell만 사용(ADR-013) |
| Bedrock 호출 실패: AccessDenied | us-east-1 미승인 또는 SafeRole 권한 누락 | Phase 1.1 승인 확인. 권한 누락 시 #999-general-tech-qna |
| OAuth ID 토큰 검증 실패 | redirect URI 불일치 | Google 콘솔에서 SDK가 요구하는 default scheme 재확인 |
