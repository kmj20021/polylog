# IAM User 발급 드립니다 (Polylog)

---

## 1. 로그인

- **접속 URL:** https://shingu-cs.signin.aws.amazon.com/console
- **Account ID:** shingu-cs (또는 443370697536) — 이미 입력되어 있으면 그대로 두세요
- 아래 입력칸에 IAM username / Password 입력

---

## 2. 유저 정보

- **멤버:** polylog-1, polylog-2, polylog-3, polylog-4
- **초기 Password** = 본인 IAM Username
- 최초 로그인 후 Password 반드시 변경

---

## 3. 사용 가능 서비스 및 주의사항

### ✅ 허가된 서비스

- Bedrock (Claude Haiku) · Textract · Translate · Lambda · API Gateway · DynamoDB · S3 · CloudWatch Logs · CloudFormation/SAM

### 🌍 리전 — 서울 ap-northeast-2 고정 (Bedrock만 예외)

- 모든 자원은 서울에서 생성
- Bedrock(Claude)만 us-east-1에서 호출 — Lambda 코드 안 client 리전만 다르게 잡으면 됩니다
- 뭔가 안 되면 제일 먼저 리전부터 확인

### 🧠 Bedrock / Textract / Translate

- Lambda는 서울, Bedrock 호출만 리전 지정:
  ```python
  boto3.client("bedrock-runtime", region_name="us-east-1")
  ```
- Textract, Translate는 서울에서 호출 OK

### ⚡ Lambda / API Gateway / SAM 배포

- 실행 역할은 기존 **SafeRole-polylog**를 공용으로 사용

  이 역할에 Bedrock / Textract / Translate / DynamoDB (polylog*) / S3 (polylog*) / CloudWatch Logs 권한이 모두 들어 있습니다.
  네 함수 따로 만드는 분리 효과보다, polylog prefix·태그 격리로 이미 blast radius가 그룹 내부로 한정되어 있어 차이가 거의 없습니다.
  운영 단계에서 다시 검토하면 충분합니다.

- `iam:CreateRole`은 차단되어 있어 학생이 새 역할을 만들 수도 없습니다 — SAM 템플릿에서 `Globals.Function.Role`로 한 줄:

  ```yaml
  Globals:
    Function:
      Role: !Sub arn:aws:iam::${AWS::AccountId}:role/SafeRole-polylog
  ```

- 배포는 콘솔 CloudShell에서 `sam deploy` (Access Key 미발급이라 로컬 X)
- 첫 배포 전 SAM 배포 버킷을 직접 만들어 주세요

  `sam deploy --guided`가 기본 생성하는 `aws-sam-cli-managed-default-...` 이름은 polylog prefix 위반이라 거부됩니다:

  ```bash
  aws s3 mb s3://polylog-sam-deploy --region ap-northeast-2
  sam deploy --guided --s3-bucket polylog-sam-deploy --stack-name polylog-backend
  ```

- 함수 생성 직후 5초 정도 지연 (새로고침하면 정상)

### 🪣 S3 / DynamoDB — 이름은 반드시 `polylog`로 시작

- S3 예: `polylog-media`, `polylog-sam-deploy`
- DynamoDB 예: `polylog-users`, `polylog-trips`, `polylog-expenses`
- prefix가 안 맞으면 생성 자체가 거부됩니다
- 팀원 4명이 같은 리소스를 공유합니다 (자동 부착되는 `group=polylog` 태그 기준)
- 태그(username, group)는 자동 부착, 수동 변경 불가

### 🔑 Access Key는 절대 발급 불가 → IAM Role 사용

- Lambda: `SafeRole-polylog`
- EC2 (필요 시): `SafeInstanceProfile-polylog`

---

## 🚫 Cognito는 제공하지 않습니다

원칙은 두 가지입니다.

- **You Are Not Google** — 트래픽이 없는 단계에서 구글급 아키텍처는 비용·시간·복잡도만 늘립니다.
- **Premature optimization is the root of all evil** — "혹시 모르니까"로 도입한 것 대부분은 실제로 필요해진 적이 없습니다.

### 왜 신청하셨을지

"진짜 서비스처럼" 보이고 싶거나, 비밀번호 처리가 무서워서.

### 왜 Over-engineering인가

Cognito는 MFA · SSO · 사용자 풀 관리 등 운영 서비스용 추상화입니다.
시연용 계정으로 들어오는 정도라면 학습 곡선만 가파르고, 디버깅 시 IAM · 트리거 람다 · 콜백 URL까지 얽혀 시간 손실이 큽니다.
Polylog의 4개 핵심 기능(AI 추천 · 메뉴 번역 · 영수증 · 일정)과 인증 학습은 별개 트랙이라, PoC 기간엔 Cognito 디버깅에 들어갈 시간을 본질에 쓰시는 게 낫습니다.

### 대안 (권장 순서)

1. **가장 간단:** 로그인 없이 시연 (게스트 모드 / 시연용 mock 계정). Polylog 4개 기능은 인증 없이도 전부 시연 가능합니다.
2. **학습 가치까지 챙기고 싶다면:** 직접 구현한 JWT 인증 — `polylog-users` DynamoDB 테이블에 이메일 + bcrypt 해시 저장 → 로그인 Lambda에서 JWT 발급 → API Gateway Lambda Authorizer로 검증. PoC 규모면 30~50줄.
3. **소셜 로그인이 꼭 필요하면:** Google/Kakao OAuth를 Flutter 클라이언트에서 직접 연동 (백엔드 인프라 불필요).

### 그 외 막혀 있는 것들 (요청 안 하셨지만 흔히 묻는 항목)

Route 53, ACM, CloudFront, ElastiCache, ELB/ASG, EKS, MSK, Fine tuning, Provisioned Throughput, Access Key

모두 같은 두 원칙 — "You Are Not Google" + "Premature optimization" — 으로 정리되어 있습니다. 필요하면 별도로 사유 안내드립니다.

---

## ⚠️ 격리 모델

팀 polylog 4명은 서로의 자원을 자유롭게 관리할 수 있습니다 (다른 그룹 자원은 불가)

누가 뭘 owning하는지 팀 내에서 이름·README 컨벤션 정해두는 걸 권장합니다.

---

추가 필요한 권한은 **#999-general-tech-qna** 채널로 문의주세요. 모든 요청이 승인되는 것은 아닙니다.
