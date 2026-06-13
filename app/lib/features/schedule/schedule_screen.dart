import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/bookmark_panel.dart';
import '../../shared/feature_nav.dart';
import '../../shared/maps_link.dart';
import '../trips/trip.dart';
import 'schedule_planner.dart';

/// '여행' 탭 — 담아 둔 일정(polylog-schedules)을 **일자별**로 보여주고 관리한다.
///
/// 추천 화면 상단의 작은 칩 타임라인이 '미리보기'라면, 이 화면은 일정 전체를
/// 한눈에 펼쳐 보고 개별 항목을 지울 수 있는 '본 화면'이다.
///
/// 일자별 계획:
///   - 여행 기간(시작~종료일)으로 날짜 스트립(1일차·2일차…)을 만든다(list_trips 로 기간 조회).
///   - 스트립에서 고른 '그 날'의 일정만 골라 타임라인에 보여주고, 그 날로 새 계획을 담는다.
///   - 항목의 '날짜 바꾸기'(set_day)로 잘못 담긴/날짜 미정 항목을 다른 날로 옮길 수 있다.
///   - 여행 기간이 미정이면 스트립 없이 전체 일정을 한 줄로 보여준다(예전과 동일).
///
/// 데이터 출처(모두 이미 배포된 fn-schedule):
///   - 기간 조회: POST /schedule {action:"list_trips"}    (날짜 스트립 만들기)
///   - 일정 조회: GET  /schedule?trip_id=...
///   - 순서 변경: POST /schedule {action:"reorder", order:[...]}
///   - 날짜 변경: POST /schedule {action:"set_day", start_time, day}
///   - 삭제:     DELETE /schedule {trip_id, start_time}
class ScheduleScreen extends StatefulWidget {
  /// 어느 여행의 일정을 보여줄지 — '내 여행' 목록에서 선택한 여행이 주입된다.
  final String tripId;
  final String tripName;

  /// 처음 보여줄 날짜 'YYYY-MM-DD'(메인 홈에서 보고 있던 날). 빈 값이면 기본 날짜로.
  final String day;

  const ScheduleScreen(
      {super.key, required this.tripId, required this.tripName, this.day = ''});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  bool _loading = true;
  String? _error;
  final List<_Schedule> _items = [];

  // 일자별 계획 상태 ──────────────────────────────────────────────
  List<DateTime> _days = const []; // 여행 기간의 날짜들(비어 있으면 스트립 숨김)
  String _selectedDay = ''; // 지금 보고 있는 날짜 'YYYY-MM-DD'
  bool _otherSelected = false; // '날짜 미정' 묶음을 보고 있는가

  @override
  void initState() {
    super.initState();
    _selectedDay = widget.day; // 날짜 로드 전에도 플래너가 쓸 기본값
    _load();
    _loadDays();
  }

