import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../api/dio_client.dart';

/// 앱 전역 인증 상태(Google OAuth) — 단일 인스턴스.
///
/// ADR-007(Google 단독·Android): Google 로그인으로 Google 이 서명한 **ID 토큰(RS256 JWT)**
/// 을 받는다. 그 토큰 안의 `sub` 가 우리 `user_id`, `aud` 는 `serverClientId`(웹 클라이언트
/// ID)다. 토큰을 [DioClient] 에 넣어 두면 이후 모든 API 요청 헤더에
/// `Authorization: Bearer` 로 자동 첨부되고, 백엔드 `fn-authorizer` 가 이를 검증한다.
///
/// google_sign_in 7.x(Credential Manager 기반)로 동작한다. 레거시 GMS Sign-In 경로가
/// deprecated 되며 발생하던 `ApiException: 10` 을 피하기 위한 것. 공개 API([signIn]/
/// [trySilent]/[signOut]/[signedIn]/[account]/[hasClientId])는 6.x 때와 동일하게 유지해
/// 호출부(`AuthGate`/`AuthScreen`/`TripsScreen`)는 그대로 둔다.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// 빌드 시 주입: `flutter run --dart-define=GOOGLE_CLIENT_ID=<웹 클라이언트 ID>`.
  /// 이 값이 곧 ID 토큰의 `aud` 가 되어 백엔드의 `aud=GOOGLE_CLIENT_ID` 검증과 맞물린다.
  static const String _serverClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID');

  /// 로그인 상태(true=로그인됨). AuthGate 가 구독한다.
  final ValueNotifier<bool> signedIn = ValueNotifier<bool>(false);

  /// 현재 로그인 계정(이름·이메일 표시용). 없으면 null.
  GoogleSignInAccount? _account;
  GoogleSignInAccount? get account => _account;

  /// GOOGLE_CLIENT_ID 가 빌드에 주입됐는지(미주입이면 idToken 이 null 일 위험 → 화면 경고).
  bool get hasClientId => _serverClientId.isNotEmpty;

  /// initialize() 는 7.x 에서 **정확히 한 번** 호출해야 한다. Future 를 캐시해 보장한다.
  Future<void>? _init;
  Future<void> _ensureInitialized() {
    return _init ??= GoogleSignIn.instance.initialize(
      serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
    );
  }

  /// 앱 시작 시 사용자 상호작용 없이 이전 로그인을 조용히 복원한다.
  Future<bool> trySilent() async {
    try {
      await _ensureInitialized();
      // 반환 future 자체가 null 일 수 있다(플랫폼이 스트림으로만 통지하는 경우).
      final future = GoogleSignIn.instance.attemptLightweightAuthentication();
      return _apply(future == null ? null : await future);
    } catch (_) {
      return false;
    }
  }

  /// 사용자가 'Google 로 시작하기'를 눌렀을 때. 취소/실패는 예외로 오므로 잡아서 false.
  Future<bool> signIn() async {
    try {
      await _ensureInitialized();
      if (!GoogleSignIn.instance.supportsAuthenticate()) return false;
      return _apply(await GoogleSignIn.instance.authenticate());
    } on GoogleSignInException {
      // 취소 포함 — 호출부에서 안내 스낵바를 띄운다.
      return false;
    }
  }

  /// 로그아웃 — 토큰 제거 + 상태 false(게이트가 로그인 화면으로 되돌린다).
  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } finally {
      _account = null;
      DioClient().clearIdToken();
      signedIn.value = false;
    }
  }

  /// 계정에서 ID 토큰을 꺼내 DioClient 에 적용하고 [signedIn] 을 갱신한다.
  bool _apply(GoogleSignInAccount? acc) {
    if (acc == null) {
      _account = null;
      signedIn.value = false;
      return false;
    }
    final idToken = acc.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      _account = null;
      signedIn.value = false;
      return false;
    }
    _account = acc;
    DioClient().setIdToken(idToken);
    signedIn.value = true;
    return true;
  }
}
