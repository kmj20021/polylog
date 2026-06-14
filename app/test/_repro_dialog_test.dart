import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AlertDialog + Column + TextField 재현', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showDialog<bool>(
              context: ctx,
              builder: (_) => AlertDialog(
                title: const Text('직접 일정 작성'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                          labelText: '일정 내용', hintText: '예) 공항 출발'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: const InputDecoration(
                          labelText: '시간(선택)', hintText: '예) 09:00'),
                    ),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final ex = tester.takeException();
    // ignore: avoid_print
    print('EXCEPTION => $ex');
  });
}
