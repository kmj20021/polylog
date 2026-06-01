import 'package:flutter_test/flutter_test.dart';

import 'package:polylog/main.dart';

void main() {
  testWidgets('추천 화면이 기본 탭으로 렌더링된다', (WidgetTester tester) async {
    await tester.pumpWidget(const PolylogApp());

    // index 1(추천)이 기본 탭 — AppBar 제목과 버튼이 보여야 한다.
    expect(find.text('AI 장소 추천'), findsOneWidget);
    expect(find.text('AI 추천받기'), findsOneWidget);
  });
}
