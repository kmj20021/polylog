# Polylog — 요구사항 정의서 (Requirements Specification)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v1.0 |
| 작성일 | 2026-05-24 |
| 근거 문서 | `polylog-planning.md` v1.0 |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-24 | 1.0 | 최초 작성 — polylog-planning.md 기반 요구사항 통합 정리 |

---

## 1. 기능 요구사항 (Functional Requirements)

### FR-1: 카메라 기반 장소 인식 및 설명

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-1.1 | 사용자가 카메라로 건물·풍경을 비추면 사진을 캡처한다 | 필수 | — (CameraX) |
| FR-1.2 | 캡처된 사진을 GPS 좌표와 함께 서버로 전송하여 분석을 요청한다 | 필수 | S3, API Gateway |
| FR-1.3 | AI가 장소명, 역사, 특징을 한국어 자연어로 설명한다 | 필수 | Rekognition, Location Service, Bedrock |
| FR-1.4 | 생성된 설명을 음성으로 재생할 수 있다 | 선택 | Polly |

**수용 기준**
- 사진 촬영부터 설명 표시까지 5초 이내
- GPS 신호 부재 시 Rekognition 결과만으로 일반 설명 제공
- 네트워크 단절 시 로컬 큐에 저장 후 복구 시 일괄 업로드

---

### FR-2: 실시간 음성 통역

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-2.1 | 마이크 입력을 실시간 텍스트로 변환한다 | 필수 | Transcribe Streaming |
| FR-2.2 | 사용자 설정 언어 ↔ 대상 언어 양방향 번역을 수행한다 | 필수 | Translate |
| FR-2.3 | 번역된 텍스트를 자연스러운 음성으로 출력한다 | 필수 | Polly Neural TTS |
| FR-2.4 | 통역 이력을 저장하고 재조회할 수 있다 | 필수 | DynamoDB |

**수용 기준**
- 발화 종료 후 번역 음성 출력까지 2초 이내
- 지원 언어: 영어, 일본어, 중국어, 스페인어 ↔ 한국어
- 시끄러운 환경에서 텍스트 직접 입력 모드 전환 가능
- 통역 지연 3초 이상 시 "처리 중..." 인디케이터 표시

---

### FR-3: 메뉴판 OCR 및 추천

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-3.1 | 메뉴판 사진 촬영 후 텍스트를 추출한다 | 필수 | Textract |
| FR-3.2 | 외국어 메뉴를 한국어로 번역한다 | 필수 | Translate |
| FR-3.3 | 사용자 선호도·알레르기 기반 추천 메뉴를 제시한다 | 필수 | Bedrock |
| FR-3.4 | 메뉴별 간단한 설명을 제공한다 | 선택 | Bedrock |

**수용 기준**
- 메뉴판 텍스트 추출 정확도 90% 이상 (명확한 인쇄물 기준)
- 알레르기 유발 가능 메뉴 필터링
- 사진 품질 불량 시 재촬영 가이드라인(프레임 오버레이) 표시

---

### FR-4: 자동 여행기 작성

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-4.1 | 하루 동안의 사진, 음성 메모, 위치 데이터를 수집한다 | 필수 | S3, DynamoDB |
| FR-4.2 | 시간 순으로 정렬 후 AI가 자연어 여행기 초안을 생성한다 | 필수 | Step Functions, Bedrock |
| FR-4.3 | 사용자가 여행기를 수정하고 저장할 수 있다 | 필수 | DynamoDB |
| FR-4.4 | 월별·여행별 아카이브를 조회할 수 있다 | 선택 | DynamoDB |

**수용 기준**
- 수동 트리거 또는 매일 밤 11시 자동 생성
- 사진 1장 이상 또는 위치 이력 존재 시 생성 가능
- 데이터 부족 시 짧은 요약 모드로 분기
- Bedrock 응답 실패 시 3회 재시도 후 사용자 알림
- 완성 시 SNS 푸시 알림 발송

---

