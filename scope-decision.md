# Polylog — 구현 범위 조정 결정서 (Scope Decision)

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Polylog (AI 여행 동행자) |
| 버전 | v2.0 |
| 작성일 | 2026-05-24 |
| 근거 문서 | `polylog-planning.md`, `requirements.md`, `schedule.md`, `ADR.md` |
| 현재 시점 | 12주차 (잔여 4주, 실질 개발 가능 3주) |
| 결정 사유 | 잔여 일정 대비 전체 구현 범위 과다, 미경험 기술 전수, 시험기간 병행, 앱 정체성 재정의 |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|---|---|---|
| 2026-05-24 | 1.0 | 최초 작성 — 7개 기능을 4개 구현 + 3개 이후 구현으로 분리 |
| 2026-05-24 | 2.0 | 앱 정체성 재정의 — 메인/서브 기능 구조로 재구성, Flutter 전환, FR-1+FR-7 통합, FR-5 복귀, Rekognition·Location Service 제거 |

---

## 1. 범위 조정 배경

### 원래 계획
- 7개 핵심 기능 (FR-1 ~ FR-7) 전체 구현
- 11개 Lambda 함수, AWS AI 서비스 7종 통합
- Android 네이티브 (Kotlin + Jetpack Compose)
- 10주 개발 일정 (주당 20시간)

### 현실
- 잔여 기간 4주, 15주차 시험기간 감안 시 실질 **3주**
- 사용 기술 **전부 미경험** (Flutter, AWS AI 서비스, SAM 등)
- 1인 개발, AI 에이전트 보조 활용하나 코드 이해·디버깅은 본인 몫
- 중간발표 12주차, 최종발표 15주차(시험기간)

### v1.0 → v2.0 변경 사유
- **FR-1(장소 인식)의 실용성 부족**: "사진 찍어서 AI가 설명해주는" 기능은 인터넷 검색으로 대체 가능하여 사용자 가치가 낮음
- **앱 정체성 불명확**: FR-1~FR-7이 나열식으로 "AI 카메라 앱"에 가까웠음
- **Flutter 전환**: Android 단일 플랫폼에서 Flutter 크로스 플랫폼으로 전환하여 Android + iOS 동시 데모 가능
- **결론**: 앱의 핵심 정체성을 **"AI 여행 장소 추천 앱"**으로 재정의하고, 메인/서브 구조로 기능을 재구성

---

## 2. 구현 범위 분류

### 2.1 앱 구조 개요

```
┌─────────────────────────────────────────────────┐
│          메인: AI 장소 추천                       │
│  GPS + Google Places API + Bedrock 개인화 추천   │
│  (맛집 / 숙소 / 관광지)                          │
└─────────────────────────────────────────────────┘
┌───────────────┬────────────────┬────────────────┐
│  서브1         │  서브2          │  서브3          │
│  메뉴판 번역   │  영수증 기록    │  AI 일정 관리   │
│  (FR-3)       │  (FR-5)        │  (FR-1+FR-7)   │
└───────────────┴────────────────┴────────────────┘
```

### 2.2 이번에 구현하는 기능 (v1.0 PoC)

| 우선순위 | 기능 | Lambda | AWS 서비스 | 외부 서비스 |
|---|---|---|---|---|
| **필수** | 인프라 + 인증 | fn-health | Cognito, API Gateway, S3, DynamoDB | — |
| **메인** | AI 장소 추천 | fn-recommend | Bedrock | Google Places API |
| **서브1** | 메뉴판 번역 | fn-menu | Textract, Translate, Bedrock | — |
| **서브2** | 영수증 기록 | fn-receipt | Textract (AnalyzeExpense), Bedrock | 환율 API |
| **서브3** | AI 일정 관리 | fn-schedule | Bedrock | Google Places API |

---

#### 필수: 인프라 + 인증

**포함 범위**
- AWS 계정, IAM 역할, S3 버킷, DynamoDB 테이블, API Gateway REST API
- Cognito User Pool + Amplify Flutter SDK 연동
- Flutter 앱 스켈레톤 (Dart + Material Design 3, 네비게이션, 인증 화면)
- SAM 템플릿 초기 구성

**선정 이유**
- 모든 기능의 전제 조건. 이것 없이는 어떤 기능도 동작하지 않음
- 인프라 구축 자체가 AWS 서버리스 아키텍처 학습

---

