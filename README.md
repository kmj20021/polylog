# Polylog

> AWS 서버리스 기반 AI 여행 도우미 앱
> 장소 추천, 영수증 분석, 메뉴 번역, 대화형 일정 관리를 하나의 Android 앱에서 제공합니다.

## 프로젝트 개요

Polylog는 여행 중 반복되는 장소 검색, 외국어 확인, 지출 기록, 일정 변경 문제를 해결하기 위해 개발한 개인 프로젝트입니다.

Flutter 앱과 AWS 서버리스 백엔드로 구성했으며, 제한된 IAM 환경에서 인증, 배포, 자원 격리, 외부 API 연동을 직접 설계하고 구현했습니다.

* 개발 인원: 1인
* 플랫폼: Android
* 백엔드: AWS Lambda + API Gateway
* AI: Amazon Bedrock Claude
* 배포: AWS SAM + Bash 배포 스크립트

## 주요 기능

### AI 장소 추천

현재 위치와 카테고리를 기반으로 Google Places API에서 장소를 검색하고, Bedrock이 각 장소의 추천 이유를 생성합니다.

### 영수증 자동 가계부

영수증 이미지를 Bedrock Vision으로 분석해 날짜, 통화, 금액, 구매 항목을 추출합니다.

ExchangeRate API를 이용해 외화를 원화로 환산하고 식사, 교통, 숙박 등의 카테고리로 분류합니다.

### 대화형 일정 관리

자연어로 여행 일정을 요청할 수 있습니다.

```text
광화문에서 점심을 먹고 카페에 가는 일정 짜줘.
```

플래너는 이전 대화와 현재 일정을 조회하고, 필요한 경우 Google Places에서 장소를 검색한 뒤 Bedrock으로 동선을 제안합니다.

제안된 장소는 사용자가 확인한 후 실제 일정에 저장됩니다.

### 메뉴판 번역

초기에는 Bedrock Vision으로 직접 메뉴판을 분석했지만, 문자 인식 속도와 사용성을 고려해 현재는 Google Lens로 연결하도록 변경했습니다.

## 기술 스택

| 구분     | 기술                                |
| ------ | --------------------------------- |
| 앱      | Flutter, Dart                     |
| 서버     | AWS Lambda, Python 3.12           |
| API    | Amazon API Gateway                |
| 데이터베이스 | Amazon DynamoDB                   |
| 파일 저장  | Amazon S3                         |
| AI     | Amazon Bedrock Claude             |
| 장소 검색  | Google Places API                 |
| 환율     | ExchangeRate API                  |
| 인증     | Google Sign-In, Lambda Authorizer |
| 배포     | AWS SAM, AWS CLI, Bash            |

## 아키텍처

```text
Flutter Android App
        │
        ▼
Amazon API Gateway
        │
        ├─ Lambda Authorizer
        │      └─ Google ID Token 검증
        │
        ├─ fn-recommend
        │      ├─ Google Places
        │      └─ Amazon Bedrock
        │
        ├─ fn-receipt
        │      ├─ Amazon Bedrock Vision
        │      └─ ExchangeRate API
        │
        ├─ fn-schedule
        │      └─ DynamoDB
        │
        └─ fn-planner
               ├─ DynamoDB
               ├─ Google Places
               └─ Amazon Bedrock
```

AWS 자원은 주로 `ap-northeast-2`에 배치하고, Bedrock은 모델을 사용할 수 있는 `us-east-1`로 호출합니다.

## 주요 기술적 결정

### 서버리스 구조

여행 앱은 계속 실행되더라도 백엔드 요청은 장소 검색이나 영수증 분석처럼 사용자가 기능을 실행할 때만 발생합니다.

따라서 상시 서버보다 요청 단위로 실행되는 Lambda가 비용과 운영 측면에서 적합하다고 판단했습니다.

### 플래너와 일정 CRUD 분리

일정 저장과 조회는 가벼운 DynamoDB 작업이지만, AI 플래너는 Bedrock과 Places API를 호출해 처리 시간이 더 깁니다.

