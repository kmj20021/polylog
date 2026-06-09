# 로그인(Google Sign-In) 트러블슈팅 런북

> 로그인이 안 될 때 **여기부터 본다.** (2026-06-08 기준, 이틀 헤맨 끝에 해결한 내용)

---

## TL;DR — 확정된 구조
- 앱은 **`google_sign_in` 7.x (Credential Manager)** 를 쓴다. **레거시 GMS Sign-In(6.x)은 deprecated → `ApiException: 10` 의 원인.** 절대 6.x로 되돌리지 말 것.
- 로그인에 필요한 OAuth 3종 (전부 **같은 GCP 프로젝트 `739567881099`**):
  1. **Android 클라이언트** `polylog_android` — 패키지 `com.shingu.polylog` + 디버그 SHA-1 (아래).
  2. **웹 클라이언트** — 앱이 `--dart-define=GOOGLE_CLIENT_ID=` 로 받는 **serverClientId**. idToken 의 `aud`.
  3. **OAuth 동의 화면** — 게시(프로덕션)·구성 완료 상태.
- **앱의 GOOGLE_CLIENT_ID(웹) == 백엔드 authorizer env GOOGLE_CLIENT_ID** 여야 한다(서버가 `aud` 검증).

## 핵심 값 (복붙용)
```
프로젝트 번호      : 739567881099
패키지명           : com.shingu.polylog
디버그 SHA-1       : 6D:0C:34:E6:F1:73:B8:89:51:7D:A4:E8:7F:61:9B:27:79:EA:7B:21
(필요시) SHA-256   : BA:E5:2E:C0:A3:1C:9D:03:8B:C2:12:00:8D:6F:62:91:56:F6:98:8E:C7:8F:54:7E:64:DB:CD:C4:83:C0:B9:CF
웹 클라이언트 ID   : 739567881099-o4u2ir5midcjush7br5pbuuiguocpml7.apps.googleusercontent.com
실행 명령          : flutter run --dart-define=GOOGLE_CLIENT_ID=<위 웹 ID>
AWS region         : ap-northeast-2
authorizer 함수    : polylog-fn-authorizer
```
> 디버그 SHA-1 다시 뽑기:
> `keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android`

---

## 증상 → 원인 → 조치 (빠른 진단)

| 증상 | 거의 항상 이 원인 | 조치 |
|---|---|---|
| `ApiException: 10` (계정 선택창도 안 뜸) | **레거시 GMS 경로** 또는 OAuth 등록 불일치 | 7.x 쓰는지 확인. SHA-1/패키지/프로젝트 일치 확인 |
| 계정창은 뜨는데 선택 후 로그인 안 됨, 로그에 `[28444] Developer console is not set up correctly` | **웹 클라이언트(serverClientId) 문제** (타입/프로젝트/꼬임) | 같은 프로젝트에 **웹 애플리케이션 클라이언트 새로 만들어** ID 교체 |
| 로그인은 되는데 API가 403 | 백엔드 `GOOGLE_CLIENT_ID` 가 앱과 다른 값(옛 ID) | authorizer env 를 앱과 같은 웹 ID로 갱신(아래) |
| "토큰을 받지 못했어요" + `GOOGLE_CLIENT_ID 미주입` 경고 | `--dart-define` 누락 | 실행 명령에 웹 ID 주입 |

### 진단 팁
- 실패 사유 정확히 보기(임시): `AuthService.signIn()` catch 에서
  `debugPrint('code=${e.code} desc=${e.description}')` 찍고 `flutter run`/logcat 으로 확인.
- adb 로 직접 재현: 앱 띄우고 `adb shell screencap` + `adb shell input tap x y`.

---

## 백엔드 GOOGLE_CLIENT_ID 갱신 (앱 웹 ID 바꿨을 때 필수)
authorizer 가 idToken 의 `aud == env GOOGLE_CLIENT_ID` 를 검증한다. 앱 웹 ID를 바꾸면 **반드시** 같이 바꿔야 API 가 안 막힌다.

**CloudShell 한 줄 (권장):**
```bash
aws lambda update-function-configuration \
  --function-name polylog-fn-authorizer \
  --environment "Variables={GOOGLE_CLIENT_ID=<새 웹 ID>}" \
  --region ap-northeast-2
```
확인:
```bash
aws lambda get-function-configuration --function-name polylog-fn-authorizer \
  --region ap-northeast-2 --query "Environment.Variables.GOOGLE_CLIENT_ID" --output text
```
> 클라이언트 ID 는 **코드에 없다.** authorizer `app.py` 는 `os.environ.get("GOOGLE_CLIENT_ID")` 로 읽는다 → 코드 수정 X, **환경변수 값만** 바꾼다.
> `bash scripts/deploy.sh` 로도 가능하지만, **`export GOOGLE_CLIENT_ID=새ID` 를 먼저** 해야 5-5 블록이 주입한다(안 하면 건너뜀).

---

## 절대 하지 말 것 / 주의
- `google_sign_in` 6.x 로 다운그레이드 ❌ (레거시 = 에러 10 재발). minSdk 24 유지(7.x 요구).
- serverClientId 에 **Android 클라이언트 ID** 넣기 ❌ → 반드시 **웹** 타입.
- 웹 클라이언트를 바꿨으면 **앱·백엔드 둘 다** 새 ID로 맞춘 뒤에 옛 클라이언트 삭제.