#### 메인: AI 장소 추천

**포함 범위**
- GPS 위치 수집 (geolocator 패키지)
- 사용자 카테고리 선택 (맛집 / 숙소 / 관광지 / 카페 등)
- Lambda → Google Places API (Nearby Search) → 주변 장소 후보 수집
- Bedrock Claude → 장소 후보 + 사용자 선호도 기반 개인화 추천 생성
- 추천 카드 UI (이름, 별점, 거리, AI 추천 이유)
- DynamoDB 추천 이력 저장

**선정 이유**

| 근거 | 설명 |
|---|---|
| **앱 정체성의 핵심** | "어디 가지?" 한마디에 AI가 맞춤 추천 — 앱을 여는 가장 기본적인 이유 |
| **데모 임팩트** | 발표에서 바로 "근처 맛집 추천해줘" 시연 가능. 실시간 인터랙티브 데모 |
| **기술 파이프라인 대표성** | GPS → Lambda → 외부 API + AI → 앱 표시. 전체 아키텍처 축소판 |
| **Bedrock 활용** | Google Places 데이터를 Bedrock가 큐레이션하여 단순 검색 이상의 가치 제공 |

**처리 흐름**

```
[사용자: 카테고리 선택 + GPS 위치]
    ↓
[API Gateway → fn-recommend Lambda]
    ↓
   ┌──────────────────────────────────────────┐
   │ 1. Google Places API (Nearby Search)     │
   │    (반경 N km, 카테고리, 장소 후보 수집)  │
   │ 2. Bedrock Claude                        │
   │    - 입력: 장소 후보 + 사용자 선호도      │
   │    - 출력: 개인화 추천 + 추천 이유        │
   └──────────────────────────────────────────┘
    ↓
[DynamoDB 추천 이력 저장 + 앱 결과 표시]
```

---

#### 서브1: 메뉴판 번역

**포함 범위**
- 메뉴판 촬영 → Textract 텍스트 추출 → Translate 번역 → Bedrock 메뉴 추천
- 촬영 가이드라인 오버레이 UI
- 원문/번역/추천 카드 UI
- 식이 제한 프로필 설정

**선정 이유**

| 근거 | 설명 |
|---|---|
| **카메라 기반 기능** | 메인(텍스트 입력)과 다른 입력 방식으로 앱의 다양성을 보여줌 |
| **AWS AI 서비스 2종 추가** | Textract + Translate. 메인의 Bedrock과 합치면 AI 서비스 3종 |
| **여행 핵심 페인 포인트** | "외국어 메뉴판을 못 읽겠다"는 여행자의 가장 빈번한 불편 |
| **Bedrock 프롬프트 심화** | 사용자 프로필(알레르기) 기반 개인화 추천으로 프롬프트 활용도 상승 |

---

#### 서브2: 영수증 기록

**포함 범위**
- 영수증 촬영 → Textract AnalyzeExpense → 금액·항목 추출
- Bedrock 카테고리 자동 분류 (식사, 교통, 숙박, 쇼핑)
- 환율 API → 원화 환산
- 일별 지출 목록 + 카테고리 통계 UI
- DynamoDB Expense 테이블 저장

**축소 사항**
- 환율 통계 고급 분석은 v2.0으로 이관
- 차트/그래프는 기본 통계만 (복잡한 시각화 제외)

**선정 이유**

| 근거 | 설명 |
|---|---|
| **Textract 파이프라인 재활용** | 메뉴판 OCR(서브1)에서 Textract를 이미 사용하므로 파이프라인 재활용 가능 |
| **다른 입력→다른 출력** | 같은 카메라 입력이지만 "번역"이 아닌 "금액 추출"로 다른 AI 파이프라인 시연 |
| **Textract AnalyzeExpense** | Textract의 영수증 특화 API로 일반 OCR과 다른 고급 기능 학습 |
| **실용성** | 여행 지출 관리는 보편적 니즈 |

---

#### 서브3: AI 일정 관리

**포함 범위**
- AI와 대화형으로 일정 계획 (Bedrock 채팅 인터페이스)
- AI가 GPS + Google Places API로 근처 장소를 검색하여 일정 추천
- 일정을 정해진 프레임(타임라인/카드)으로 표시
- DynamoDB Schedule + ChatMessage 저장
- 일정 변경 시 자동으로 근처 재검색 → 대안 추천

