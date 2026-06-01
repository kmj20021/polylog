import 'package:flutter/material.dart';

class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('영수증')),
      body: const Center(child: Text('WBS 1.6에서 구현 예정', style: TextStyle(color: Colors.grey))),
    );
  }
}