### FR-5: 영수증 자동 가계부

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-5.1 | 영수증 사진 촬영 시 금액·항목·날짜를 자동 추출한다 | 필수 | Textract AnalyzeExpense |
| FR-5.2 | 지출을 카테고리(식사, 교통, 숙박, 쇼핑 등)로 자동 분류한다 | 필수 | Bedrock |
| FR-5.3 | 현지 통화를 원화로 자동 환산한다 | 필수 | 외부 환율 API |
| FR-5.4 | 일별·카테고리별 지출 통계를 제공한다 | 필수 | DynamoDB |

**수용 기준**
- Textract 신뢰도 80% 미만 필드는 사용자 확인 요청
- 카테고리 자동 분류 오류 시 수동 변경 가능
- 환율은 실시간 조회 + 캐싱 적용

---

### FR-6: 날씨 기반 일정 추천

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-6.1 | 현재 위치의 실시간 날씨를 조회한다 | 필수 | 외부 API (OpenWeatherMap) |
| FR-6.2 | 시간대별 날씨 예보를 제공한다 | 필수 | 외부 API |
| FR-6.3 | 날씨에 따라 실내·실외 활동을 추천한다 | 필수 | Bedrock, Location Service |

**수용 기준**
- 기존 야외 일정이 있고 악천후 예보 시 대안 실내 활동 추천
- 추천 수락 시 기존 일정 자동 교체 + 알림 재등록

---

### FR-7: 대화형 일정 관리

| ID | 요구사항 | 우선순위 | 관련 AWS 서비스 |
|---|---|---|---|
| FR-7.1 | 텍스트 채팅으로 자연어 일정 추천을 요청한다 | 필수 | Bedrock |
| FR-7.2 | 위치·날씨·시간을 고려한 맛집·관광지를 추천한다 | 필수 | Location Service, Bedrock |
| FR-7.3 | 추천 결과를 일정에 추가·수정·삭제한다 | 필수 | DynamoDB |
| FR-7.4 | 일정 변경 시 알림을 발송한다 | 선택 | EventBridge, SNS |

**수용 기준**
- 대화 컨텍스트(이전 대화 이력 + 기존 일정) 유지
- 모호한 요청 시 확인 질문 반환 (즉답 방지)
- 일정 변경 의도 불명확 시 확인 프롬프트 제공

---

## 2. 비기능 요구사항 (Non-Functional Requirements)

### 2.1 성능 (Performance)

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-P1 | 카메라 기반 장소 분석 응답 시간 | 5초 이내 |
| NFR-P2 | 실시간 통역 지연 시간 | 2초 이내 |
| NFR-P3 | 메뉴판 OCR + 번역 + 추천 응답 시간 | 6초 이내 |
| NFR-P4 | 영수증 분석 응답 시간 | 4초 이내 |
| NFR-P5 | 채팅 일정 추천 응답 시간 | 4초 이내 |
| NFR-P6 | 날씨 조회 응답 시간 | 1초 이내 |
| NFR-P7 | 자동 여행기 생성 완료 시간 | 30초 이내 |

### 2.2 가용성 (Availability)

| ID | 요구사항 |
|---|---|
| NFR-A1 | 서비스 가용성 99% 이상 (PoC 기준) |
| NFR-A2 | 네트워크 단절 시 로컬 큐잉으로 데이터 유실 0% |
| NFR-A3 | Lambda 서버리스 구조로 사용량 기반 자동 확장 |

### 2.3 보안 (Security)

| ID | 요구사항 |
|---|---|
| NFR-S1 | 사진·음성 파일 S3 SSE(Server-Side Encryption) 암호화 |
| NFR-S2 | IAM 최소 권한 원칙 — Lambda 함수별 역할 분리 |
| NFR-S3 | Cognito 기반 사용자 인증 및 권한 관리 |
| NFR-S4 | API Gateway를 통한 인증된 요청만 허용 |
| NFR-S5 | 사용자 데이터 내보내기 및 삭제 권한 보장 |

### 2.4 사용성 (Usability)

