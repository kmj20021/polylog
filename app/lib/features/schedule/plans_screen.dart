import 'dart:ui' show ImageFilter;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../trips/trip.dart';
import '../trips/trips_screen.dart'; // showTripFormSheet / TripFormResult 재사용
import 'schedule_screen.dart';

/// '계획' 팝업 — 아직 '지나지 않은' 여행 계획만 모아 보여주는 떠 있는 창.
///
/// 메인 홈의 우측 로고 메뉴에서 '계획'을 누르면 이 팝업이 열린다. 전체 화면을 새로
/// 덮지 않고, 누른 순간의 **실제 화면(메인 홈)을 뒤에 그대로 두고 블러만 입힌 채**
/// 가운데 작은 창을 띄운다([showGeneralDialog] 의 라우트는 불투명하지 않아 뒤 화면이
/// 그대로 보이고, 그 위에 [BackdropFilter] 로 흐림 효과를 준다).
///
/// 창 안:
///   - 계획이 없으면 "아직 예정된 계획이 없어요…" 안내 + '새 여행 만들기' 버튼.
///   - 계획이 있으면 목록(진행 중·미래·날짜 미정 = [Trip.hasNotPassed])과
///     맨 아래 '새 여행 만들기' 버튼.
///   - 계획을 탭 → 그 여행의 일정 플래너(ScheduleScreen)를 위에 띄운다(현재 여행은
///     바꾸지 않아 '내 여행' 홈엔 영향이 없다).
///
/// 데이터 출처(모두 fn-schedule 의 POST action 분기 — 새 API 경로 없이 처리):
///   - 목록: POST /schedule {action:"list_trips"} → 클라이언트에서 '안 지난 것'만 거름
///   - 생성: POST /schedule {action:"create_trip", name, start_date, end_date}
Future<void> showPlansPopup(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '계획',
    barrierColor: Colors.transparent, // 어둠 막은 팝업 안에서 직접 그린다
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, __) => const _PlansDialog(),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOut);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _PlansDialog extends StatefulWidget {
  const _PlansDialog();

  @override
  State<_PlansDialog> createState() => _PlansDialogState();
}

class _PlansDialogState extends State<_PlansDialog> {
  bool _loading = true;
  String? _error;
  final List<Trip> _plans = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 여행 전체를 받아 '아직 지나지 않은' 것만 남긴다.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'list_trips'},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _plans
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => Trip.fromJson(e.cast<String, dynamic>()))
              .where((t) => t.hasNotPassed()));
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? '네트워크 오류';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 새 계획 만들기 — '새 여행'과 같은 입력 시트를 재사용해 이름·기간을 받아 저장.
  Future<void> _create() async {
    final data = await showTripFormSheet(context);
    if (data == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>('/schedule', data: {
        'action': 'create_trip',
        'name': data.name,
        'start_date': data.startDate,
        'end_date': data.endDate,
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('계획 생성 실패: $e')));
    }
  }

  /// 계획을 탭 → 그 여행의 일정 플래너를 팝업 위에 띄운다('현재 여행'은 안 바꿈).
  void _open(Trip trip) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScheduleScreen(
        tripId: trip.tripId,
        tripName: trip.name,
        day: trip.defaultDayYmd(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Stack(
      children: [
        // 뒤 화면(메인 홈)을 흐리게 + 살짝 어둡게. 빈 곳을 탭하면 팝업을 닫는다.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(color: Colors.black.withValues(alpha: 0.12)),
            ),
          ),
        ),
        // 가운데 떠 있는 창. 폭은 화면에 맞춰 확정값으로(최대 400) 줘서 내용에 따라
        // 좁아지지 않게 하고, 높이는 화면의 70% 까지로 제한한다.
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.7),
            child: SizedBox(
              width: (size.width - 48).clamp(280.0, 400.0),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 8,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: _card(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card() {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 제목 줄 + 닫기.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(
            children: [
              Text('계획',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 본문(스크롤 가능) — 높이는 위 ConstrainedBox 가 제한한다.
        Flexible(child: _content()),
      ],
    );
  }

  Widget _content() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_loading && _plans.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null && _plans.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            Text('계획을 불러오지 못했어요',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(_error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }
    // 목록(또는 빈 안내) + 맨 끝 '새 여행 만들기' 버튼.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_plans.isEmpty)
            _EmptyHint()
          else
            ..._plans.map((t) => _PlanCard(
                  trip: t,
                  isOngoing: t.isOngoing(),
                  onTap: () => _open(t),
                )),
          const SizedBox(height: 4),
          _CreateButton(onTap: _create),
        ],
      ),
    );
  }
}

/// 계획이 하나도 없을 때의 안내 블록.
class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Icon(Icons.event_note_outlined, size: 56, color: scheme.primary),
          const SizedBox(height: 12),
          Text('아직 예정된 계획이 없어요',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('아래 버튼으로 새 여행 계획을 만들어 보세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 계획 한 장 — 탭하면 그 여행의 일정 플래너로 들어간다. '여행 중'이면 배지를 단다.
class _PlanCard extends StatelessWidget {
  final Trip trip;
  final bool isOngoing;
  final VoidCallback onTap;

  const _PlanCard({
    required this.trip,
    required this.isOngoing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.map_outlined, color: scheme.onPrimaryContainer),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(trip.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (isOngoing) ...[
              const SizedBox(width: 8),
              _Badge(text: '여행 중', color: scheme.primary),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.event, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(trip.dateRangeLabel,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 맨 끝 '새 여행 만들기' — '새 여행'과 같은 입력 시트를 띄운다.
class _CreateButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add),
      label: const Text('새 여행 만들기'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        side: BorderSide(color: scheme.primary),
        foregroundColor: scheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

/// 작은 알약형 배지(예: "여행 중").
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}
