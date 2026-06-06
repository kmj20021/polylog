import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../menu/menu_screen.dart';
import '../receipt/receipt_screen.dart';
import '../recommend/recommend_screen.dart';
import '../schedule/schedule_screen.dart';
import '../trips/trip.dart';
import '../trips/trips_screen.dart';

/// 앱의 메인 셸 — 하단 탭으로 근처/계획/메뉴/영수증을 '현재 여행' 기준으로 바로 쓴다.
///
/// 핵심 개념 '현재 여행(_current)':
///   - 근처·계획·메뉴·영수증은 모두 어떤 여행에 속한 데이터다(저장 시 trip_id 필요).
///   - 그래서 메인은 하나의 '현재 여행'을 들고 있고, 기능 탭들은 그 여행으로 동작한다.
///   - 앱을 켜면 **오늘이 여행 기간 안인 여행(여행 중)을 자동 선택**한다(Trip.isOngoing).
///     여행 중이 없으면 선택 없음 → 기능 탭은 '내 여행에서 골라주세요' 안내를 보여준다.
///   - '내 여행' 탭에서 다른 여행을 탭하면 현재 여행이 바뀌고 근처 탭으로 이동한다.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;            // 0근처 1계획 2메뉴 3영수증 4내여행
  Trip? _current;            // 현재 여행(없으면 기능 탭은 안내 표시)
  bool _loaded = false;      // 첫 자동 선택을 마쳤는지

  @override
  void initState() {
    super.initState();
    _reloadAndAutoSelect();
  }

  /// 여행 목록을 받아 '현재 여행'을 정리한다.
  ///   - 아직 선택이 없으면 → 오늘이 기간 안인 여행(여행 중)을 자동 선택.
  ///   - 이미 선택돼 있으면 → 그 여행이 아직 존재하면 최신 정보로 갱신, 사라졌으면 해제.
  Future<void> _reloadAndAutoSelect() async {
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'list_trips'},
      );
      final trips = ((res.data?['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Trip.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        if (_current == null) {
          // 여행 중인 첫 여행을 자동 선택(없으면 null 유지).
          Trip? ongoing;
          for (final t in trips) {
            if (t.isOngoing()) {
              ongoing = t;
              break;
            }
          }
          _current = ongoing;
        } else {
          // 선택돼 있던 여행을 최신 목록에서 다시 찾는다(삭제됐으면 해제).
          Trip? still;
          for (final t in trips) {
            if (t.tripId == _current!.tripId) {
              still = t;
              break;
            }
          }
          _current = still;
        }
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true); // 실패해도 화면은 띄운다(내 여행 탭에서 재시도).
    }
  }

  /// '내 여행' 탭에서 여행을 골랐을 때 — 현재 여행으로 삼고 근처 탭으로 이동.
  void _onSelect(Trip trip) {
    setState(() {
      _current = trip;
      _index = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 기능 탭(근처/계획/메뉴/영수증)은 현재 여행이 있어야 동작한다. 현재 여행이 바뀌면
    // ValueKey(tripId) 로 화면을 새로 만들어 그 여행의 데이터를 다시 불러오게 한다.
    final id = _current?.tripId ?? '';
    final name = _current?.name ?? '';
    final tabs = <Widget>[
      _scoped(RecommendScreen(
          key: ValueKey('recommend-$id'), tripId: id, tripName: name)),
      _scoped(ScheduleScreen(
          key: ValueKey('schedule-$id'), tripId: id, tripName: name)),
      _scoped(MenuScreen(
          key: ValueKey('menu-$id'), tripId: id, tripName: name)),
      _scoped(ReceiptScreen(
          key: ValueKey('receipt-$id'), tripId: id, tripName: name)),
      TripsScreen(
        currentTripId: _current?.tripId,
        onSelect: _onSelect,
        onChanged: _reloadAndAutoSelect,
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: '근처',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '계획',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu),
            label: '메뉴',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: '영수증',
          ),
          NavigationDestination(
            icon: Icon(Icons.luggage_outlined),
            selectedIcon: Icon(Icons.luggage),
            label: '내 여행',
          ),
        ],
      ),
    );
  }

  /// 기능 화면을 현재 여행 유무로 감싼다 — 여행이 없으면 안내 화면을 대신 보여준다.
  Widget _scoped(Widget child) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_current == null) return _noTrip();
    return child;
  }

  Widget _noTrip() {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('polylog')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.luggage_outlined, size: 64, color: scheme.primary),
              const SizedBox(height: 16),
              Text('선택된 여행이 없어요',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '"내 여행"에서 여행을 고르면 그 여행 기준으로\n'
                '근처·계획·메뉴·영수증을 쓸 수 있어요.\n'
                '(여행 기간에 오늘이 들면 자동으로 선택됩니다.)',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => setState(() => _index = 4),
                icon: const Icon(Icons.luggage),
                label: const Text('내 여행으로 가기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
