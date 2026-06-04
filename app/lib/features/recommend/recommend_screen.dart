import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/location/geolocator.dart';

/// 위치 기반 AI 장소 추천 — 대화형 화면 (메인 기능 #1).
///
/// 흐름(사용자 시나리오):
///   1) 상단에서 "장소 추천 / 일정 변경" 중 선택(일정 변경은 메인 #2, 준비 중).
///   2) 자연어로 입력 → 서버가 카테고리를 추출. GPS 좌표가 있으면 {lat,lng,query},
///      없으면 {location, query} 로 보낸다.
///   3) 서버 응답 type 으로 분기:
///        - "clarify": 카테고리가 모호 → 되묻는 말풍선 + 카테고리 칩(탭하면 재요청).
///        - "result" : 전체 요약 말풍선 + 장소 카드(별점·거리·리뷰 요약 좋은점/아쉬운점).
///
/// 대화는 위에서 아래로 쌓이는 말풍선/카드 목록(_items)으로 표현한다.
class RecommendScreen extends StatefulWidget {
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

enum _Mode { recommend, schedule }

class _RecommendScreenState extends State<RecommendScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _location = LocationService();

  _Mode _mode = _Mode.recommend;

  bool _loading = false;
  ({double lat, double lng})? _pos; // null = 위치 미확보(텍스트 폴백)
  bool _gpsTried = false;
  String _lastUserText = '';

  /// 로그인/Trip 생성(다른 기능) 전까지 PoC 고정 여행 식별자.
  static const String _tripId = 'demo-trip';

  /// 대화 항목들(위→아래). _ChatItem 의 서브타입으로 분기 렌더.
  final List<_ChatItem> _items = [];

  /// 상단 타임라인에 쌓이는 '담은 일정'(서버 polylog-schedules 와 동기).
  final List<_ScheduleItem> _timeline = [];

