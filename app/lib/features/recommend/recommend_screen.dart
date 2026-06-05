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
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  /// 로그인/Trip 생성(다른 기능) 전까지 PoC 고정 여행 식별자.
  static const String _tripId = 'demo-trip';

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
        queryParameters: {'trip_id': _tripId},
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
          'trip_id': _tripId,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 장소 추천')),
      body: Column(
        children: [
          _TimelineBar(items: _timeline),
          Expanded(child: PlaceChat(onAdd: _addToSchedule)),
        ],
      ),
    );
  }
}

/// 상단 타임라인에 표시할 '담은 일정' 1개(서버 polylog-schedules 항목).
class _ScheduleItem {
  final String title;
  final String placeName;
  const _ScheduleItem({required this.title, required this.placeName});

  factory _ScheduleItem.fromJson(Map<String, dynamic> j) {
    final name = (j['place_name'] ?? '').toString();
    return _ScheduleItem(
      title: (j['title'] ?? name).toString(),
      placeName: name,
    );
  }
}

/// 상단 '여행 일정' 타임라인 — 담은 장소가 1 → 2 → 3 순서로 가로로 쌓인다.
class _TimelineBar extends StatelessWidget {
  final List<_ScheduleItem> items;
  const _TimelineBar({required this.items});

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
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.chevron_right,
                          size: 18, color: scheme.onSurfaceVariant),
                    ),
                    itemBuilder: (context, i) => _TimelineChip(
                      index: i + 1,
                      label: items[i].placeName,
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
