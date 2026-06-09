import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/bookmark_panel.dart';
import '../../shared/place_chat.dart';

/// 위치 기반 AI 장소 추천 — 대화형 화면 (메인 기능 #1).
///
/// 화면 구성(레퍼런스 chat.jpg '책갈피' 레이아웃):
///   - 상단 책갈피 패널([BookmarkPanel]): 내 여행 일정(접힘=마지막 1곳, 끌어내리면 전체·순서변경).
///   - 큰 흰 패널: 공용 [PlaceChat] 위젯(대화 입력 → /recommend → 장소 카드).
///
/// 대화·GPS·카드 렌더링은 모두 [PlaceChat] 가 담당하고, 이 화면은 '담기 → 일정 저장 +
/// 상단 일정 갱신'만 책임진다. (여행 탭의 일정 화면도 같은 책갈피 패널을 재사용한다.)
class RecommendScreen extends StatefulWidget {
  /// 어느 여행에 담을지 — '내 여행' 목록에서 선택한 여행이 주입된다.
  final String tripId;
  final String tripName;

  /// 담는 장소를 붙일 여행 날짜 'YYYY-MM-DD'(메인 홈에서 보고 있던 날). 빈 값이면 미지정.
  final String day;

  const RecommendScreen(
      {super.key, required this.tripId, required this.tripName, this.day = ''});

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
          if (widget.day.isNotEmpty) 'day': widget.day,
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

  /// 레퍼런스(docs/ref-image/chat.jpg) '책갈피' 레이아웃:
  ///   - 블루 배경 + 상단 바(뒤로 / 로고).
  ///   - 상단 책갈피 패널 = 내 여행 일정(접힘=마지막 1곳, 끌어내리면 전체·순서변경).
  ///   - 큰 흰 패널 = 위치 기반 추천 대화(PlaceChat) + 하단 입력창.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const topBarH = 56.0;
            const collapsedH = 112.0;
            final expandedH =
                ((constraints.maxHeight - topBarH) * 0.72).clamp(220.0, 600.0);
            return Stack(
              children: [
                Column(
                  children: [
                    BookmarkTopBar(
                      title: widget.tripName,
                      onBack: () => Navigator.of(context).maybePop(),
                    ),
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
                        child: PlaceChat(
                          onAdd: _addToSchedule,
                          greeting: '주변에 무엇이 있는지 찾아드려요!\n'
                              '예: "근처 괜찮은 레스토랑 있어?", "조용한 카페 추천해줘"',
                        ),
                      ),
                    ),
                  ],
                ),
                // 상단 책갈피 패널 — 내 여행 일정(펼치면 대화 위로 내려와 덮는다).
                Positioned(
                  top: topBarH,
                  left: 16,
                  right: 16,
                  child: BookmarkPanel(
                    collapsedHeight: collapsedH,
                    expandedHeight: expandedH,
                    collapsedChild: _collapsedItinerary(),
                    expandedChild: _expandedItinerary(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 접힘 상태 — 마지막으로 담은 1곳 요약(없으면 안내).
  Widget _collapsedItinerary() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_timeline.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('아직 담은 일정이 없어요 — 아래에서 찾아 담아보세요',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final last = _timeline.last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primary,
            child: Text('${_timeline.length}',
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
                Text('내 여행 일정 · 총 ${_timeline.length}곳 — 아래로 끌어 전체 보기',
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

  /// 펼침 상태 — 담은 일정 전체(세로 목록, 꾹 눌러 순서 변경).
  Widget _expandedItinerary() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_timeline.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('추천 카드의 "담기"를 누르면 여기에 일정이 쌓여요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              Icon(Icons.route, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text('내 여행 일정',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text('(${_timeline.length})',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              if (_timeline.length > 1) ...[
                const Spacer(),
                Text('꾹 눌러 순서 변경',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: _timeline.length,
            onReorderItem: _reorder,
            proxyDecorator: (child, index, animation) =>
                Material(color: Colors.transparent, child: child),
            itemBuilder: (context, i) => _itineraryTile(i),
          ),
        ),
      ],
    );
  }

  Widget _itineraryTile(int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = _timeline[i];
    return Padding(
      key: ValueKey(item.startTime),
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: scheme.primary,
              child: Text('${i + 1}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: scheme.onPrimary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(item.placeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.drag_handle, size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
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