| ID | 요구사항 |
|---|---|
| NFR-U1 | 한 화면에서 카메라·음성·텍스트 모든 입력 가능 |
| NFR-U2 | UI 언어: 한국어 |
| NFR-U3 | 음성 출력 옵션으로 시각적 정보 음성화 가능 |
| NFR-U4 | 메인 네비게이션: 카메라·통역·메뉴·지출·채팅·여행기 탭 |

### 2.5 비용 (Cost)

| ID | 요구사항 | 목표 수치 |
|---|---|---|
| NFR-C1 | 월 운영 비용 (PoC, 무료 티어 적용) | ~$5 |
| NFR-C2 | 월 운영 비용 (무료 티어 종료 후) | $15~$30 이하 |
| NFR-C3 | AWS 결제 알람 설정 | Budgets $30 |

### 2.6 관측 가능성 (Observability)

| ID | 요구사항 |
|---|---|
| NFR-O1 | CloudWatch Logs로 모든 Lambda 함수 로그 수집 |
| NFR-O2 | X-Ray 분산 추적으로 모든 요청 경로 추적 가능 |
| NFR-O3 | CloudWatch Metrics로 서비스 메트릭 모니터링 |

---

## 3. 기술 요구사항 (Technical Requirements)

### 3.1 AWS AI 서비스 (7종)

| ID | 서비스 | 용도 | 사용 API |
|---|---|---|---|
| TR-AI1 | Amazon Rekognition | 이미지 내 객체·랜드마크 인식 | DetectLabels, DetectText |
| TR-AI2 | Amazon Bedrock (Claude) | 자연어 생성, 분석, 추천 | InvokeModel |
| TR-AI3 | Amazon Transcribe | 음성 → 텍스트 변환 | StartStreamTranscription |
| TR-AI4 | Amazon Translate | 텍스트 번역 | TranslateText |
| TR-AI5 | Amazon Polly | 텍스트 → 음성 합성 | SynthesizeSpeech (Neural) |
| TR-AI6 | Amazon Textract | 문서/영수증 OCR | DetectDocumentText, AnalyzeExpense |
| TR-AI7 | Amazon Location Service | 지도·역지오코딩·POI 검색 | SearchPlaceIndexForPosition, SearchPlaceIndexForText |

### 3.2 AWS 인프라 서비스

| ID | 서비스 | 용도 |
|---|---|---|
| TR-INF1 | AWS Lambda | 서버리스 백엔드 함수 실행 |
| TR-INF2 | Amazon API Gateway | REST/WebSocket API 엔드포인트 |
| TR-INF3 | Amazon S3 | 사진·음성·영수증 미디어 저장 |
| TR-INF4 | Amazon DynamoDB | 구조화 데이터 저장 (7종 테이블) |
| TR-INF5 | Amazon Cognito | 사용자 인증 |
| TR-INF6 | Amazon CloudFront | 사진 CDN 배포 |
| TR-INF7 | Amazon EventBridge | 일정 알림 및 자동 여행기 스케줄링 |
| TR-INF8 | Amazon SNS | 모바일 푸시 알림 |
| TR-INF9 | AWS Step Functions | 여행기 생성 워크플로우 오케스트레이션 |
| TR-INF10 | Amazon CloudWatch | 로그·메트릭 모니터링 |
| TR-INF11 | AWS X-Ray | 분산 추적 |

### 3.3 외부 서비스

| ID | 서비스 | 용도 |
|---|---|---|
| TR-EXT1 | OpenWeatherMap API | 실시간 날씨 및 예보 조회 |
| TR-EXT2 | ExchangeRate-API (또는 동등) | 실시간 환율 조회 |

### 3.4 클라이언트 기술 스택

