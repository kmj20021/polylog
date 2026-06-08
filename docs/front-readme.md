# 프론트엔드 재디자인 기록

## 한 일 (Done)

### 2026-06-08 — 로그인 인증 마이그레이션 (google_sign_in 6.x → 7.x, 기능)
- 증상: 레거시 Google Sign-In(GMS) 경로에서 `ApiException: 10`(DEVELOPER_ERROR)로 로그인 실패. OAuth 설정(SHA-1·패키지·웹 클라이언트·동의화면) 전부 검증해도 재현 → deprecated된 레거시 흐름이 원인으로 판단.
- 해결: Credential Manager 기반 `google_sign_in 7.x`로 이전(디자인 아님, 기능 변경 — 사용자 승인 후 진행).
  - `pubspec.yaml`: `google_sign_in ^6.2.1` → `^7.0.0`(설치 7.2.0).
  - `lib/core/auth/auth_service.dart` 내부만 7.x API로 교체, **공개 API(`signIn`/`trySilent`/`signOut`/`signedIn`/`account`/`hasClientId`)는 유지** → 호출부(`auth_gate`/`auth_screen`/`trips_screen`) 무수정.
    - `initialize(serverClientId:)` 1회 보장, `signIn()`→`authenticate()`, `trySilent()`→`attemptLightweightAuthentication()`, `signOut()`→`instance.signOut()`, idToken은 `account.authentication.idToken`.
  - `android/app/build.gradle.kts`: `minSdk` → **24**(7.x Credential Manager 요구사항).
- 추가 원인/해결: 7.x 전환 후에도 idToken 발급에서 `[28444] Developer console is not set up correctly` 발생 → **기존 웹 클라이언트(serverClientId)가 원인**. 같은 프로젝트(739567881099)에 **웹 애플리케이션 클라이언트를 새로 발급**해 교체하니 해결.
  - 새 웹 클라이언트 ID: `739567881099-o4u2ir5midcjush7br5pbuuiguocpml7.apps.googleusercontent.com`
- 검증: **실기기(R3CT50R45EX)에서 로그인 → 메인 진입까지 성공 확인**(개발자가 직접 + Claude가 adb로 재현). `flutter analyze` 에러 0.
- ⚠️ 후속(백엔드, 미처리): `backend/.../authorizer/app.py` 가 `aud == GOOGLE_CLIENT_ID` 검증 → **배포 시 authorizer env `GOOGLE_CLIENT_ID` 를 새 웹 ID로 갱신** 필요(deploy.sh 5-5). 빌드/실행 명령의 `--dart-define=GOOGLE_CLIENT_ID` 도 새 ID 사용.

### 2026-06-08 — 로그인 화면 재디자인 (로고 + 색 번지는 배경)
- 색상 토큰 파일 `app/lib/core/theme/app_colors.dart` 신규: 허용 4색(#FFFFFF/#1E98D8/#4EC1B6/#A9E198)을 상수로 한곳에 정의.
- 로고 에셋 추가: `docs/logo/Transparent background-polylog_logo.png` → `app/assets/logo/polylog_logo.png` 복사 후 `pubspec.yaml` 에 등록.
- `app/lib/features/auth/auth_screen.dart` 재디자인:
  - 배경: `AnimationController`(6초, reverse 반복) + `LinearGradient([blue, mid, green])` 의 정렬을 보간해 파랑↔초록이 번지며 왔다갔다 하는 애니메이션 배경 적용(참고: `docs/ref-image/login.jpg`).
  - 로고: 기본 아이콘(`Icons.travel_explore`) → 흰 원형 카드 위 실제 로고 이미지(변형·재색칠 없음, 그라데이션 위 대비 확보).
  - 타이틀/부제: 흰색(#FFFFFF) 텍스트로 가독성 확보.
  - 버튼: 흰 배경 + 블루 텍스트/아이콘(`FilledButton` 스타일만 조정, 로그인 로직 `_signIn` 불변).
  - 로딩 인디케이터·클라이언트ID 경고 문구 색만 팔레트(흰색)에 맞춤.
- 색은 4색만 사용. 로그인 기능 로직(`auth_service`/`auth_gate`/`main` 라우팅)은 건드리지 않음.
- 검증: `flutter analyze` 통과(No issues found). 실기기 육안 확인은 사용자 진행.
