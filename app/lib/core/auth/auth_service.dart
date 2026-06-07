import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../api/dio_client.dart';

/// 앱 전역 인증 상태(Google OAuth) — 단일 인스턴스.
///
/// ADR-007(Google 단독·Android): `google_sign_in` 으로 로그인하면 Google 이 서명한
/// **ID 토큰(RS256 JWT)** 을 받는다. 그 토큰 안의 `sub` 가 우리 `user_id`, `aud` 는
/// `serverClientId`(웹 클라이언트 ID)다. 토큰을 [DioClient] 에 넣어 두면 이후 모든
/// API 요청 헤더에 `Authorization: Bearer` 로 자동 첨부되고, 백엔드 `fn-authorizer`
/// 가 이를 검증한다(서버 강제는 추후 활성화).
///
/// 로그인 여부는 [signedIn](ValueNotifier)로 알린다 → `AuthGate` 가 이를 듣고 화면을
/// 로그인/메인으로 전환한다. 덕분에 sign-out 을 **어느 화면에서 호출해도** 게이트가
/// 자동으로 반응한다(콜백을 화면마다 내려줄 필요가 없다).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// 빌드 시 주입: `flutter run --dart-define=GOOGLE_CLIENT_ID=<웹 클라이언트 ID>`.
  /// 클라이언트 ID 는 비밀이 아니지만, 환경별 교체를 위해 하드코딩 대신 define 으로 받는다.
  /// 이 값이 곧 ID 토큰의 `aud` 가 되어 백엔드의 `aud=GOOGLE_CLIENT_ID` 검증과 맞물린다.
  static const String _serverClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID');

  final GoogleSignIn _google = GoogleSignIn(
    scopes: const ['email', 'profile'],
    // 비어 있으면 null → 로그인은 되어도 idToken 이 null 일 수 있다(아래 [hasClientId] 경고).
    serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
  );

  /// 로그인 상태(true=로그인됨). AuthGate 가 구독한다.
  final ValueNotifier<bool> signedIn = ValueNotifier<bool>(false);

  /// 현재 로그인 계정(이름·이메일 표시용). 없으면 null.
  GoogleSignInAccount? get account => _google.currentUser;

  /// GOOGLE_CLIENT_ID 가 빌드에 주입됐는지(미주입이면 idToken 이 null 일 위험 → 화면 경고).
  bool get hasClientId => _serverClientId.isNotEmpty;

  /// 앱 시작 시 사용자 상호작용 없이 이전 로그인을 조용히 복원한다.
  Future<bool> trySilent() async {
    try {
      return _apply(await _google.signInSilently());
    } catch (_) {
      return false;
    }
  }

  /// 사용자가 'Google 로 시작하기'를 눌렀을 때.
  Future<bool> signIn() async => _apply(await _google.signIn());

  /// 로그아웃 — 토큰 제거 + 상태 false(게이트가 로그인 화면으로 되돌린다).
  Future<void> signOut() async {
    try {
      await _google.signOut();
    } finally {
      DioClient().clearIdToken();
      signedIn.value = false;
    }
  }

  /// 계정에서 ID 토큰을 꺼내 DioClient 에 적용하고 [signedIn] 을 갱신한다.
  Future<bool> _apply(GoogleSignInAccount? acc) async {
    if (acc == null) {
      signedIn.value = false;
      return false;
    }
    final auth = await acc.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      signedIn.value = false;
      return false;
    }
    DioClient().setIdToken(idToken);
    signedIn.value = true;
    return true;
  }
}
