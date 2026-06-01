import 'package:flutter/material.dart';

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('일정')),
      body: const Center(child: Text('WBS 1.7에서 구현 예정', style: TextStyle(color: Colors.grey))),
    );
  }
}