| ID | 분류 | 기술 | 비고 |
|---|---|---|---|
| TR-CLI1 | 플랫폼 | Android (Kotlin) | 최소 API 26 (Android 8.0) |
| TR-CLI2 | UI 프레임워크 | Jetpack Compose | 선언형 UI |
| TR-CLI3 | 카메라 | CameraX | 사진 캡처 |
| TR-CLI4 | 위치 | FusedLocationProviderClient | GPS 좌표 |
| TR-CLI5 | 네트워크 | Retrofit + OkHttp | REST API 통신 |
| TR-CLI6 | 로컬 DB | Room | 오프라인 큐잉 |
| TR-CLI7 | 인증 | AWS Amplify Android SDK | Cognito 연동 |

### 3.5 개발·운영 도구

| ID | 분류 | 도구 |
|---|---|---|
| TR-DEV1 | IaC | AWS SAM 또는 Terraform |
| TR-DEV2 | CI/CD | GitHub Actions |
| TR-DEV3 | 로컬 테스트 | AWS SAM Local |
| TR-DEV4 | 버전 관리 | Git / GitHub |

---

## 4. 데이터 요구사항 (Data Requirements)

### 4.1 데이터 엔티티 목록

| ID | 엔티티 | 저장소 | 설명 |
|---|---|---|---|
| DR-1 | User | DynamoDB | 사용자 프로필 (Cognito Sub ID, 언어, 식이 제한) |
| DR-2 | Trip | DynamoDB | 여행 단위 (목적지, 기간, 통화, 상태) |
| DR-3 | Place | DynamoDB + S3 | 카메라 인식 장소 (사진, 좌표, AI 설명, 라벨) |
| DR-4 | TranslationLog | DynamoDB + S3 | 통역 기록 (원문, 번역문, 합성 음성) |
| DR-5 | Menu / MenuItem | DynamoDB + S3 | 메뉴판 분석 (사진, 항목, 번역, 추천) |
| DR-6 | Expense | DynamoDB + S3 | 지출 (영수증 사진, 금액, 환산, 카테고리) |
| DR-7 | Schedule | DynamoDB | 일정 (장소, 시간, 수동/AI추천 구분) |
| DR-8 | Diary | DynamoDB | 자동 여행기 (본문, 포함 사진, 수정 여부) |
| DR-9 | ChatMessage | DynamoDB | 대화 이력 (사용자/AI 역할, 메시지) |

### 4.2 데이터 관계

```
User (1) ── (N) Trip
                 │
    ┌────┬────┬──┴──┬────┬────┬────┐
   (N)  (N)  (N)  (N)  (N)  (N)  (N)
  Place Trans Menu Expense Sched Diary Chat
              │
             (N)
           MenuItem
```

### 4.3 미디어 저장 정책

| 유형 | S3 버킷 분리 | 암호화 | 비고 |
|---|---|---|---|
| 사진 (장소/메뉴판) | photos/ | SSE-S3 | CloudFront CDN 배포 |
| 음성 (통역/메모) | audio/ | SSE-S3 | — |
| 영수증 이미지 | receipts/ | SSE-S3 | — |

---

## 5. 제약사항 (Constraints)

| ID | 분류 | 제약 내용 |
|---|---|---|
| CON-1 | 플랫폼 | PoC 범위: Android 앱 우선 개발, iOS는 차후 검토 |
| CON-2 | 목적 | 개인 학습 프로젝트 — 상용 출시 아닌 포트폴리오 목적 |
| CON-3 | 리전 | AWS 서울 리전 우선, Bedrock·Location Service는 가용 리전(us-east-1) 사용 |
| CON-4 | 비용 | 무료 티어 적극 활용, 월 $30 이하 유지 |
| CON-5 | 개발 기간 | 10주 (주당 20시간 기준), 최대 12주 연장 가능 |
| CON-6 | 인원 | 1인 개발 |
| CON-7 | Bedrock 리전 | us-east-1 cross-region 호출로 ~200ms 추가 지연 감안 |

---

## 6. Lambda 함수 요구사항

