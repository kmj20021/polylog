import 'package:flutter/material.dart';

import 'features/recommend/recommend_screen.dart';

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
      home: const HomeShell(),
    );
  }
}

/// 4탭 하단 내비게이션 셸. index 1 이 AI 추천 화면이다.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 1;

  static const _tabs = <Widget>[
    _PlaceholderTab(title: '홈', icon: Icons.home_outlined),
    RecommendScreen(),
    _PlaceholderTab(title: '여행', icon: Icons.map_outlined),
    _PlaceholderTab(title: '내 정보', icon: Icons.person_outline),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: '추천',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '여행',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '내 정보',
          ),
        ],
      ),
    );
  }
}

class _PlaceholderTab extends StatelessWidget {
  final String title;
  final IconData icon;
  const _PlaceholderTab({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('$title 화면 (준비 중)'),
          ],
        ),
      ),
    );
  }
}
