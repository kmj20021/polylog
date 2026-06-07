import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../home/main_shell.dart';
import 'auth_screen.dart';

/// 앱 루트 — 로그인 상태에 따라 로그인 화면 / 메인 셸을 보여준다.
///
/// 앱을 켜면 먼저 이전 로그인을 조용히 복원(trySilent)하고, 이후 [AuthService.signedIn]
/// 을 구독해 로그인/로그아웃에 맞춰 화면을 자동 전환한다. 어느 화면에서 signOut 해도
/// 이 게이트가 반응하므로 화면마다 콜백을 내려줄 필요가 없다.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checking = true; // 앱 시작 시 이전 로그인 복원 중인지

  @override
  void initState() {
    super.initState();
    AuthService.instance.trySilent().whenComplete(() {
      if (mounted) setState(() => _checking = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.instance.signedIn,
      builder: (_, signed, __) =>
          signed ? const MainShell() : const AuthScreen(),
    );
  }
}