| ID | 함수명 | 역할 | 트리거 | 목표 실행 시간 |
|---|---|---|---|---|
| LF-1 | fn-place | 카메라 사진 → 장소 설명 생성 | API Gateway | 3~5초 |
| LF-2 | fn-translate | 실시간 통역 처리 | API Gateway (WebSocket) | 1~2초/청크 |
| LF-3 | fn-menu | 메뉴판 OCR + 번역 + 추천 | API Gateway | 4~6초 |
| LF-4 | fn-receipt | 영수증 OCR + 가계부 등록 | API Gateway | 3~4초 |
| LF-5 | fn-chat | 대화형 일정 추천 | API Gateway | 2~4초 |
| LF-6 | fn-weather | 날씨 조회 (캐시 포함) | API Gateway | <1초 |
| LF-7 | fn-diary-orchestrator | Step Functions 트리거 | EventBridge / 사용자 | <1초 |
| LF-8 | fn-diary-collector | 하루 데이터 수집 | Step Functions | 1~2초 |
| LF-9 | fn-diary-photo-analyzer | 사진 일괄 태깅 | Step Functions Map | 5~30초 |
| LF-10 | fn-diary-writer | Bedrock 여행기 작성 | Step Functions | 10~20초 |
| LF-11 | fn-notify | SNS 푸시 발송 | EventBridge / Step Functions | <1초 |

---

## 7. 요구사항 추적 매트릭스 (Traceability Matrix)

각 기능 요구사항이 어떤 Lambda 함수와 Use Case에 매핑되는지 추적합니다.

| 기능 요구사항 | Lambda 함수 | Use Case | 데이터 엔티티 |
|---|---|---|---|
| FR-1 (장소 인식) | fn-place | UC-1 | Place |
| FR-2 (음성 통역) | fn-translate | UC-2 | TranslationLog |
| FR-3 (메뉴판 OCR) | fn-menu | UC-3 | Menu, MenuItem |
| FR-4 (자동 여행기) | fn-diary-* (4종) | UC-6 | Diary |
| FR-5 (영수증 가계부) | fn-receipt | UC-4 | Expense |
| FR-6 (날씨 일정) | fn-weather, fn-chat | UC-5 | Schedule |
| FR-7 (대화형 일정) | fn-chat | UC-7 | Schedule, ChatMessage |

---

## 8. 위험 요구사항 (Risk Requirements)

### 8.1 미경험 기술 식별표

프로젝트에 사용되는 기술 중 개발자가 처음 사용하거나 경험이 부족한 항목을 식별하고, 숙련도와 위험 등급을 평가합니다.

#### 8.1.1 처음 사용하는 라이브러리 / 프레임워크

| ID | 기술 | 사용 목적 | 숙련도 | 위험 등급 | 관련 요구사항 |
|---|---|---|---|---|---|
| RISK-LIB1 | Jetpack Compose | 선언형 UI 구성 | 미경험 | 상 | TR-CLI2 |
| RISK-LIB2 | CameraX | 카메라 캡처 및 프리뷰 | 미경험 | 중 | TR-CLI3, FR-1.1 |
| RISK-LIB3 | AWS Amplify Android SDK | Cognito 인증 연동 | 미경험 | 중 | TR-CLI7, NFR-S3 |
| RISK-LIB4 | Room (오프라인 큐 용도) | 로컬 큐잉 및 동기화 | 미경험 | 중 | TR-CLI6, NFR-A2 |
| RISK-LIB5 | Retrofit + OkHttp | REST/WebSocket 통신 | 미경험 | 중 | TR-CLI5 |
| RISK-LIB6 | AWS SAM (IaC) | Lambda·API Gateway 배포 자동화 | 미경험 | 중 | TR-DEV1 |

**대응 방안**
- 각 라이브러리별 공식 Codelab / 튜토리얼을 10주차 착수 전에 1회 이상 완주
- Jetpack Compose는 앱 전체 UI의 근간이므로 가장 높은 학습 우선순위 부여
- CameraX·Amplify는 공식 샘플 프로젝트를 fork하여 동작 확인 후 프로젝트에 통합

---

#### 8.1.2 처음 사용하는 API / AWS 서비스