**축소 사항**
- EventBridge 일정 알림 제외 — 일정 저장·조회까지만
- 날씨 연동 제외 (v2.0)

**선정 이유**

| 근거 | 설명 |
|---|---|
| **"AI 동행자" 정체성의 핵심** | 대화형 일정 관리가 없으면 "AI 추천 앱"일 뿐, "AI 동행자"가 아님 |
| **Bedrock 활용 심화** | 메인(단발 추천), 서브1(개인화 추천)에 이어 서브3(대화형 컨텍스트 유지)로 Bedrock 활용 3단계 |
| **메인 기능과 시너지** | 메인에서 추천받은 장소를 일정에 추가하는 자연스러운 흐름 |
| **추가 AWS 서비스 없음** | Bedrock + Google Places API만으로 구현 — 이미 사용하는 서비스 재활용 |

---

### 2.3 이후에 구현할 기능 (v2.0 확장)

| 기능 | 관련 요구사항 | 핵심 미구현 기술 | 이후 구현 사유 |
|---|---|---|---|
| FR-2 실시간 통역 | FR-2.1~2.4 | Transcribe Streaming (WebSocket), Polly | WebSocket 기반 프로토콜이 REST와 다름. 구현 난이도 독립적으로 최고 |
| FR-4 자동 여행기 | FR-4.1~4.4 | Step Functions (ASL), Map State | Lambda 4종 오케스트레이션 규모가 미니 프로젝트급 |
| FR-6 날씨 기반 일정 | FR-6.1~6.3 | OpenWeatherMap API | 서브3(일정 관리)가 성숙한 후 날씨 컨텍스트를 추가하는 것이 자연스러운 확장 경로 |
| 일정 알림 | FR-7.4 | EventBridge, SNS | 핵심 가치(추천+일정)가 동작한 뒤 부가 기능으로 추가 |

---

## 3. 구현 범위 비교 요약

```
원래 계획 (v1.0 Full)              v1.0 PoC (조정 전)          v2.0 PoC (현재)
───────────────────                ──────────────────          ──────────────────
✅ 인프라 + 인증                    ✅ 인프라 + 인증             ✅ 인프라 + 인증
✅ FR-1 장소 인식                   ✅ FR-1 장소 인식            ✅ 메인: AI 장소 추천 (신규)
✅ FR-2 실시간 통역                 ➡️ v2.0 이후                ➡️ v2.0 이후
✅ FR-3 메뉴판 OCR                  ✅ FR-3 메뉴판 OCR           ✅ 서브1: 메뉴판 번역
✅ FR-4 자동 여행기                 ➡️ v2.0 이후                ➡️ v2.0 이후
✅ FR-5 영수증 가계부               ➡️ v2.0 이후                ✅ 서브2: 영수증 기록 (복귀)
✅ FR-6 날씨 일정                   ➡️ v2.0 이후                ➡️ v2.0 이후
✅ FR-7 채팅 일정                   ✅ FR-7 채팅 일정            ✅ 서브3: AI 일정 관리

플랫폼: Android Native             플랫폼: Android Native      플랫폼: Flutter (Android+iOS)
Lambda 함수: 11개                  Lambda 함수: 4개            Lambda 함수: 5개
AWS AI 서비스: 7종                 AWS AI 서비스: 5종          AWS AI 서비스: 3종
외부 API: 2종                      외부 API: 0종               외부 API: 2종 (Google Places, 환율)
```

---

## 4. AWS AI 서비스 + 외부 API 커버리지

v2.0 PoC 범위에서는 AWS AI 서비스 3종 + Google Places API로 실용성 중심 구성을 채택합니다.

| 서비스 | v1.0 조정 전 | v2.0 현재 | 사용 기능 | 변경 사유 |
|---|---|---|---|---|
| Amazon Rekognition | ✅ | ❌ | — | 이미지 인식보다 장소 추천에 집중 |
| Amazon Bedrock (Claude) | ✅ | ✅ | 메인 + 서브1,2,3 전체 | 핵심 AI 엔진 유지 |
| Amazon Textract | ✅ | ✅ | 서브1 메뉴판 + 서브2 영수증 | OCR 2종으로 확장 |
| Amazon Translate | ✅ | ✅ | 서브1 메뉴판 번역 | 유지 |
| Amazon Location Service | ✅ | ❌ | — | Google Places API가 POI 데이터 압도적 우위 |
| Amazon Polly | 선택 | ❌ | — | v2.0 통역 기능에서 재도입 |
| Amazon Transcribe | ❌ | ❌ | — | v2.0 통역 기능에서 도입 |
| **Google Places API** | ❌ | ✅ | 메인 + 서브3 장소 검색 | 리뷰·별점·사진 등 풍부한 POI 데이터 |
| **환율 API** | ❌ | ✅ | 서브2 영수증 환산 | 원화 환산 필수 |