  @override
  void initState() {
    super.initState();
    _items.add(const _AiText(
      '안녕하세요! 지금 계신 곳 주변을 찾아드릴게요. '
      '예: "근처 괜찮은 레스토랑 있어?", "조용한 카페 추천해줘"',
    ));
    _ensureGps();
    _loadTimeline();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 화면 진입 시 GPS 좌표를 한 번 확보(거부/실패해도 텍스트 폴백으로 계속 진행).
  Future<void> _ensureGps() async {
    final p = await _location.getCurrentPosition();
    if (!mounted) return;
    setState(() {
      _gpsTried = true;
      _pos = (p == null) ? null : (lat: p.latitude, lng: p.longitude);
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 자연어 전송 — 입력창의 글을 query 로 보낸다.
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _loading) return;
    _input.clear();
    _lastUserText = text;
    _push(_UserMsg(text));
    await _request({'query': text}, fallbackLocation: text);
  }

  /// 카테고리 칩 탭(clarify 응답에 답함) — 카테고리를 직접 지정해 재요청.
  Future<void> _pickCategory(String category) async {
    if (_loading) return;
    _push(_UserMsg(category));
    await _request({'category': category}, fallbackLocation: _lastUserText);
  }

  /// 공통 요청 — GPS 유무로 좌표/텍스트 입력을 구성하고, 응답 type 으로 분기.
  Future<void> _request(
    Map<String, dynamic> intent, {
    required String fallbackLocation,
  }) async {
    setState(() => _loading = true);
    _scrollToEnd();
    try {
      final data = <String, dynamic>{...intent};
      if (_pos != null) {
        data['lat'] = _pos!.lat;
        data['lng'] = _pos!.lng;
      } else {
        // 위치를 못 잡았으면 입력 텍스트를 검색 지역으로 사용(텍스트 폴백).
        data['location'] = fallbackLocation;
      }

      final res = await DioClient().post<Map<String, dynamic>>(
        '/recommend',
        data: data,
      );
      final body = res.data ?? const {};
      final type = (body['type'] ?? 'result').toString();

      if (type == 'clarify') {
        _push(_AiClarify(
          message: (body['message'] ?? '어떤 곳을 찾아드릴까요?').toString(),
          suggestions: ((body['suggestions'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(),
        ));
      } else {
        final rawPlaces = (body['places'] as List?) ?? const [];
        _push(_AiResult(
          summary: (body['ai_summary'] ?? '').toString(),
          places: rawPlaces
              .whereType<Map>()
              .map((e) => _Place.fromJson(e.cast<String, dynamic>()))
              .toList(),
        ));
      }
    } on DioException catch (e) {
      final b = e.response?.data;
      final msg = (b is Map && b['error'] != null)
          ? b['error'].toString()
          : (e.message ?? '네트워크 오류');
      _push(_AiError('추천을 불러오지 못했어요.\n$msg'));
    } catch (e) {
      _push(_AiError('알 수 없는 오류: $e'));
    } finally {
      if (mounted) setState(() => _loading = false);
      _scrollToEnd();
    }
  }

  void _push(_ChatItem item) {
    setState(() => _items.add(item));
    _scrollToEnd();
  }

  void _onModeChanged(_Mode m) {
    if (m == _Mode.schedule) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('일정 대화형 수정은 준비 중이에요 (다음 단계).')),
      );
      return; // 추천 모드 유지
    }
    setState(() => _mode = m);
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

  /// 추천 카드의 '일정에 추가' → 서버에 저장 후 상단 타임라인을 갱신한다.
  Future<void> _addToSchedule(_Place p) async {
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
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('일정에 "${p.name}" 추가됨')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('추가 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 장소 추천')),
      body: Column(
        children: [
          _TimelineBar(items: _timeline),
          _ModeBar(mode: _mode, onChanged: _onModeChanged),
          _GpsBanner(tried: _gpsTried, hasPos: _pos != null),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _items.length + (_loading ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _items.length) return const _TypingBubble();
                return _ChatItemView(
                  item: _items[i],
                  onPickCategory: _pickCategory,
                  onAddToSchedule: _addToSchedule,
                );
              },
            ),
          ),
          const Divider(height: 1),
          _InputBar(
            controller: _input,
            enabled: !_loading,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 대화 항목 모델 — 서브타입으로 분기 렌더
// ──────────────────────────────────────────────────────────────
sealed class _ChatItem {
  const _ChatItem();
}

class _UserMsg extends _ChatItem {
  final String text;
  const _UserMsg(this.text);
}

class _AiText extends _ChatItem {
  final String text;
  const _AiText(this.text);
}

class _AiError extends _ChatItem {
  final String text;
  const _AiError(this.text);
}

class _AiClarify extends _ChatItem {
  final String message;
  final List<String> suggestions;
  const _AiClarify({required this.message, required this.suggestions});
}

class _AiResult extends _ChatItem {
  final String summary;
  final List<_Place> places;
  const _AiResult({required this.summary, required this.places});
}

class _ChatItemView extends StatelessWidget {
  final _ChatItem item;
  final ValueChanged<String> onPickCategory;
  final Future<void> Function(_Place) onAddToSchedule;
  const _ChatItemView({
    required this.item,
    required this.onPickCategory,
    required this.onAddToSchedule,
  });

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      _UserMsg(:final text) => _Bubble(text: text, fromUser: true),
      _AiText(:final text) => _Bubble(text: text, fromUser: false),
      _AiError(:final text) => _ErrorCard(message: text),
      _AiClarify(:final message, :final suggestions) => _ClarifyCard(
          message: message,
          suggestions: suggestions,
          onPick: onPickCategory,
        ),
      _AiResult(:final summary, :final places) => _ResultBlock(
          summary: summary,
          places: places,
          onAdd: onAddToSchedule,
        ),
    };
  }
}

/// 응답 places[] 항목 1개의 표시용 모델.
class _Place {
  final String placeId;
  final String name;
  final double? rating;
  final int userRatings;
  final int? distanceM;
  final String address;
  final bool? openNow;
  final double? lat;
  final double? lng;
  final String reviewGood;
  final String reviewBad;
  final int reviewsUsed;

  const _Place({
    required this.placeId,
    required this.name,
    required this.rating,
    required this.userRatings,
    required this.distanceM,
    required this.address,
    required this.openNow,
    required this.lat,
    required this.lng,
    required this.reviewGood,
    required this.reviewBad,
    required this.reviewsUsed,
  });

  factory _Place.fromJson(Map<String, dynamic> j) {
    final loc = (j['location'] as Map?)?.cast<String, dynamic>() ?? const {};
    return _Place(
      placeId: (j['place_id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      rating: (j['rating'] as num?)?.toDouble(),
      userRatings: (j['user_ratings'] as num?)?.toInt() ?? 0,
      distanceM: (j['distance_m'] as num?)?.toInt(),
      address: (j['address'] ?? '').toString(),
      openNow: j['open_now'] as bool?,
      lat: (loc['lat'] as num?)?.toDouble(),
      lng: (loc['lng'] as num?)?.toDouble(),
      reviewGood: (j['review_good'] ?? '').toString(),
      reviewBad: (j['review_bad'] ?? '').toString(),
      reviewsUsed: (j['reviews_used'] as num?)?.toInt() ?? 0,
    );
  }

  /// 거리 표기: 1km 미만은 m, 이상은 km(소수 1자리).
  String? get distanceLabel {
    if (distanceM == null) return null;
    if (distanceM! < 1000) return '${distanceM}m';
    return '${(distanceM! / 1000).toStringAsFixed(1)}km';
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

// ──────────────────────────────────────────────────────────────
// 상단 바: 모드 선택 + GPS 상태
// ──────────────────────────────────────────────────────────────
class _ModeBar extends StatelessWidget {
  final _Mode mode;
  final ValueChanged<_Mode> onChanged;
  const _ModeBar({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: SegmentedButton<_Mode>(
        segments: const [
          ButtonSegment(
            value: _Mode.recommend,
            icon: Icon(Icons.place_outlined),
            label: Text('장소 추천'),
          ),
          ButtonSegment(
            value: _Mode.schedule,
            icon: Icon(Icons.event_note_outlined),
            label: Text('일정 변경'),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _GpsBanner extends StatelessWidget {
  final bool tried;
  final bool hasPos;
  const _GpsBanner({required this.tried, required this.hasPos});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = !tried
        ? (Icons.gps_not_fixed, '현재 위치 확인 중…', scheme.onSurfaceVariant)
        : hasPos
            ? (Icons.my_location, '현재 위치 기준으로 찾아요', scheme.primary)
            : (Icons.location_off, '위치 꺼짐 — 메시지에 지역명을 함께 적어 주세요',
                scheme.error);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: color)),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 말풍선 / 카드들
// ──────────────────────────────────────────────────────────────
class _Bubble extends StatelessWidget {
  final String text;
  final bool fromUser;
  const _Bubble({required this.text, required this.fromUser});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: fromUser ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: fromUser ? scheme.onPrimary : scheme.onSurface,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _ClarifyCard extends StatelessWidget {
  final String message;
  final List<String> suggestions;
  final ValueChanged<String> onPick;
  const _ClarifyCard({
    required this.message,
    required this.suggestions,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Bubble(text: message, fromUser: false),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in suggestions)
                ActionChip(
                  avatar: const Icon(Icons.search, size: 16),
                  label: Text(s),
                  onPressed: () => onPick(s),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultBlock extends StatelessWidget {
  final String summary;
  final List<_Place> places;
  final Future<void> Function(_Place) onAdd;
  const _ResultBlock({
    required this.summary,
    required this.places,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary.isNotEmpty) _SummaryCard(summary: summary),
        if (places.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('조건에 맞는 장소를 찾지 못했어요.'),
          ),
        for (final p in places) _PlaceCard(place: p, onAdd: onAdd),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String summary;
  const _SummaryCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: color.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(summary,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceCard extends StatefulWidget {
  final _Place place;
  final Future<void> Function(_Place) onAdd;
  const _PlaceCard({required this.place, required this.onAdd});

  @override
  State<_PlaceCard> createState() => _PlaceCardState();
}

class _PlaceCardState extends State<_PlaceCard> {
  bool _added = false;
  bool _adding = false;

  Future<void> _handleAdd() async {
    if (_added || _adding) return;
    setState(() => _adding = true);
    await widget.onAdd(widget.place);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _added = true; // 중복 추가 방지 + '담음' 시각 피드백
    });
  }

  @override
  Widget build(BuildContext context) {
    final place = widget.place;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
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
                Expanded(
                  child: Text(
                    place.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                _AddButton(
                  added: _added,
                  adding: _adding,
                  onPressed: _handleAdd,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (place.rating != null)
                  _MetaChip(
                    icon: Icons.star,
                    iconColor: Colors.amber.shade700,
                    label:
                        '${place.rating!.toStringAsFixed(1)} (${place.userRatings})',
                  ),
                if (place.distanceLabel != null)
                  _MetaChip(
                    icon: Icons.directions_walk,
                    iconColor: scheme.primary,
                    label: place.distanceLabel!,
                  ),
                if (place.openNow != null)
                  _MetaChip(
                    icon: Icons.circle,
                    iconColor: place.openNow! ? Colors.green : scheme.error,
                    label: place.openNow! ? '영업 중' : '영업 종료',
                  ),
              ],
            ),
            if (place.reviewGood.isNotEmpty)
              _ReviewLine(
                icon: Icons.thumb_up_alt_outlined,
                color: Colors.green.shade700,
                label: '좋은 점',
                text: place.reviewGood,
              ),
            if (place.reviewBad.isNotEmpty)
              _ReviewLine(
                icon: Icons.thumb_down_alt_outlined,
                color: scheme.error,
                label: '아쉬운 점',
                text: place.reviewBad,
              ),
            if (place.reviewsUsed > 0) ...[
              const SizedBox(height: 6),
              Text('리뷰 ${place.reviewsUsed}개 기반 요약',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (place.address.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(place.address,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String text;
  const _ReviewLine({
    required this.icon,
    required this.color,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                children: [
                  TextSpan(
                    text: '$label  ',
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: text,
                    style: TextStyle(color: theme.colorScheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  const _MetaChip({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 상단 '여행 일정' 타임라인 — 담은 장소가 1 → 2 → 3 순서로 가로로 쌓인다.
/// 사용자가 "일정에 추가"를 누를 때마다 여기 칩이 늘어나 일정이 만들어지는 모습을 보여준다.
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

/// 추천 카드 우상단의 '일정에 추가' 버튼 — 담기 전/담는 중/담음 3상태.
class _AddButton extends StatelessWidget {
  final bool added;
  final bool adding;
  final VoidCallback onPressed;
  const _AddButton({
    required this.added,
    required this.adding,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (adding) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (added) {
      return TextButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check_circle, size: 18),
        label: const Text('담음'),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: const Icon(Icons.add, size: 18),
      label: const Text('담기'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: '무엇을 찾아드릴까요?',
                  filled: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: enabled ? onSend : null,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
