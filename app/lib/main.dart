import 'package:flutter/material.dart';
import 'features/auth/auth_screen.dart';
import 'features/recommend/recommend_screen.dart';
import 'features/menu/menu_screen.dart';
import 'features/receipt/receipt_screen.dart';
import 'features/schedule/schedule_screen.dart';

void main() {
  runApp(const PolylogApp());
}

class PolylogApp extends StatelessWidget {
  const PolylogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Polylog',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: const AuthScreen(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  static const List<Widget> _screens = [
    RecommendScreen(),
    MenuScreen(),
    ReceiptScreen(),
    ScheduleScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.explore), label: '추천'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu), label: '메뉴판'),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: '영수증'),
          NavigationDestination(icon: Icon(Icons.calendar_month), label: '일정'),
        ],
      ),
    );
  }
}
