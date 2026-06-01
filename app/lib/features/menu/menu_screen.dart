import 'package:flutter/material.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('메뉴판')),
      body: const Center(child: Text('WBS 1.5에서 구현 예정', style: TextStyle(color: Colors.grey))),
    );
  }
}
