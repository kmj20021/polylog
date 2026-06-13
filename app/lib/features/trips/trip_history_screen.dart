import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import 'trip.dart';

/// '내 여행 관리' — 완료(종료)한 여행들의 기록을 돌아보는 화면.
///
/// 계정 관리에서 들어온다. 끝난 여행만 모아 보여주고(진행 중·미래·날짜 미정은 제외),
/// 한 여행을 누르면 그 여행의 기록 상세([_TripRecordScreen])로 들어간다.
///
/// 데이터 출처(읽기 전용 — 새 API 없이 기존 라우트 재사용):
///   - 여행 목록:   POST /schedule {action:"list_trips"}
///   - (상세) 방문지: GET  /schedule?trip_id=...        (타임라인 place_name)
///   - (상세) 비용:   POST /receipt {action:"list", trip_id}  (total_krw·occurred_at)
///
/// 디자인은 다른 기능 화면과 통일한다 — 메인 컬러(AppColors.blue) 배경 위 흰색 라운드
/// 시트. 아이콘은 쓰지 않는다(텍스트만으로 구성).
class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  bool _loading = true;
  String? _error;
  List<Trip> _completed = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 여행 목록을 불러와 '완료한 여행'만 추려 최근(종료일) 순으로 정렬한다.
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
      final all = raw
          .whereType<Map>()
          .map((e) => Trip.fromJson(e.cast<String, dynamic>()))
          .toList();
      // '이미 지난' 여행만(=완료). 최근 끝난 여행이 위로 오게 종료일 내림차순.
      final done = all.where((t) => !t.hasNotPassed()).toList()
        ..sort((a, b) => _endKey(b).compareTo(_endKey(a)));
      if (!mounted) return;
      setState(() {
        _completed = done;
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

  /// 정렬용 키 — 종료일(없으면 시작일). 빈 값은 가장 과거로 취급.
  static String _endKey(Trip t) =>
      t.endDate.isNotEmpty ? t.endDate : t.startDate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(title: '내 여행 관리', onBack: () => Navigator.maybePop(context)),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  color: AppColors.base,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                clipBehavior: Clip.antiAlias,
                child: _body(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _Centered(
        title: '여행을 불러오지 못했어요',
        detail: _error!,
        onRetry: _load,
      );
    }
    if (_completed.isEmpty) {
      return const _Centered(
        title: '완료한 여행이 없어요',
        detail: '여행 기간이 지나면 여기에서 방문한 곳과\n사용한 비용을 돌아볼 수 있어요.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 24 + MediaQuery.of(context).padding.bottom),
        itemCount: _completed.length,
        itemBuilder: (context, i) => _TripRow(
          trip: _completed[i],
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _TripRecordScreen(trip: _completed[i]),
          )),
        ),
      ),
    );
  }
}

