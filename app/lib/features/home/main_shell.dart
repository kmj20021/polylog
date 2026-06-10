import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../menu/menu_screen.dart';
import '../receipt/receipt_screen.dart';
import '../recommend/recommend_screen.dart';
import '../schedule/schedule_screen.dart';
import '../trips/trip.dart';
import '../trips/trips_screen.dart';
import 'my_trip_home.dart';

/// 앱의 메인 셸 — 레퍼런스(docs/ref-image/main.jpg) 구조.
///
///   - 흰색 상단 헤더 : 좌측 햄버거 / 우측 로고 원형 + "내 여행" + 날짜 스트립.
///   - 블루 패널      : 상단이 곡선으로 깎인 패널. 선택한 날짜의 계획을 타임라인 카드로(MyTripHome).
///   - 좌측 햄버거    : 드로어로 '다른 여행'(오늘이 기간 밖) 전환 + '내 여행 관리'.
///   - 우측 로고 원형 : 누르면 아래로 펼쳐지는 메뉴 → 계획·메뉴·영수증·근처로 이동(push).
///
/// '현재 여행(_current)' — 기능 화면은 모두 한 여행에 속한 데이터다. 앱을 켜면 '여행 중'
/// (오늘이 기간 안)인 여행을 자동 선택한다. '선택 날짜(_selectedDay)'는 셸이 들고 있어
/// 날짜 스트립이 표시·변경하고, 계획/근처로 담을 때 그 날짜로 저장된다.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final List<Trip> _trips = []; // 드로어('다른 여행')용 전체 목록
  Trip? _current;               // 현재 여행(없으면 안내 표시)
  String _selectedDay = '';     // 보고 있는 날짜 — 계획/근처로 담을 때도 이 날 사용
  bool _loaded = false;         // 첫 자동 선택을 마쳤는지
  bool _menuOpen = false;       // 우측 로고 펼침 메뉴 열림 여부
  int _homeTick = 0;            // 기능 화면에서 돌아오면 ++ → 홈을 새로 만들어 계획 새로고침

  @override
  void initState() {
    super.initState();
    _reloadAndAutoSelect();
  }

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
        _trips
          ..clear()
          ..addAll(trips);
        if (_current == null) {
          Trip? ongoing;
          for (final t in trips) {
            if (t.isOngoing()) {
              ongoing = t;
              break;
            }
          }
          _current = ongoing;
        } else {
          Trip? still;
          for (final t in trips) {
            if (t.tripId == _current!.tripId) {
              still = t;
              break;
            }
          }
          _current = still;
        }
        // 선택 날짜를 현재 여행에 맞춘다 — 비었거나 이 여행 날짜가 아니면 기본 날짜로.
        final valid =
            (_current?.days() ?? const <DateTime>[]).map(Trip.ymd).toSet();
        if (_selectedDay.isEmpty || !valid.contains(_selectedDay)) {
          _selectedDay = _current?.defaultDayYmd() ?? '';
        }
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  /// 드로어에서 다른 여행을 골랐을 때 — 현재 여행으로 삼고 드로어를 닫는다.
  void _selectTrip(Trip trip) {
    Navigator.of(context).pop();
    setState(() {
      _current = trip;
      _selectedDay = trip.defaultDayYmd();
    });
  }

  /// 우측 로고 메뉴에서 기능을 골랐을 때 — 그 화면을 현재 여행으로 연다(push).
  /// 돌아오면 홈을 새로 만들어(계획 담기/편집 결과를) 다시 불러온다.
  Future<void> _openFeature(Widget screen) async {
    setState(() => _menuOpen = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() => _homeTick++);
  }

  @override
  Widget build(BuildContext context) {
    final id = _current?.tripId ?? '';
    final name = _current?.name ?? '';

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.base,
      drawer: _OtherTripsDrawer(
        trips: _trips,
        currentId: _current?.tripId,
        onSelect: _selectTrip,
        onManage: () async {
          Navigator.of(context).pop();
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TripsScreen(
              currentTripId: _current?.tripId,
              onSelect: (t) => setState(() {
                _current = t;
                _selectedDay = t.defaultDayYmd();
              }),
              onChanged: _reloadAndAutoSelect,
            ),
          ));
          await _reloadAndAutoSelect();
        },
      ),
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _Header(
                  trip: _current,
                  selectedDay: _selectedDay,
                  onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  // 여행이 없어도 항상 누를 수 있게 한다('계획' 등 기능 입구이기 때문).
                  // 여행이 필요한 기능은 메뉴 선택 시점에 별도로 안내한다(_openFeature 가드).
                  onLogoTap: () => setState(() => _menuOpen = !_menuOpen),
                  onSelectDay: (d) => setState(() => _selectedDay = d),
                ),
                // 블루 패널 — 상단을 곡선으로 깎아(레퍼런스 main.jpg) 흰 헤더가
                // 곡선으로 흘러내리게 한다(깎인 부분엔 흰 Scaffold 배경이 드러난다).
                Expanded(
                  child: ClipPath(
                    clipper: _PanelCurveClipper(),
                    child: Container(
                      width: double.infinity,
                      color: AppColors.blue,
                      child: _panelChild(),
                    ),
                  ),
                ),
              ],
            ),
            // 펼침 메뉴 바깥을 누르면 닫히는 투명 막.
            if (_menuOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _menuOpen = false),
                ),
              ),
            // 우측 상단 로고 아래로 펼쳐지는 기능 메뉴.
            Positioned(
              top: 56,
              right: 20,
              child: _ExpandingNavMenu(
                open: _menuOpen,
                onSelect: (dest) {
                  // '메뉴'(구글 렌즈)는 여행이 없어도 쓸 수 있지만, 계획·영수증·근처는
                  // 한 여행에 속한 데이터라 여행이 없으면 열어도 비어 있다. 그래서
                  // 여행이 없을 땐 안내만 하고 멈춘다(왼쪽 위에서 여행 고르기 유도).
                  if (dest != _NavDest.menu && _current == null) {
                    setState(() => _menuOpen = false);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('먼저 왼쪽 위에서 여행을 고르거나 만들어 주세요.')));
                    return;
                  }
                  switch (dest) {
                    case _NavDest.plan:
                      _openFeature(ScheduleScreen(
                          tripId: id, tripName: name, day: _selectedDay));
                    case _NavDest.menu:
                      _openFeature(MenuScreen(
                          tripId: id, tripName: name, day: _selectedDay));
                    case _NavDest.receipt:
                      _openFeature(ReceiptScreen(
                          tripId: id, tripName: name, day: _selectedDay));
                    case _NavDest.nearby:
                      _openFeature(RecommendScreen(
                          tripId: id, tripName: name, day: _selectedDay));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 블루 패널 안 — 현재 여행의 홈, 없으면 안내.
  Widget _panelChild() {
    if (!_loaded) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.base));
    }
    if (_current == null) return _noTrip();
    return MyTripHome(
      key: ValueKey('${_current!.tripId}:$_homeTick'),
      trip: _current!,
      selectedDay: _selectedDay,
    );
  }

  Widget _noTrip() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.luggage_outlined, size: 64, color: AppColors.base),
            const SizedBox(height: 16),
            const Text('선택된 여행이 없어요',
                style: TextStyle(
                    color: AppColors.base,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '왼쪽 위 메뉴에서 여행을 고르거나 새로 만들어 보세요.\n'
              '(여행 기간에 오늘이 들면 자동으로 선택됩니다.)',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.base.withValues(alpha: 0.85)),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu),
              label: const Text('여행 고르기'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 흰색 상단 헤더 — 햄버거 / 로고 원형 + "내 여행" + 여행 이름·오늘 + 날짜 스트립.
class _Header extends StatelessWidget {
  final Trip? trip;
  final String selectedDay;
  final VoidCallback onMenu;
  final VoidCallback? onLogoTap; // 현재 여행 없으면 null(비활성)
  final ValueChanged<String> onSelectDay;
  const _Header({
    required this.trip,
    required this.selectedDay,
    required this.onMenu,
    required this.onLogoTap,
    required this.onSelectDay,
  });

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  String _todayLabel() {
    final n = DateTime.now();
    return '${n.month}월 ${n.day}일 (${_weekdays[n.weekday - 1]})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = trip?.days() ?? const <DateTime>[];
    return Container(
      color: AppColors.base,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 상단 아이콘 줄: 햄버거 / 로고 원형 (+ 우상단을 감싸는 블루 블록)
          Stack(
            clipBehavior: Clip.none,
            children: [
              // 로고 버튼을 감싸는 블루 라운드 블록 — 우상단 모서리에 붙어 좌하단이
              // 크게 둥글어, 곡선이 그 버튼만 비켜 지나가는 느낌을 준다.
              Positioned(
                top: -6,
                right: -20,
                child: SizedBox(
                  // 96(원래 폭) + 44(좌상단 모서리 좌측 확장) = 140.
                  // 우측을 right:-20 으로 고정해 우측 모서리들은 제자리에 둔다.
                  width: 140,
                  height: 72,
                  child: ClipPath(
                    clipper: _LogoBlobClipper(),
                    child: const ColoredBox(color: AppColors.blue),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: '다른 여행',
                    onPressed: onMenu,
                    icon: const Icon(Icons.menu),
                    color: Colors.black87,
                  ),
                  GestureDetector(
                    onTap: onLogoTap,
                    child: Opacity(
                      opacity: onLogoTap == null ? 0.4 : 1,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // 블루 블록 위에 얹히므로 흰 링으로 또렷하게.
                          border: Border.all(color: AppColors.base, width: 2.5),
                        ),
                        child: const CircleAvatar(
                          radius: 20,
                          backgroundColor: AppColors.base,
                          backgroundImage:
                              AssetImage('assets/logo/polylog_logo.png'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('내 여행',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800, color: Colors.black87)),
          const SizedBox(height: 6),
          Row(
            children: [
              if (trip != null)
                Flexible(
                  child: Text(trip!.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: AppColors.blue, fontWeight: FontWeight.w700)),
                ),
              if (trip != null) const SizedBox(width: 12),
              const Spacer(),
              Text('Today',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.bold, color: Colors.black87)),
              const SizedBox(width: 6),
              Text(_todayLabel(),
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: Colors.black45)),
            ],
          ),
          if (days.isNotEmpty) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: days.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final d = days[i];
                  final ymd = Trip.ymd(d);
                  return _DateChip(
                    day: d.day,
                    weekday: _weekdays[d.weekday - 1],
                    selected: ymd == selectedDay,
                    onTap: () => onSelectDay(ymd),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 날짜 스트립 칩 — 선택 시 블루 채움(흰 글씨), 평상시 흰 카드(테두리).
class _DateChip extends StatelessWidget {
  final int day;
  final String weekday;
  final bool selected;
  final VoidCallback onTap;
  const _DateChip({
    required this.day,
    required this.weekday,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.base : Colors.black87;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 50,
        decoration: BoxDecoration(
          color: selected ? AppColors.blue : AppColors.base,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: selected ? AppColors.blue : Colors.black12, width: 1.5),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.blue.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(day.toString().padLeft(2, '0'),
                style: TextStyle(
                    color: fg, fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 2),
            Text(weekday,
                style: TextStyle(
                    color: selected
                        ? AppColors.base.withValues(alpha: 0.9)
                        : Colors.black38,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// 블루 패널 상단 곡선(레퍼런스 main.jpg의 '흰 곡선').
///
/// 패널의 윗변을 직선이 아닌 부드러운 곡선으로 깎는다. 좌측이 가장 깊게(흰색이 더
/// 내려옴) 들어왔다가 우측으로 올라가며 사라지는 단일 베지에 스윕이다. 깎인 영역엔
/// 흰 Scaffold 배경(AppColors.base)이 드러나 헤더의 흰색과 이어진다.
class _PanelCurveClipper extends CustomClipper<Path> {
  /// 곡선이 가장 깊게 내려오는 깊이(px).
  static const _depth = 40.0;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(0, _depth) // 좌측 윗점 — 흰색이 가장 깊게 내려온 자리
      ..quadraticBezierTo(w * 0.5, _depth * 1.15, w, 0) // 우측 윗점까지 스윕
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// 우상단 로고 블록 모양 — 사각형의 '왼쪽 위 모서리만' 좌측으로 옮긴 사다리꼴.
///
/// 우상단·우하단 모서리와 좌하단 라운드는 제자리에 두고, 좌상단만 좌측으로 빠져
/// 좌변이 사선이 된다. 좌상단 이동량은 SizedBox 폭(196) − 원래 폭(96) = 100px 이며,
/// 좌하단 모서리는 원래 좌변 자리(local x = 100)에서 [_radius]로 둥글린다.
class _LogoBlobClipper extends CustomClipper<Path> {
  static const _radius = 40.0; // 좌하단 라운드

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    const blx = 100.0; // 좌하단 모서리 x(= 옮기기 전 좌변 위치)
    // 좌하단 → 좌상단(0,0) 사선 방향의 단위벡터(라운드 끝점 계산용).
    final len = math.sqrt(blx * blx + h * h);
    final ux = -blx / len, uy = -h / len;
    return Path()
      ..moveTo(0, 0) // 좌상단 — 좌측으로 100px 이동
      ..lineTo(w, 0) // 우상단 — 그대로
      ..lineTo(w, h) // 우하단 — 그대로
      ..lineTo(blx + _radius, h) // 하단변
      ..quadraticBezierTo(blx, h, blx + ux * _radius, h + uy * _radius) // 좌하단 라운드
      ..lineTo(0, 0) // 사선 좌변
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// 우측 로고 메뉴의 네 목적지.
enum _NavDest { plan, menu, receipt, nearby }

/// 로고 아래로 '쭉 내려오며' 펼쳐지는 기능 메뉴(계획/메뉴/영수증/근처).
class _ExpandingNavMenu extends StatelessWidget {
  final bool open;
  final ValueChanged<_NavDest> onSelect;
  const _ExpandingNavMenu({required this.open, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        offset: open ? Offset.zero : const Offset(0, -0.08),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: open ? 1 : 0,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(18),
            color: AppColors.base,
            child: Container(
              width: 184,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _item(Icons.map_outlined, '계획', _NavDest.plan),
                  _item(Icons.restaurant_menu_outlined, '메뉴', _NavDest.menu),
                  _item(Icons.receipt_long_outlined, '영수증', _NavDest.receipt),
                  _item(Icons.auto_awesome_outlined, '근처', _NavDest.nearby),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, _NavDest dest) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: AppColors.blue),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: () => onSelect(dest),
    );
  }
}

/// 좌측 드로어 — '다른 여행'(오늘이 기간에 안 든 여행) 목록 + '내 여행 관리' 진입점.
class _OtherTripsDrawer extends StatelessWidget {
  final List<Trip> trips;
  final String? currentId;
  final ValueChanged<Trip> onSelect;
  final VoidCallback onManage;
  const _OtherTripsDrawer({
    required this.trips,
    required this.currentId,
    required this.onSelect,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final others =
        trips.where((t) => !t.isOngoing() && t.tripId != currentId).toList();
    return Drawer(
      backgroundColor: AppColors.base,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('다른 여행',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: others.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '다른 여행이 없어요.\n아래 "내 여행 관리"에서 만들 수 있어요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: others.length,
                      itemBuilder: (context, i) {
                        final t = others[i];
                        return ListTile(
                          leading: const Icon(Icons.luggage_outlined,
                              color: AppColors.blue),
                          title: Text(t.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(t.dateRangeLabel),
                          onTap: () => onSelect(t),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('내 여행 관리'),
              subtitle: const Text('만들기 · 수정 · 삭제 · 로그아웃'),
              onTap: onManage,
            ),
          ],
        ),
      ),
    );
  }
}