| ID | API / 서비스 | 사용 목적 | 숙련도 | 위험 등급 | 관련 요구사항 |
|---|---|---|---|---|---|
| RISK-API1 | Amazon Bedrock (InvokeModel) | 자연어 생성·분석·추천 | 미경험 | 상 | TR-AI2 |
| RISK-API2 | Amazon Transcribe Streaming | 실시간 음성→텍스트 (WebSocket) | 미경험 | 상 | TR-AI3, FR-2.1 |
| RISK-API3 | Amazon Rekognition | 이미지 객체·랜드마크 인식 | 미경험 | 중 | TR-AI1, FR-1.2 |
| RISK-API4 | Amazon Textract (AnalyzeExpense) | 영수증 특화 OCR | 미경험 | 중 | TR-AI6, FR-5.1 |
| RISK-API5 | Amazon Polly (Neural TTS) | 텍스트→음성 합성 | 미경험 | 하 | TR-AI5, FR-1.4 |
| RISK-API6 | Amazon Translate | 텍스트 번역 | 미경험 | 하 | TR-AI4, FR-2.2 |
| RISK-API7 | Amazon Location Service | 역지오코딩·POI 검색 | 미경험 | 중 | TR-AI7, FR-7.2 |
| RISK-API8 | AWS Step Functions (ASL) | 여행기 생성 워크플로우 오케스트레이션 | 미경험 | 상 | TR-INF9, FR-4.2 |
| RISK-API9 | Amazon EventBridge | 스케줄 기반 트리거 | 미경험 | 하 | TR-INF7, FR-7.4 |
| RISK-API10 | Amazon Cognito | 사용자 인증·권한 관리 | 미경험 | 중 | TR-INF5, NFR-S3 |
| RISK-API11 | OpenWeatherMap API | 날씨 조회 | 미경험 | 하 | TR-EXT1, FR-6.1 |
| RISK-API12 | ExchangeRate-API | 환율 조회 | 미경험 | 하 | TR-EXT2, FR-5.3 |

**대응 방안**
- **위험 등급 "상"** (Bedrock, Transcribe Streaming, Step Functions): 10주차에 독립 PoC 스크립트로 단독 호출 테스트 먼저 수행. 동작 확인 후 Lambda에 통합
- **위험 등급 "중"**: AWS 콘솔에서 수동 테스트 1회 이상 수행 후 코드화
- **위험 등급 "하"**: REST API 기반으로 복잡도 낮음. 공식 문서 참고하여 바로 구현 가능
- Transcribe Streaming은 WebSocket 기반으로 일반 REST API보다 구현 난이도 높음 — 11주차에 통역 기능 미완성 시 텍스트 입력 폴백 모드로 전환

---

#### 8.1.3 AI 의존 위험 (AI 생성 코드 이해도 부족)

AI 코드 생성 도구(Claude, Copilot 등)에 의존하여 작성한 코드를 개발자 본인이 충분히 이해하지 못할 경우, 디버깅·유지보수·발표 질의응답에서 심각한 문제가 발생할 수 있습니다.

| ID | 위험 영역 | 위험 설명 | 위험 등급 |
|---|---|---|---|
| RISK-AI1 | Lambda 비즈니스 로직 | AI가 생성한 AWS SDK 호출 코드(Rekognition, Textract 등)의 파라미터·응답 구조를 본인이 이해하지 못함 | 상 |
| RISK-AI2 | Bedrock 프롬프트 엔지니어링 | AI가 작성한 프롬프트의 의도와 구조를 설명하지 못함. 프롬프트 수정 시 예상치 못한 품질 변화 발생 | 상 |
| RISK-AI3 | SAM / IaC 템플릿 | AI가 생성한 template.yaml의 리소스 정의·권한 설정을 이해하지 못해 배포 오류 시 수정 불가 | 중 |
| RISK-AI4 | Jetpack Compose UI | AI가 작성한 Composable 함수의 상태 관리(State Hoisting, Side Effects)를 이해하지 못해 UI 버그 수정 불가 | 중 |
| RISK-AI5 | Step Functions ASL | AI가 생성한 State Machine 정의(JSON)의 상태 전이·에러 핸들링 로직을 본인이 설명하지 못함 | 중 |
| RISK-AI6 | 발표 질의응답 대응 | 코드의 동작 원리를 질문받았을 때 "AI가 작성했다"는 답변만 가능하여 학습 목표 미달 판정 | 상 |