/// 완료 여행 목록의 한 줄 — 이름 + 기간(누르면 기록 상세로).
class _TripRow extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;
  const _TripRow({required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: onTap,
        title: Text(trip.name,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(trip.dateRangeLabel,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// 기록 상세 — 한 여행의 방문했던 곳 / 총 사용 비용 / 일별 사용 비용
// ──────────────────────────────────────────────────────────────────────────
class _TripRecordScreen extends StatefulWidget {
  final Trip trip;
  const _TripRecordScreen({required this.trip});

  @override
  State<_TripRecordScreen> createState() => _TripRecordScreenState();
}

class _TripRecordScreenState extends State<_TripRecordScreen> {
  bool _loading = true;
  String? _error;

  // 방문했던 곳 — day(YYYY-MM-DD, 없으면 '') → 장소명 목록(방문 순서).
  final Map<String, List<String>> _placesByDay = {};
  // 일별 사용 비용 — day(YYYY-MM-DD) → 원화 합계.
  final Map<String, int> _costByDay = {};
  int _totalCost = 0; // 총 사용 비용(원화)
  bool _hasMissingCost = false; // 환산 안 된 영수증이 섞였는지

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 타임라인(방문지)과 영수증(비용)을 함께 불러와 집계한다.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = widget.trip.tripId;
      final results = await Future.wait([
        DioClient().get<Map<String, dynamic>>(
          '/schedule',
          queryParameters: {'trip_id': id},
        ),
        DioClient().post<Map<String, dynamic>>(
          '/receipt',
          data: {'action': 'list', 'trip_id': id},
        ),
      ]);
      _collectPlaces((results[0].data?['items'] as List?) ?? const []);
      _collectCosts((results[1].data?['receipts'] as List?) ?? const []);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 타임라인 항목 → 날짜별 방문 장소명 묶음(빈 이름은 건너뜀).
  void _collectPlaces(List raw) {
    _placesByDay.clear();
    for (final e in raw.whereType<Map>()) {
      final m = e.cast<String, dynamic>();
      final name = (m['place_name'] ?? m['title'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final day = (m['day'] ?? '').toString().trim();
      _placesByDay.putIfAbsent(day, () => []).add(name);
    }
  }

  /// 영수증 → 총합 + 날짜별 합계(원화 환산 안 된 건은 빼고 표시만 알림).
  void _collectCosts(List raw) {
    _costByDay.clear();
    _totalCost = 0;
    _hasMissingCost = false;
    for (final e in raw.whereType<Map>()) {
      final m = e.cast<String, dynamic>();
      final krw = (m['total_krw'] as num?)?.toInt();
      if (krw == null) {
        _hasMissingCost = true;
        continue;
      }
      _totalCost += krw;
      final day = (m['occurred_at'] ?? '').toString().trim();
      _costByDay[day] = (_costByDay[day] ?? 0) + krw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
                title: widget.trip.name,
                onBack: () => Navigator.maybePop(context)),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  color: AppColors.base,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                clipBehavior: Clip.antiAlias,
                child: _body(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _Centered(
          title: '기록을 불러오지 못했어요', detail: _error!, onRetry: _load);
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 32 + MediaQuery.of(context).padding.bottom),
        children: [
          Text(widget.trip.dateRangeLabel,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          _totalCard(),
          const SizedBox(height: 24),
          _section('일별 사용한 비용'),
          const SizedBox(height: 8),
          _dailyCosts(),
          const SizedBox(height: 24),
          _section('방문했던 곳'),
          const SizedBox(height: 8),
          _visitedPlaces(),
        ],
      ),
    );
  }

  /// 총 사용 비용 카드 — 메인 컬러로 강조.
  Widget _totalCard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('총 사용 비용',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 4),
            Text('₩ ${_comma(_totalCost)}',
                style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: AppColors.blue)),
            if (_hasMissingCost)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('* 원화로 환산되지 않은 영수증은 합계에서 빠졌어요.',
                    style: TextStyle(color: scheme.error, fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(String text) => Text(text,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.bold));

  /// 일별 사용 비용 — 날짜 오름차순, 막대로 상대 비교.
  Widget _dailyCosts() {
    final scheme = Theme.of(context).colorScheme;
    if (_costByDay.isEmpty) {
      return Text('기록된 지출이 없어요.',
          style: TextStyle(color: scheme.onSurfaceVariant));
    }
    final days = _costByDay.keys.toList()..sort();
    final maxCost =
        _costByDay.values.fold<int>(0, (m, v) => v > m ? v : m);
    return Column(
      children: [
        for (final d in days)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(_dayLabel(d),
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 13)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: maxCost == 0 ? 0 : _costByDay[d]! / maxCost,
                      minHeight: 8,
                      backgroundColor: AppColors.blue.withValues(alpha: 0.12),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(AppColors.blue),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('₩ ${_comma(_costByDay[d]!)}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
      ],
    );
  }

  /// 방문했던 곳 — 날짜별로 묶어 방문 순서대로.
  Widget _visitedPlaces() {
    final scheme = Theme.of(context).colorScheme;
    if (_placesByDay.isEmpty) {
      return Text('기록된 방문 장소가 없어요.',
          style: TextStyle(color: scheme.onSurfaceVariant));
    }
    // 날짜 있는 날 먼저(오름차순), '날짜 미정'('')은 맨 뒤로.
    final days = _placesByDay.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.compareTo(b);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in days) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text(d.isEmpty ? '날짜 미정' : _dayLabel(d),
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          for (final name in _placesByDay[d]!)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 2),
              child: Text(name, style: const TextStyle(fontSize: 15)),
            ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// 'YYYY-MM-DD' → 'MM.DD' (간결 표시). 형식이 다르면 원문 그대로.
  static String _dayLabel(String ymd) {
    final parts = ymd.split('-');
    if (parts.length == 3) return '${parts[1]}.${parts[2]}';
    return ymd;
  }
}

// ──────────────────────────────────────────────────────────────────────────
// 공용 위젯
// ──────────────────────────────────────────────────────────────────────────

/// 메인 컬러 위 흰 글씨 상단 바 — 아이콘 없이 텍스트 '뒤로' 버튼만.
class _TopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _TopBar({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            TextButton(
              onPressed: onBack,
              style: TextButton.styleFrom(foregroundColor: AppColors.base),
              child: const Text('<',
                  style:
                      TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.base,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
            ),
            // '뒤로' 버튼과 좌우 균형을 맞추기 위한 빈 자리.
            const SizedBox(width: 64),
          ],
        ),
      ),
    );
  }
}

/// 빈 상태·에러 공용 안내(스크롤 가능 — RefreshIndicator 와 함께 쓰기 위함).
class _Centered extends StatelessWidget {
  final String title;
  final String detail;
  final VoidCallback? onRetry;
  const _Centered({required this.title, required this.detail, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.14),
        Center(
          child: Text(title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          Center(
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.blue,
                  foregroundColor: AppColors.base),
              onPressed: onRetry,
              child: const Text('다시 시도'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 정수 천 단위 콤마 — 92281 → "92,281".
String _comma(int n) {
  final neg = n < 0;
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return (neg ? '-' : '') + buf.toString();
}
