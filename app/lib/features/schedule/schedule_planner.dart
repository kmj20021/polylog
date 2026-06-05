import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/config/dev_config.dart';
import '../../core/location/geolocator.dart';

/// 여행 탭의 '대화형 일정 플래너' — 추천과 달리 AI가 대화를 기억하고 동선을 제안한다.
///
/// 추천 탭의 [PlaceChat] 과 다른 점(차별화의 핵심):
///   - `POST /schedule {action:"chat"}` 를 호출 → 서버가 이전 대화 + 현재 일정을 함께 본다.
///   - 응답은 단순 장소 목록이 아니라 {reply(말), proposed_plan(방문 순서 동선), timeline, edited}.
///   - "빼줘/순서 바꿔" 같은 편집은 서버가 즉시 반영 → [onScheduleChanged] 로 호스트가
///     위쪽 타임라인을 새로고침한다. 새 장소(proposed_plan)는 '이대로 담기'로 확정.
class SchedulePlanner extends StatefulWidget {
  final String tripId;

  /// 일정이 바뀌었을 때(편집 즉시반영/담기 확정) 호스트가 타임라인을 새로고침하도록.
  final Future<void> Function() onScheduleChanged;

  const SchedulePlanner({
    super.key,
    required this.tripId,
    required this.onScheduleChanged,
  });

  @override
  State<SchedulePlanner> createState() => _SchedulePlannerState();
}

class _SchedulePlannerState extends State<SchedulePlanner> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _location = LocationService();

  bool _loading = false;
  ({double lat, double lng})? _pos;
  bool _gpsTried = false;

  final List<_PlanItem> _items = [];

  @override
  void initState() {
    super.initState();
    _items.add(const _PAi(
      '여기서 대화로 하루 일정을 함께 짜요. 저는 이전 대화와 지금 일정을 기억해요.\n'
      '예) "오후에 3시간, 조용한 곳 위주로 짜줘", "2번 빼줘", "순서 바꿔줘", "아까 카페 말고 다른 곳".',
    ));
    _ensureGps();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ensureGps() async {
    const mock = DevConfig.mockLocation;
    if (mock != null) {
      if (!mounted) return;
      setState(() {
        _gpsTried = true;
        _pos = (lat: mock.lat, lng: mock.lng);
      });
      return;
    }
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

  void _push(_PlanItem item) {
    setState(() => _items.add(item));
    _scrollToEnd();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _loading) return;
    _input.clear();
    _push(_PUser(text));
    setState(() => _loading = true);
    _scrollToEnd();
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'action': 'chat',
          'trip_id': widget.tripId,
          'message': text,
          if (_pos != null) 'lat': _pos!.lat,
          if (_pos != null) 'lng': _pos!.lng,
        },
      );
      final body = res.data ?? const {};
      final reply = (body['reply'] ?? '').toString();
      if (reply.isNotEmpty) _push(_PAi(reply));

      final plan = ((body['proposed_plan'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => _Proposed.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (plan.isNotEmpty) _push(_PProposal(plan));

      // 서버가 일정을 직접 고쳤으면(삭제/순서변경) 위쪽 타임라인을 새로고침.
      if (body['edited'] == true) await widget.onScheduleChanged();
    } on DioException catch (e) {
      final b = e.response?.data;
      final msg = (b is Map && b['error'] != null)
          ? b['error'].toString()
          : (e.message ?? '네트워크 오류');
      _push(_PError('일정 도우미를 부르지 못했어요.\n$msg'));
    } catch (e) {
      _push(_PError('알 수 없는 오류: $e'));
    } finally {
      if (mounted) setState(() => _loading = false);
      _scrollToEnd();
    }
  }

  /// 제안된 장소 하나를 일정에 저장(담기). 성공 시 위 타임라인 새로고침.
  Future<bool> _addOne(_Proposed p) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'trip_id': widget.tripId,
          'place_id': p.placeId,
          'place_name': p.placeName,
          if (p.timeLabel.isNotEmpty) 'time_label': p.timeLabel,
          if (p.lat != null) 'latitude': p.lat,
          if (p.lng != null) 'longitude': p.lng,
          if (p.address.isNotEmpty) 'address': p.address,
          if (p.rating != null) 'rating': p.rating,
        },
      );
      await widget.onScheduleChanged();
      return true;
    } catch (e) {
      if (!mounted) return false;
      messenger.showSnackBar(SnackBar(content: Text('담기 실패: $e')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GpsHint(tried: _gpsTried, hasPos: _pos != null,
            mockLabel: DevConfig.mockLocation?.label),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: _items.length + (_loading ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= _items.length) return const _TypingDots();
              return _PlanItemView(item: _items[i], onAddOne: _addOne);
            },
          ),
        ),
        const Divider(height: 1),
        _InputBar(controller: _input, enabled: !_loading, onSend: _send),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 대화 항목 모델
// ──────────────────────────────────────────────────────────────
sealed class _PlanItem {
  const _PlanItem();
}

class _PUser extends _PlanItem {
  final String text;
  const _PUser(this.text);
}

class _PAi extends _PlanItem {
  final String text;
  const _PAi(this.text);
}

class _PError extends _PlanItem {
  final String text;
  const _PError(this.text);
}

