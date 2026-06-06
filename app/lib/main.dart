import 'package:flutter/material.dart';

import 'features/trips/trips_screen.dart';

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
      // 홈 = '내 여행' 목록. 여행을 고르면 그 여행의 근처/계획(HomeShell)으로 들어간다.
      home: const TripsScreen(),
    );
  }
}