**대응 방안**

| 대응 전략 | 설명 |
|---|---|
| **코드 리뷰 의무화** | AI가 생성한 모든 코드를 커밋 전에 한 줄씩 읽고, 주석 없이도 동작 원리를 말로 설명할 수 있어야 커밋 허용 |
| **"설명 테스트" 규칙** | 각 Lambda 함수 완성 시, 해당 함수의 입력→처리→출력 흐름을 3분 이내에 구두로 설명하는 셀프 테스트 수행. 실패 시 코드를 직접 다시 작성 |
| **핵심 로직 수동 작성** | Bedrock 프롬프트, DynamoDB 쿼리, IAM 권한 정의는 반드시 본인이 직접 작성. AI는 보조 검토 용도로만 활용 |
| **단계적 AI 활용** | 1단계: 본인이 의사 코드(pseudocode) 작성 → 2단계: AI로 구현 코드 생성 → 3단계: 생성 코드와 의사 코드 대조 검증 |
| **학습 기록 작성** | 새로운 AWS 서비스·라이브러리 사용 시 "오늘 배운 것" 형식으로 핵심 개념 1~2줄 기록. 발표 준비 시 이 기록을 기반으로 질의응답 대비 |
| **블랙박스 코드 금지** | 동작은 하지만 원리를 설명하지 못하는 코드는 프로젝트에 포함하지 않음. 이해 불가 시 더 단순한 대안으로 교체 |

---

### 8.2 미경험 기술 위험 요약 매트릭스

```
위험 등급 ▲
  상   │ RISK-LIB1     RISK-API1  RISK-API2  RISK-API8
       │ RISK-AI1      RISK-AI2   RISK-AI6
       │
  중   │ RISK-LIB2~5   RISK-API3  RISK-API4  RISK-API7  RISK-API10
       │ RISK-LIB6     RISK-AI3   RISK-AI4   RISK-AI5
       │
  하   │               RISK-API5  RISK-API6  RISK-API9
       │               RISK-API11 RISK-API12
       └──────────────────────────────────────────────────▶
                라이브러리         API/서비스        AI 의존
```

### 8.3 기능별 미경험 기술 의존도 요약

각 기능이 미경험 기술에 얼마나 의존하는지 표시합니다. 의존도가 높을수록 일정 지연 가능성이 큽니다.

| 기능 | 미경험 라이브러리 | 미경험 API | AI 의존 위험 | 종합 위험도 |
|---|---|---|---|---|
| FR-1 장소 인식 | CameraX, Compose | Rekognition, Location, Bedrock | 프롬프트, SDK 코드 | **상** |
| FR-2 실시간 통역 | Compose | Transcribe Streaming, Translate, Polly | SDK 코드 | **상** |
| FR-3 메뉴판 OCR | CameraX, Compose | Textract, Translate, Bedrock | 프롬프트, 파싱 로직 | **상** |
| FR-4 자동 여행기 | — | Step Functions, Bedrock | ASL 정의, 프롬프트 | **상** |
| FR-5 영수증 가계부 | Compose | Textract AnalyzeExpense, Bedrock | SDK 코드 | **중** |
| FR-6 날씨 일정 | Compose | OpenWeatherMap | 낮음 | **하** |
| FR-7 채팅 일정 | Compose | Location Service, Bedrock | 프롬프트 | **중** |
| 인증 | Amplify SDK | Cognito | 설정 코드 | **중** |
| 인프라 | SAM | IAM, S3, DynamoDB | IaC 템플릿 | **중** |
