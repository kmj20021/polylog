import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../shared/place_chat.dart';

/// 위치 기반 AI 장소 추천 — 대화형 화면 (메인 기능 #1).
///
/// 화면 구성:
///   - 상단: 담은 일정 미리보기(가로 칩 타임라인). '담기'를 누를 때마다 칩이 늘어난다.
///   - 본문: 공용 [PlaceChat] 위젯(대화 입력 → /recommend → 장소 카드).
///
/// 대화·GPS·카드 렌더링은 모두 [PlaceChat] 가 담당하고, 이 화면은 '담기 → 일정 저장 +
/// 상단 미리보기 갱신'만 책임진다. (여행 탭의 일정 화면도 같은 [PlaceChat] 를 재사용한다.)
class RecommendScreen extends StatefulWidget {
  /// 어느 여행에 담을지 — '내 여행' 목록에서 선택한 여행이 주입된다.
  final String tripId;
  final String tripName;

  const RecommendScreen(
      {super.key, required this.tripId, required this.tripName});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  /// 상단 타임라인에 쌓이는 '담은 일정'(서버 polylog-schedules 와 동기).
  final List<_ScheduleItem> _timeline = [];

  @override
  void initState() {
    super.initState();
    _loadTimeline();
  }

  /// 서버에서 현재 여행(demo-trip)의 일정을 시간순으로 불러와 상단 타임라인을 채운다.
  Future<void> _loadTimeline() async {
    try {
      final res = await DioClient().get<Map<String, dynamic>>(
        '/schedule',
        queryParameters: {'trip_id': widget.tripId},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _timeline
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => _ScheduleItem.fromJson(e.cast<String, dynamic>())));
      });
    } catch (_) {
      // 타임라인 로드 실패는 조용히 무시(추천 흐름을 막지 않음).
    }
  }

  /// 추천 카드의 '담기' → 서버에 저장 후 상단 타임라인 갱신. 성공하면 true.
  Future<bool> _addToSchedule(Place p) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'trip_id': widget.tripId,
          'place_id': p.placeId,
          'place_name': p.name,
          if (p.lat != null) 'latitude': p.lat,
          if (p.lng != null) 'longitude': p.lng,
          if (p.address.isNotEmpty) 'address': p.address,
          if (p.rating != null) 'rating': p.rating,
        },
      );
      await _loadTimeline();
      if (!mounted) return true;
      messenger.showSnackBar(
        SnackBar(content: Text('일정에 "${p.name}" 추가됨')),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      messenger.showSnackBar(
        SnackBar(content: Text('추가 실패: $e')),
      );
      return false;
    }
  }

  /// 칩을 드래그해 순서를 바꿨을 때: ① 화면에서 먼저 옮겨 즉시 반응시키고
  /// ② 서버에 '새 순서'(start_time 목록)를 보내 영구 반영, ③ 서버가 다시 매긴
  /// start_time 으로 동기화한다. 실패하면 서버 상태로 되돌려 어긋남을 막는다.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    // onReorderItem 은 newIndex 를 이미 보정해 준다(예전 onReorder 처럼 직접 -1 안 해도 됨).
    if (oldIndex == newIndex) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      final moved = _timeline.removeAt(oldIndex);
      _timeline.insert(newIndex, moved);
    });

    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'action': 'reorder',
          'trip_id': widget.tripId,
          'order': _timeline.map((e) => e.startTime).toList(),
        },
      );
      await _loadTimeline(); // 서버가 재부여한 start_time 으로 맞춘다.
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('순서 변경 실패: $e')));
      _loadTimeline(); // 서버 상태로 되돌림.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.tripName)),
      body: Column(
        children: [
          _TimelineBar(items: _timeline, onReorder: _reorder),
          Expanded(child: PlaceChat(onAdd: _addToSchedule)),
        ],
      ),
    );
  }
}

/// 상단 타임라인에 표시할 '담은 일정' 1개(서버 polylog-schedules 항목).
class _ScheduleItem {
  final String startTime; // SK — 재정렬 시 '이 순서로 바꿔줘'를 서버에 알리는 키
  final String title;
  final String placeName;
  const _ScheduleItem(
      {required this.startTime, required this.title, required this.placeName});

  factory _ScheduleItem.fromJson(Map<String, dynamic> j) {
    final name = (j['place_name'] ?? '').toString();
    return _ScheduleItem(
      startTime: (j['start_time'] ?? '').toString(),
      title: (j['title'] ?? name).toString(),
      placeName: name,
    );
  }
}

/// 상단 '여행 일정' 타임라인 — 담은 장소가 1 → 2 → 3 순서로 가로로 쌓인다.
///
/// 칩을 꾹 눌러(롱프레스) 좌우로 드래그하면 방문 순서를 바꿀 수 있다.
/// 추천에서 '담기'는 일단 맨 뒤에 붙으므로, 원하는 자리로 끌어다 '중간에' 넣는다.
class _TimelineBar extends StatelessWidget {
  final List<_ScheduleItem> items;

  /// 드래그로 순서가 바뀌면 (이전 위치, 새 위치)를 부모에 알린다.
  final void Function(int oldIndex, int newIndex) onReorder;

  const _TimelineBar({required this.items, required this.onReorder});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text('내 여행 일정',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text('(${items.length})',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              if (items.length > 1) ...[
                const Spacer(),
                Icon(Icons.drag_indicator,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Text('꾹 눌러 순서 변경',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: items.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '추천 카드의 "담기"를 누르면 여기에 일정이 쌓여요.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: true, // 모바일: 롱프레스로 칩 전체를 잡아 드래그
                    onReorderItem: onReorder,
                    itemCount: items.length,
                    // 드래그 중 떠 있는 칩 배경이 비치지 않도록 투명 처리.
                    proxyDecorator: (child, index, animation) =>
                        Material(color: Colors.transparent, child: child),
                    itemBuilder: (context, i) => Padding(
                      // ReorderableListView 는 각 항목에 고유 Key 가 필수.
                      key: ValueKey(items[i].startTime),
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: _TimelineChip(
                          index: i + 1,
                          label: items[i].placeName,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TimelineChip extends StatelessWidget {
  final int index;
  final String label;
  const _TimelineChip({required this.index, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: scheme.primary,
            child: Text('$index',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimary)),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