두 기능을 별도 Lambda로 분리해 AI 기능 장애가 기본 일정 조회까지 영향을 주지 않도록 했습니다.

### OCR 전략 변경

초기에는 Textract를 검토했지만 한글, 일본어, 중국어가 포함된 이미지에서 원하는 품질을 얻기 어려웠습니다.

영수증은 Bedrock Vision으로 변경했고, 메뉴판은 사용자 편의성을 고려해 Google Lens로 위임했습니다.

## 트러블슈팅

### 제한된 IAM 환경에서 배포

공유 AWS 계정에서 다음 기능이 제한됐습니다.

* IAM Role 생성
* Lambda 태그 직접 설정
* Access Key 발급
* Cognito
* CloudFront

Lambda 생성 직후 필수 태그가 붙기 전에 조회 요청이 실행되면서 일반적인 `sam deploy`가 실패했습니다.

이를 해결하기 위해 SAM은 빌드와 패키징에 사용하고, 실제 배포는 `scripts/deploy.sh`에서 AWS CLI로 수행했습니다.

```text
SAM Build
→ S3 패키징
→ Lambda 생성 또는 업데이트
→ 자동 태그 적용 대기
→ 환경변수 설정
→ API Gateway 재배포
→ 헬스체크
```

### Google 로그인 오류

Flutter 앱에서 발급된 ID 토큰의 `aud`와 Lambda Authorizer에 설정한 Google Client ID가 일치하지 않아 인증 오류가 발생했습니다.

Android OAuth 클라이언트와 웹 클라이언트의 역할을 구분하고, Authorizer가 올바른 Client ID를 검증하도록 수정했습니다.

## 배포

배포 전에 필요한 값을 CloudShell 환경변수로 설정합니다.

```bash
export GOOGLE_PLACES_API_KEY="<API_KEY>"
export EXCHANGE_RATE_API_KEY="<API_KEY>"
export GOOGLE_CLIENT_ID="<WEB_CLIENT_ID>"
```

배포 스크립트를 실행합니다.

```bash
bash scripts/deploy.sh
```

정상 배포 시 헬스체크 결과를 확인할 수 있습니다.

```json
{
  "status": "ok",
  "service": "polylog"
}
```

Authorizer 적용:

```bash
bash scripts/setup-authorizer.sh enable
```

## 앱 실행

```bash
cd app
flutter pub get
flutter run
```

실행 전 API Gateway 주소와 Google OAuth Android 설정이 필요합니다.

## 디렉터리 구조

```text
polylog/
├── app/                    # Flutter Android 앱
├── backend/
│   ├── template.yaml       # AWS SAM 설정
│   └── src/handlers/
│       ├── health/
│       ├── recommend/
│       ├── receipt/
│       ├── schedule/
│       ├── planner/
│       ├── menu/
│       └── authorizer/
├── scripts/
│   ├── deploy.sh
│   ├── setup-apigw.sh
│   └── setup-authorizer.sh
├── docs/
│   ├── requirements.md
│   ├── wbs.md
│   ├── ADR.md
│   └── polylog-iam-guide.md
└── README.md
```

## 현재 한계

* Android 환경만 검증했습니다.
* 메뉴판 번역은 Google Lens에 의존합니다.
* AI 응답은 동일한 입력에서도 달라질 수 있습니다.
* 외부 API 장애와 사용량 제한의 영향을 받습니다.
* 현재 배포 스크립트는 제한된 교육용 AWS 환경을 기준으로 작성됐습니다.

## 담당 범위

* 서비스 기획 및 요구사항 작성
* 서버리스 아키텍처 설계
* Flutter 앱 개발
* Lambda 및 API Gateway 구성
* DynamoDB 데이터 구조 설계
* Bedrock 및 외부 API 연동
* Google OAuth 인증 구현
* 배포 스크립트 작성
* IAM 제약 대응 및 트러블슈팅
* ADR과 배포 문서 작성

구현에는 AI 에이전트를 활용했으며, 아키텍처 설계, AWS 자원 구성, 배포, 검증과 최종 기술 의사결정은 직접 수행했습니다.