---

## 5. 기술 스택 변경 사항

### 클라이언트 전환: Android Native → Flutter

| 항목 | 조정 전 | 현재 | 변경 사유 |
|---|---|---|---|
| 프레임워크 | Kotlin + Jetpack Compose | Flutter (Dart) | 크로스 플랫폼, Hot Reload |
| 카메라 | CameraX | camera / image_picker 패키지 | Flutter 호환 |
| 위치 | FusedLocationProviderClient | geolocator 패키지 | Flutter 호환 |
| 네트워크 | Retrofit + OkHttp | dio | Flutter 호환 |
| 로컬 DB | Room | sqflite | Flutter 호환 |
| 인증 | Amplify Android SDK | Amplify Flutter SDK | Flutter 호환 |
| 플랫폼 지원 | Android 전용 | **Android + iOS** | 발표 임팩트 상승 |

### ADR-003 변경

기존 ADR-003 "Android (Kotlin + Jetpack Compose) 단일 플랫폼" → "Flutter (Dart) 크로스 플랫폼"으로 변경. 상세 근거는 `ADR.md` ADR-003 참조.

---

## 6. 발표 전략

### 중간발표 (12주차)
- **데모**: 메인 장소 추천 E2E — "근처 맛집 추천해줘" → AI 추천 카드 표시
- **어필 포인트**: 서버리스 아키텍처 설계, GPS + Google Places + Bedrock 파이프라인, Flutter 크로스 플랫폼

### 최종발표 (15주차)
- **데모**: 메인 + 서브 3개 — "추천받고, 메뉴판 읽고, 영수증 찍고, 일정 짠다"
- **어필 포인트**:
  - 메인/서브 4개 기능으로 Bedrock 활용의 3단계 깊이 시연 (단발 추천 → 개인화 추천 → 대화형 컨텍스트)
  - Textract 2종 활용 (DetectDocumentText + AnalyzeExpense)
  - Flutter로 Android + iOS 동시 데모
  - 미구현 기능은 **확장 로드맵**으로 제시 — "설계는 완료, 구현은 v2.0"
  - 기획 산출물 (planning, requirements, WBS, ADR, scope-decision)로 기획력 어필

### 예상 질의응답 대비

| 예상 질문 | 대비 답변 |
|---|---|
| "왜 7개 다 안 했나요?" | "3주 안에 이해 없이 AI로 코드만 생성하는 것보다, 4개를 깊이 이해하고 설명할 수 있는 것이 학습 프로젝트의 본질이라 판단했습니다. 범위 조정 근거는 scope-decision.md에 문서화되어 있습니다." |
| "왜 Flutter로 바꿨나요?" | "Android 단일 플랫폼의 제약을 극복하고 iOS 동시 데모가 가능해져 프로젝트의 완성도가 높아집니다. Amplify Flutter SDK가 필요한 기능(Auth, Storage, API)을 안정적으로 지원하여 전환 리스크가 낮았습니다." |
| "Rekognition을 왜 뺐나요?" | "앱의 핵심 가치를 '장소 추천'으로 재정의하면서, 이미지 인식보다 Google Places API의 풍부한 POI 데이터(리뷰, 별점, 사진)가 더 적합하다고 판단했습니다." |
| "AWS AI 서비스가 3종밖에 안 되나요?" | "Bedrock, Textract, Translate 3종이지만 Textract는 DetectDocumentText와 AnalyzeExpense 2가지 API를 사용하고, Bedrock는 4개 기능에서 각기 다른 프롬프트 패턴(단발 생성, 개인화, 분류, 대화형)으로 활용합니다. 양보다 깊이에 집중했습니다." |
| "나머지는 어떻게 할 건가요?" | "아키텍처 설계와 ADR은 7개 기능 전체에 대해 완료되어 있고, v1.0에서 구축한 파이프라인을 재활용하면 v2.0 확장 공수가 크게 줄어듭니다." |
