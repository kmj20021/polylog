import 'package:flutter/material.dart';

import 'features/home/main_shell.dart';

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
      // 홈 = 메인 셸. 현재 여행을 자동 선택하고 근처/계획/메뉴/영수증을 바로 쓴다.
      home: const MainShell(),
    );
  }
}
