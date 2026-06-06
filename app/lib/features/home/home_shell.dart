import 'package:flutter/material.dart';

import '../recommend/recommend_screen.dart';
import '../schedule/schedule_screen.dart';

/// 한 '여행' 안으로 들어왔을 때의 화면 셸 — 하단 탭으로 근처/계획을 오간다.
///
/// '내 여행' 목록(TripsScreen)에서 여행 하나를 탭하면 이 셸이 push 되고, 선택한
/// [tripId] 가 근처·계획 화면 모두에 주입된다(예전엔 'demo-trip' 으로 고정돼 있었다).
/// 뒤로가기를 누르면(각 화면 AppBar 의 ← ) 다시 여행 목록으로 돌아간다.
class HomeShell extends StatefulWidget {
  final String tripId;   // 이 셸이 다루는 여행 식별자(자식 화면들이 공유)
  final String tripName; // 화면 상단에 보여줄 여행 이름(지금 어느 여행인지 알려줌)

  const HomeShell({super.key, required this.tripId, required this.tripName});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0; // 0=근처, 1=계획

  @override
  Widget build(BuildContext context) {
    // IndexedStack: 탭을 바꿔도 각 화면의 상태(스크롤·대화 등)를 유지한다.
    final tabs = <Widget>[
      RecommendScreen(tripId: widget.tripId, tripName: widget.tripName),
      ScheduleScreen(tripId: widget.tripId, tripName: widget.tripName),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: '근처',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '계획',
          ),
        ],
      ),
    );
  }
}
