import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:polylog/main.dart';

/// 실기기 위에서 도는 진짜 E2E 테스트.
/// 앱 → 배포된 API Gateway → Lambda → Bedrock Claude 까지 실제 호출한다.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('도쿄 신주쿠/맛집 → 실제 AI 추천 카드가 표시된다', (tester) async {
    await tester.pumpWidget(const PolylogApp());
    await tester.pumpAndSettle();

    // 1) 기본 탭이 '추천'(index 1) — 화면이 떠 있는지 확인
    expect(find.text('AI 장소 추천'), findsOneWidget);
    expect(find.text('AI 추천받기'), findsOneWidget);

    // 2) 여행지 입력 (카테고리는 기본값 '맛집')
    await tester.enterText(find.byType(TextField), '도쿄 신주쿠');
    await tester.pump();

    // 3) 버튼 탭 → 실제 네트워크 호출 시작
    // FilledButton.icon 은 비공개 서브타입이라 byType 로 못 잡음 → 라벨 텍스트로 탭.
    final button = find.text('AI 추천받기');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();

    // 4) 로딩 상태 진입 확인
    expect(find.text('추천 생성 중…'), findsOneWidget);

    // 5) 실제 응답을 기다린다 — 결과 헤더 또는 에러 카드 중 하나가 나올 때까지 폴링
    final resultHeader = find.text('도쿄 신주쿠 · 맛집');
    final errorCard = find.textContaining('불러오지 못했어요');
    final ok = await _pumpUntil(
      tester,
      () => resultHeader.evaluate().isNotEmpty || errorCard.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 45),
    );

    // 6) 검증: 타임아웃 없이, 에러 아닌 결과 카드가 떠야 한다
    expect(ok, isTrue, reason: '45초 내 응답이 오지 않음 (네트워크/배포 확인 필요)');
    expect(errorCard, findsNothing, reason: '추천 호출이 에러로 끝남');
    expect(resultHeader, findsOneWidget, reason: '결과 카드 헤더가 표시되지 않음');

    // 추천 본문이 실제로 채워졌는지 (빈 문자열이 아닌지)
    final selectable = tester.widgetList<SelectableText>(find.byType(SelectableText));
    expect(selectable.isNotEmpty, isTrue, reason: '추천 본문(SelectableText)이 없음');
    expect((selectable.first.data ?? '').trim().length, greaterThan(10),
        reason: '추천 텍스트가 비었거나 너무 짧음');
  });
}

/// 실제 비동기(네트워크) 완료를 기다리며 트리를 갱신하는 폴링 헬퍼.
/// integration_test 바인딩에서는 Future.delayed 동안 실제 타이머·I/O 가 진행된다.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.pump();
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}
