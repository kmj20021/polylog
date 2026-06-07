import 'package:flutter/material.dart';

import 'features/auth/auth_gate.dart';

void main() => runApp(const PolylogApp());

class PolylogApp extends StatelessWidget {
  const PolylogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'polylog',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B6FB6),
        useMaterial3: true,
      ),
      // 홈 = 인증 게이트. 로그인돼 있으면 메인 셸, 아니면 로그인 화면을 보여준다.
      home: const AuthGate(),
    );
  }
}
