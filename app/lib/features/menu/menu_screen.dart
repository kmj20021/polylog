import 'package:flutter/material.dart';

/// 메뉴판 번역 화면 — 현재 여행(tripId)에 속한 메뉴 분석을 다룬다(WBS 1.5에서 구현).
///
/// 아직 본 기능은 미구현이지만, 저장 시 올바른 여행에 들어가도록 [tripId] 를 미리 받아 둔다
/// (메인 셸이 '현재 여행'을 주입). 구현 시 polylog-menus 에 trip_id 로 저장하면 된다.
class MenuScreen extends StatelessWidget {
  final String tripId;
  final String tripName;
  const MenuScreen(
      {super.key, required this.tripId, required this.tripName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$tripName · 메뉴판')),
      body: const Center(
        child: Text('WBS 1.5에서 구현 예정', style: TextStyle(color: Colors.grey)),
      ),
    );
  }
}