class _PProposal extends _PlanItem {
  final List<_Proposed> places;
  const _PProposal(this.places);
}

/// 제안된 방문지 1곳(서버 proposed_plan 항목).
class _Proposed {
  final String placeId;
  final String placeName;
  final String timeLabel;
  final String reason;
  final double? lat;
  final double? lng;
  final String address;
  final double? rating;

  const _Proposed({
    required this.placeId,
    required this.placeName,
    required this.timeLabel,
    required this.reason,
    required this.lat,
    required this.lng,
    required this.address,
    required this.rating,
  });

  factory _Proposed.fromJson(Map<String, dynamic> j) => _Proposed(
        placeId: (j['place_id'] ?? '').toString(),
        placeName: (j['place_name'] ?? '').toString(),
        timeLabel: (j['time_label'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        lat: (j['latitude'] as num?)?.toDouble(),
        lng: (j['longitude'] as num?)?.toDouble(),
        address: (j['address'] ?? '').toString(),
        rating: (j['rating'] as num?)?.toDouble(),
      );
}

class _PlanItemView extends StatelessWidget {
  final _PlanItem item;
  final Future<bool> Function(_Proposed) onAddOne;
  const _PlanItemView({required this.item, required this.onAddOne});

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      _PUser(:final text) => _Bubble(text: text, fromUser: true),
      _PAi(:final text) => _Bubble(text: text, fromUser: false),
      _PError(:final text) => _ErrorCard(message: text),
      _PProposal(:final places) => _ProposalBlock(places: places, onAddOne: onAddOne),
    };
  }
}

// ──────────────────────────────────────────────────────────────
// 제안 동선 블록 — 카드 목록 + 개별 담기 + '전부 담기'
// ──────────────────────────────────────────────────────────────
class _ProposalBlock extends StatefulWidget {
  final List<_Proposed> places;
  final Future<bool> Function(_Proposed) onAddOne;
  const _ProposalBlock({required this.places, required this.onAddOne});

  @override
  State<_ProposalBlock> createState() => _ProposalBlockState();
}

class _ProposalBlockState extends State<_ProposalBlock> {
  final Set<int> _added = {};
  bool _busy = false;

  Future<void> _addAt(int i) async {
    if (_added.contains(i) || _busy) return;
    setState(() => _busy = true);
    final ok = await widget.onAddOne(widget.places[i]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _added.add(i);
    });
  }

  Future<void> _addAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    for (var i = 0; i < widget.places.length; i++) {
      if (_added.contains(i)) continue;
      final ok = await widget.onAddOne(widget.places[i]);
      if (ok) _added.add(i);
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allAdded = _added.length == widget.places.length;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.route, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text('제안 동선',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < widget.places.length; i++)
              _ProposedCard(
                index: i + 1,
                place: widget.places[i],
                added: _added.contains(i),
                busy: _busy,
                onAdd: () => _addAt(i),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_busy || allAdded) ? null : _addAll,
                icon: Icon(allAdded ? Icons.check_circle : Icons.playlist_add),
                label: Text(allAdded ? '모두 담음' : '이대로 전부 담기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProposedCard extends StatelessWidget {
  final int index;
  final _Proposed place;
  final bool added;
  final bool busy;
  final VoidCallback onAdd;
  const _ProposedCard({
    required this.index,
    required this.place,
    required this.added,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.primary,
            child: Text('$index',
                style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (place.timeLabel.isNotEmpty) ...[
                      Text(place.timeLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(place.placeName,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                if (place.rating != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star, size: 13, color: Colors.amber.shade700),
                      const SizedBox(width: 3),
                      Text(place.rating!.toStringAsFixed(1),
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                if (place.reason.isNotEmpty)
                  Text(place.reason,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          added
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.check_circle, size: 22, color: Colors.green),
                )
              : IconButton(
                  tooltip: '이 곳 담기',
                  onPressed: busy ? null : onAdd,
                  icon: const Icon(Icons.add_circle_outline),
                ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 작은 공용 위젯들(말풍선/입력/배너) — 플래너 전용
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
            maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: fromUser ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text,
            style: TextStyle(
                color: fromUser ? scheme.onPrimary : scheme.onSurface,
                height: 1.4)),
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots();

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
            child: CircularProgressIndicator(strokeWidth: 2)),
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
                    style: TextStyle(color: scheme.onErrorContainer))),
          ],
        ),
      ),
    );
  }
}

class _GpsHint extends StatelessWidget {
  final bool tried;
  final bool hasPos;
  final String? mockLabel;
  const _GpsHint({required this.tried, required this.hasPos, this.mockLabel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = !tried
        ? (Icons.gps_not_fixed, '현재 위치 확인 중…', scheme.onSurfaceVariant)
        : mockLabel != null
            ? (Icons.bug_report, '테스트 위치: $mockLabel', scheme.tertiary)
            : hasPos
                ? (Icons.my_location, '현재 위치 기준으로 동선을 짜요', scheme.primary)
                : (Icons.location_off, '위치 꺼짐 — 메시지에 지역명을 함께 적어 주세요',
                    scheme.error);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color)),
        ],
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
                  hintText: '일정을 말로 짜보세요 (예: 오후에 조용한 곳)',
                  filled: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
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