  /// 여행 기간(시작~종료일)을 받아 날짜 스트립을 만든다. 실패하면 스트립 없이 동작.
  Future<void> _loadDays() async {
    if (widget.tripId.isEmpty) return;
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'list_trips'},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      Trip? trip;
      for (final m in raw.whereType<Map>()) {
        final t = Trip.fromJson(m.cast<String, dynamic>());
        if (t.tripId == widget.tripId) {
          trip = t;
          break;
        }
      }
      final days = trip?.days() ?? const <DateTime>[];
      if (days.isEmpty || !mounted) return;
      setState(() {
        _days = days;
        final ymds = days.map(Trip.ymd).toSet();
        final initial =
            widget.day.isNotEmpty ? widget.day : trip!.defaultDayYmd();
        // 처음 날짜가 기간 안이면 그대로, 아니면 첫날부터.
        _selectedDay = ymds.contains(initial) ? initial : Trip.ymd(days.first);
      });
    } catch (_) {
      // 날짜를 못 받아도 전체 일정은 보이므로 조용히 넘어간다.
    }
  }

  /// 서버에서 일정 전체를 시간순으로 불러온다(당겨서 새로고침도 이걸 호출).
  /// 여행이 없으면(tripId 빈 값) 서버가 demo-trip 으로 대체해 엉뚱한 일정을 보여주므로
  /// 부르지 않고 '빈 일정' 상태로 둔다(DynamoDB — Query 생략).
  Future<void> _load() async {
    if (widget.tripId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _items.clear();
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await DioClient().get<Map<String, dynamic>>(
        '/schedule',
        queryParameters: {'trip_id': widget.tripId},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => _Schedule.fromJson(e.cast<String, dynamic>())));
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

  // ── 일자별 보기 도우미 ──────────────────────────────────────────

  /// 지금 화면에 보여줄 일정 — 고른 날짜의 것만(스트립 없으면 전체).
  List<_Schedule> get _visible {
    if (_days.isEmpty) return _items;
    if (_otherSelected) {
      final inRange = _days.map(Trip.ymd).toSet();
      return _items.where((e) => !inRange.contains(e.day)).toList();
    }
    return _items.where((e) => e.day == _selectedDay).toList();
  }

  /// 여행 기간에 안 속하는(또는 날짜 미정) 일정이 있는가 → '날짜 미정' 칩을 띄울지.
  bool get _hasOther {
    if (_days.isEmpty) return false;
    final inRange = _days.map(Trip.ymd).toSet();
    return _items.any((e) => !inRange.contains(e.day));
  }

  /// 플래너가 새 계획을 담을 날짜 — '날짜 미정' 보기면 빈 값.
  String get _plannerDay => _otherSelected ? '' : _selectedDay;

  void _selectDay(String ymd) => setState(() {
        _selectedDay = ymd;
        _otherSelected = false;
      });

  void _selectOther() => setState(() => _otherSelected = true);

  /// 일정 한 개 삭제 — 서버에서 지운 뒤 목록에서도 제거한다.
  /// DynamoDB 항목은 PK(trip_id)+SK(start_time) 한 쌍으로 특정하므로 둘 다 보낸다.
  Future<void> _delete(_Schedule item) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().delete<Map<String, dynamic>>(
        '/schedule',
        data: {'trip_id': widget.tripId, 'start_time': item.startTime},
      );
      if (!mounted) return;
      setState(() => _items.removeWhere((e) => e.startTime == item.startTime));
      messenger.showSnackBar(
        SnackBar(content: Text('"${item.placeName}" 일정에서 삭제됨')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
      _load(); // 서버 상태와 어긋났을 수 있으니 다시 맞춘다.
    }
  }

  /// 항목을 다른 '여행 날짜'로 옮긴다 — 바텀시트로 날짜를 고르고 set_day 호출.
  /// 잘못된 날에 담겼거나 날짜 미정인 일정을 제자리로 보내는 용도.
  Future<void> _changeDay(_Schedule item) async {
    if (_days.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('날짜로 옮기기',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            for (var i = 0; i < _days.length; i++)
              ListTile(
                title: Text('${i + 1}일차  ${_dayShort(Trip.ymd(_days[i]))}'),
                trailing: item.day == Trip.ymd(_days[i])
                    ? Icon(Icons.check, color: scheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, Trip.ymd(_days[i])),
              ),
            ListTile(
              title: const Text('날짜 미정'),
              trailing: item.day.isEmpty
                  ? Icon(Icons.check, color: scheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == item.day || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'action': 'set_day',
          'trip_id': widget.tripId,
          'start_time': item.startTime,
          'day': picked,
        },
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('날짜 변경 실패: $e')));
    }
  }

  /// 펼친 타임라인 위의 '직접 일정 작성하기' 버튼.
  Widget _manualAddButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _addManual,
          icon: const Icon(Icons.add),
          label: const Text('직접 일정 작성하기'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            foregroundColor: AppColors.blue,
            side: const BorderSide(color: AppColors.blue),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }

  /// 추천에 없는 일정을 손으로 직접 넣는다(예: '공항 출발', '호텔 체크인').
  /// 장소가 아닌 메모성 일정이라 place_id 없이 place_name(내용)·time_label(시간)만
  /// 저장한다 — 지금 고른 날짜(_plannerDay)에 붙는다.
  Future<void> _addManual() async {
    final textCtrl = TextEditingController();
    final timeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('직접 일정 작성'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textCtrl,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '일정 내용',
                hintText: '예) 공항 출발',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: timeCtrl,
              decoration: const InputDecoration(
                labelText: '시간(선택)',
                hintText: '예) 09:00',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('추가')),
        ],
      ),
    );
    final name = textCtrl.text.trim();
    final time = timeCtrl.text.trim();
    textCtrl.dispose();
    timeCtrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'trip_id': widget.tripId,
          'place_name': name,
          if (_plannerDay.isNotEmpty) 'day': _plannerDay,
          if (time.isNotEmpty) 'time_label': time,
        },
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('일정 추가 실패: $e')));
    }
  }

  /// 손잡이를 끌어 순서를 바꿨을 때 — '보이는 날짜' 안에서의 이동을 전체 목록에 반영한다.
  /// 화면엔 그 날 것만 보이므로 oldIndex/newIndex 는 '보이는 목록' 기준이다. 그걸
  /// 전체 목록의 같은 자리에 끼워 넣어 다른 날 항목 순서는 건드리지 않는다.
  /// 이후 서버에 '전체 새 순서'(start_time 목록)를 보내 start_time 을 다시 매긴다.
  /// (백엔드는 fn-schedule 의 POST {action:"reorder"} 가 처리 — 이미 배포됨.)
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final messenger = ScaffoldMessenger.of(context);
    final visible = _visible;
    // 보이는 목록 안에서 자리 이동(onReorderItem 이 newIndex 를 이미 보정해 준다).
    final newVisible = [...visible];
    final moved = newVisible.removeAt(oldIndex);
    newVisible.insert(newIndex, moved);
    // 전체 목록을 다시 짠다: 보이는 자리에는 새 순서를, 나머지는 원래대로.
    final visibleKeys = visible.map((e) => e.startTime).toSet();
    final it = newVisible.iterator;
    final rebuilt = <_Schedule>[];
    for (final s in _items) {
      if (visibleKeys.contains(s.startTime)) {
        it.moveNext();
        rebuilt.add(it.current);
      } else {
        rebuilt.add(s);
      }
    }
    setState(() {
      _items
        ..clear()
        ..addAll(rebuilt);
    });
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'action': 'reorder',
          'trip_id': widget.tripId,
          'order': _items.map((e) => e.startTime).toList(),
        },
      );
      await _load(); // 서버가 재부여한 start_time 으로 맞춘다.
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('순서 변경 실패: $e')));
      _load(); // 서버 상태로 되돌림.
    }
  }

  /// 삭제 전 확인 다이얼로그(실수로 지우는 것 방지).
  Future<bool> _confirmDelete(_Schedule item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('일정 삭제'),
        content: Text('"${item.placeName}"을(를) 일정에서 뺄까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 레퍼런스(docs/ref-image/chat.jpg) 구조:
  ///   - 블루 배경 + 상단 바(뒤로가기 / 로고 아바타) + 날짜 스트립(일자별).
  ///   - 상단 '끌어내리는' 일정 패널 — 평소엔 접혀 마지막 일정 1개만, 손잡이를
  ///     아래로 슬라이드(또는 탭)하면 펼쳐져 그 날 일정을 본다(_SchedulePanel).
  ///   - 그 아래 큰 흰 패널 = AI 대화 플래너(+ 하단 입력창).
  @override
  Widget build(BuildContext context) {
    final hasStrip = _days.isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const topBarH = 56.0;
            final stripH = hasStrip ? 64.0 : 0.0;
            const collapsedH = 112.0;
            final expandedH =
                ((constraints.maxHeight - topBarH - stripH) * 0.72)
                    .clamp(220.0, 600.0);
            return Stack(
              children: [
                // 바닥: 상단 바 + 날짜 스트립 + (접힌 일정 패널 자리) + 큰 흰 플래너 패널.
                Column(
                  children: [
                    BookmarkTopBar(
                      title: widget.tripName,
                      onBack: () => Navigator.of(context).maybePop(),
                      onLogoTap: () => showFeatureNavMenu(
                        context,
                        tripId: widget.tripId,
                        tripName: widget.tripName,
                        day: _plannerDay,
                        current: FeatureDest.plan,
                      ),
                    ),
                    if (hasStrip) _dayStrip(),
                    const SizedBox(height: collapsedH + 16), // 접힌 패널 + 여백
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: const BoxDecoration(
                          color: AppColors.base,
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            // 추천에 없는 일정(예: '공항 출발')을 손으로 직접 넣는다.
                            // 대화 플래너 위에 항상 보이게 둬서 쉽게 찾도록 한다.
                            if (widget.tripId.isNotEmpty) _manualAddButton(),
                            Expanded(
                              child: SchedulePlanner(
                                tripId: widget.tripId,
                                day: _plannerDay, // 담을 때 '고른 날짜'로 저장
                                onScheduleChanged:
                                    _load, // 담기/편집 후 타임라인 새로고침
                                // 여행이 없을 때 '이대로 여행 만들기'로 새 여행이 생기면
                                // 이 화면을 닫으며 새 여행을 돌려준다 → 홈(MainShell)이
                                // 현재 여행으로 삼는다.
                                onTripCreated: (trip) =>
                                    Navigator.of(context).pop(trip),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // 상단 일정 패널(접힘↔펼침) — 펼치면 플래너 위로 내려와 덮는다.
                Positioned(
                  top: topBarH + stripH,
                  left: 16,
                  right: 16,
                  child: BookmarkPanel(
                    collapsedHeight: collapsedH,
                    expandedHeight: expandedH,
                    collapsedChild: _collapsedView(),
                    expandedChild: RefreshIndicator(
                      onRefresh: _load,
                      child: _buildBody(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 날짜 스트립 — 여행 기간의 날짜를 가로 칩으로. 고른 날만 타임라인에 보인다.
  Widget _dayStrip() {
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          for (var i = 0; i < _days.length; i++) _dayChip(i),
          if (_hasOther) _otherChip(),
        ],
      ),
    );
  }

  Widget _dayChip(int i) {
    final ymd = Trip.ymd(_days[i]);
    final sel = !_otherSelected && _selectedDay == ymd;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: sel,
        onSelected: (_) => _selectDay(ymd),
        showCheckmark: false,
        side: BorderSide.none,
        selectedColor: AppColors.base,
        backgroundColor: AppColors.base.withValues(alpha: 0.85),
        label: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${i + 1}일차',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    color: sel ? AppColors.blue : Colors.grey.shade700,
                    fontWeight: FontWeight.w600)),
            Text(_dayShort(ymd),
                style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: sel ? AppColors.blue : Colors.grey.shade700,
                    fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Widget _otherChip() {
    final sel = _otherSelected;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: sel,
        onSelected: (_) => _selectOther(),
        showCheckmark: false,
        side: BorderSide.none,
        selectedColor: AppColors.base,
        backgroundColor: AppColors.base.withValues(alpha: 0.85),
        label: Text('날짜 미정',
            style: TextStyle(
                color: sel ? AppColors.blue : Colors.grey.shade700,
                fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  /// 접힘 상태에 보이는 '마지막 일정 1개' 요약(없으면 안내, 로딩 중이면 스피너).
  Widget _collapsedView() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_loading && _items.isEmpty) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      final msg = _error != null
          ? '일정을 불러오지 못했어요'
          : _days.isEmpty
              ? '아직 담은 일정이 없어요'
              : '이 날 담은 일정이 없어요';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final last = visible.last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primary,
            child: Text('${visible.length}',
                style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(last.placeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text('마지막 일정 · 총 ${visible.length}개 — 아래로 끌어 전체 보기',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return _MessageView(
        icon: Icons.cloud_off,
        title: '일정을 불러오지 못했어요',
        detail: _error!,
        onRetry: _load,
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return _MessageView(
        icon: Icons.event_available_outlined,
        title: _days.isEmpty ? '아직 담은 일정이 없어요' : '이 날 담은 일정이 없어요',
        detail: _days.isEmpty
            ? '"추천" 탭에서 마음에 드는 장소의 "담기"를 누르면\n여기에 순서대로 쌓입니다.'
            : '아래 대화로 이 날의 일정을 짜고 "담기"를 누르면\n여기에 순서대로 쌓입니다.',
      );
    }
    // 세로 타임라인을 드래그로 재정렬. 밀어서 삭제(Dismissible)와 제스처가 겹치지
    // 않도록 기본 드래그는 끄고(buildDefaultDragHandles:false), 오른쪽 '손잡이'에서만
    // 끌 수 있게 한다(_ScheduleTile 안의 ReorderableDragStartListener).
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: visible.length,
      onReorderItem: _reorder,
      buildDefaultDragHandles: false,
      itemBuilder: (context, i) => _ScheduleTile(
        key: ValueKey(visible[i].startTime),
        index: i + 1,
        listIndex: i,
        item: visible[i],
        isLast: i == visible.length - 1,
        showDay: _days.isNotEmpty,
        confirmDelete: () => _confirmDelete(visible[i]),
        onDelete: () => _delete(visible[i]),
        onChangeDay: () => _changeDay(visible[i]),
      ),
    );
  }

  /// 'YYYY-MM-DD' → 'MM.DD'(간결 표시). 형식이 다르면 원문 그대로.
  static String _dayShort(String ymd) {
    final p = ymd.split('-');
    return p.length == 3 ? '${p[1]}.${p[2]}' : ymd;
  }
}

/// 일정 항목 1개 — polylog-schedules 한 행.
class _Schedule {
  final String startTime; // SK — 삭제 시 항목을 특정하는 키
  final String placeId;   // 구글 장소 식별자 — 지도에서 '정확한 그 장소'를 여는 데 쓴다
  final String title;
  final String placeName;
  final String address;
  final double? rating;
  final String day;       // 어느 여행 날짜의 계획인지 'YYYY-MM-DD'(없으면 미정)
  final String timeLabel; // 시각대(예: 09:00) — 직접 작성/AI 제안에서 옴(없으면 미표시)

  const _Schedule({
    required this.startTime,
    required this.placeId,
    required this.title,
    required this.placeName,
    required this.address,
    required this.rating,
    required this.day,
    required this.timeLabel,
  });

  factory _Schedule.fromJson(Map<String, dynamic> j) {
    final name = (j['place_name'] ?? '').toString();
    return _Schedule(
      startTime: (j['start_time'] ?? '').toString(),
      placeId: (j['place_id'] ?? '').toString(),
      title: (j['title'] ?? name).toString(),
      placeName: name,
      address: (j['address'] ?? '').toString(),
      rating: (j['rating'] as num?)?.toDouble(),
      day: (j['day'] ?? '').toString(),
      timeLabel: (j['time_label'] ?? '').toString(),
    );
  }
}

/// 세로 타임라인의 한 줄: 왼쪽 순번 점 + 연결선, 오른쪽 장소 카드.
/// 스와이프(밀기)로 삭제할 수 있다(Dismissible). 우상단 날짜 칩으로 다른 날로 옮긴다.
class _ScheduleTile extends StatelessWidget {
  final int index;        // 화면에 보이는 순번(1-based)
  final int listIndex;    // 드래그 재정렬용 리스트 위치(0-based)
  final _Schedule item;
  final bool isLast;
  final bool showDay;     // 날짜 칩(다른 날로 옮기기) 표시 여부
  final Future<bool> Function() confirmDelete;
  final VoidCallback onDelete;
  final VoidCallback onChangeDay;

  const _ScheduleTile({
    super.key,
    required this.index,
    required this.listIndex,
    required this.item,
    required this.isLast,
    required this.showDay,
    required this.confirmDelete,
    required this.onDelete,
    required this.onChangeDay,
  });

  /// 장소명을 탭했을 때: 구글 지도에서 해당 장소를 연다(place_id 있으면 정확히,
  /// 없으면 이름검색). 열기에 실패하면 사용자에게 스낵바로 알린다.
  Future<void> _openMaps(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await openPlaceInMaps(
      name: item.placeName,
      placeId: item.placeId,
      address: item.address,
    );
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('지도를 열 수 없어요')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dismissible(
      key: ValueKey(item.startTime),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => confirmDelete(),
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 왼쪽: 순번 점 + 아래로 이어지는 연결선
            Column(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: scheme.primary,
                  child: Text('$index',
                      style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: scheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // 오른쪽: 장소 카드 + 드래그 손잡이
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (item.timeLabel.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(item.timeLabel,
                                    style: theme.textTheme.labelMedium?.copyWith(
                                        color: scheme.primary,
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                            ],
                            // 장소(place_id 있음)면 이름 탭 → 구글 지도에서 그 장소를
                            // 연다(강조색 + 지도 아이콘). 직접 작성한 메모성 일정은
                            // 장소가 아니므로 링크 없이 평범한 텍스트로 둔다.
                            Expanded(
                              child: item.placeId.isEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 2),
                                      child: Text(item.placeName,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                  fontWeight: FontWeight.bold)),
                                    )
                                  : InkWell(
                                      onTap: () => _openMaps(context),
                                      borderRadius: BorderRadius.circular(8),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 2),
                                        child: Row(
                                          children: [
                                            Flexible(
                                              child: Text(item.placeName,
                                                  style: theme
                                                      .textTheme.titleMedium
                                                      ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color:
                                                              scheme.primary)),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(Icons.map_outlined,
                                                size: 16, color: scheme.primary),
                                          ],
                                        ),
                                      ),
                                    ),
                            ),
                            if (showDay) ...[
                              const SizedBox(width: 8),
                              _DayPill(
                                label: item.day.isEmpty
                                    ? '미정'
                                    : _ScheduleScreenState._dayShort(item.day),
                                onTap: onChangeDay,
                              ),
                            ],
                          ],
                        ),
                        if (item.title.isNotEmpty &&
                            item.title != item.placeName) ...[
                          const SizedBox(height: 2),
                          Text(item.title,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                        if (item.rating != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star,
                                  size: 16, color: Colors.amber.shade700),
                              const SizedBox(width: 4),
                              Text(item.rating!.toStringAsFixed(1),
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ],
                        if (item.address.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(item.address,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 오른쪽 끝 드래그 손잡이 — 여기서만 끌어 순서 변경(밀어서 삭제와 충돌 방지).
            ReorderableDragStartListener(
              index: listIndex,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.drag_handle,
                        size: 22, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 일정 카드 우상단의 작은 날짜 칩 — 탭하면 다른 여행 날짜로 옮긴다(set_day).
class _DayPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DayPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

/// 빈 상태·에러 공용 안내 뷰(가운데 아이콘 + 문구 + 선택적 재시도).
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;
  const _MessageView({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // RefreshIndicator 가 동작하려면 항상 스크롤 가능해야 해서 ListView 로 감싼다.
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Icon(icon, size: 64, color: scheme.primary),
        const SizedBox(height: 16),
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
            child: FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ),
        ],
      ],
    );
  }
}
