import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../features/menu/menu_screen.dart';
import '../features/receipt/receipt_screen.dart';
import '../features/recommend/recommend_screen.dart';
import '../features/schedule/schedule_screen.dart';

/// 기능 화면(계획·메뉴·영수증·근처)이 서로 이동할 때 쓰는 목적지 구분.
enum FeatureDest { plan, menu, receipt, nearby }

/// 기능 화면 우측 상단 '로고'를 눌렀을 때 — 다른 기능으로 곧장 건너뛰는 드롭다운 메뉴.
///
/// 메인 셸(MainShell)의 우측 로고 메뉴와 같은 역할을, '이미 기능 화면 안에 들어와 있는'
/// 상태에서 제공한다. 그래서 매번 홈으로 돌아갔다가 다시 들어올 필요가 없다.
///
///   - [current] 로 지금 보고 있는 화면은 체크 표시하고 못 누르게 비활성화한다.
///   - 다른 기능을 고르면 [Navigator.pushReplacement] 로 현재 화면을 '갈아끼운다'.
///     → 기능끼리 아무리 옮겨 다녀도 스택이 깊어지지 않아, 뒤로가기 한 번이면 홈이다.
///   - 같은 여행 맥락([tripId]·[day])을 그대로 넘겨 다음 화면도 같은 여행을 본다.
Future<void> showFeatureNavMenu(
  BuildContext context, {
  required String tripId,
  required String tripName,
  required String day,
  required FeatureDest current,
}) async {
  final size = MediaQuery.of(context).size;
  final dest = await showMenu<FeatureDest>(
    context: context,
    color: AppColors.base,
    elevation: 8,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    // 로고가 있는 우측 상단(헤더 높이 56) 아래에서 펼쳐지도록 위치를 잡는다.
    position: RelativeRect.fromLTRB(size.width - 220, 58, 12, 0),
    items: [
      _navItem(Icons.map_outlined, '계획', FeatureDest.plan, current),
      _navItem(Icons.restaurant_menu_outlined, '메뉴', FeatureDest.menu, current),
      _navItem(Icons.receipt_long_outlined, '영수증', FeatureDest.receipt, current),
      _navItem(Icons.auto_awesome_outlined, '근처', FeatureDest.nearby, current),
    ],
  );
  if (dest == null || dest == current || !context.mounted) return;

  final Widget screen;
  switch (dest) {
    case FeatureDest.plan:
      screen = ScheduleScreen(tripId: tripId, tripName: tripName, day: day);
    case FeatureDest.menu:
      screen = MenuScreen(tripId: tripId, tripName: tripName, day: day);
    case FeatureDest.receipt:
      screen = ReceiptScreen(tripId: tripId, tripName: tripName, day: day);
    case FeatureDest.nearby:
      screen = RecommendScreen(tripId: tripId, tripName: tripName, day: day);
  }
  Navigator.of(context)
      .pushReplacement(MaterialPageRoute(builder: (_) => screen));
}

/// 메뉴 한 줄 — 지금 화면([current])이면 파란 체크 + 비활성(못 누름)으로 표시한다.
PopupMenuItem<FeatureDest> _navItem(
  IconData icon,
  String label,
  FeatureDest dest,
  FeatureDest current,
) {
  final isCurrent = dest == current;
  return PopupMenuItem<FeatureDest>(
    value: dest,
    enabled: !isCurrent,
    child: Row(
      children: [
        Icon(icon,
            size: 20,
            color: isCurrent
                ? AppColors.blue.withValues(alpha: 0.4)
                : AppColors.blue),
        const SizedBox(width: 12),
        Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCurrent ? Colors.black38 : Colors.black87)),
        if (isCurrent) ...[
          const Spacer(),
          const Icon(Icons.check, size: 16, color: AppColors.blue),
        ],
      ],
    ),
  );
}
