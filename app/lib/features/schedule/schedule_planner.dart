import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/config/dev_config.dart';
import '../../core/location/geolocator.dart';
import '../../shared/maps_link.dart';
import '../trips/trip.dart';
import '../trips/trips_screen.dart';

/// 여행 탭의 '대화형 일정 플래너' — 추천과 달리 AI가 대화를 기억하고 동선을 제안한다.
///
/// 추천 탭의 [PlaceChat] 과 다른 점(차별화의 핵심):
///   - `POST /planner` 를 호출(전용 함수 polylog-fn-planner) → 서버가 이전 대화 + 현재 일정을 함께 본다.
///   - 응답은 단순 장소 목록이 아니라 {reply(말), proposed_plan(방문 순서 동선), timeline, edited}.
///   - "빼줘/순서 바꿔" 같은 편집은 서버가 즉시 반영 → [onScheduleChanged] 로 호스트가
///     위쪽 타임라인을 새로고침한다. 새 장소(proposed_plan)는 '이대로 담기'로 확정.
class SchedulePlanner extends StatefulWidget {
  final String tripId;

  /// 담는 계획을 붙일 여행 날짜 'YYYY-MM-DD'(빈 값이면 미지정).
  final String day;

  /// 일정이 바뀌었을 때(편집 즉시반영/담기 확정) 호스트가 타임라인을 새로고침하도록.
  final Future<void> Function() onScheduleChanged;

  /// 여행이 없을 때(tripId 빈 값) '이대로 여행 만들기'로 새 여행이 생기면 호출.
  /// 호스트(ScheduleScreen)가 그 여행을 '현재 여행'으로 삼아 화면을 전환한다.
  final ValueChanged<Trip>? onTripCreated;

  const SchedulePlanner({
    super.key,
    required this.tripId,
    this.day = '',
    required this.onScheduleChanged,
    this.onTripCreated,
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
      '여기서 대화로 하루 일정을 함께 짜요. 가려는 지역과 하고 싶은 걸 말해 주세요.\n'
      '예) "서울 광화문 갔다가 북촌 갈 건데 밥이랑 구경거리 짜줘", '
      '"2번 빼줘", "순서 바꿔줘", "아까 카페 말고 다른 곳".',
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
        // 대화형 플래너는 전용 함수(polylog-fn-planner)로 분리됨 → /planner 호출.
        // (담기 저장은 아래 _addOne 에서 여전히 /schedule = fn-schedule 담당.)
        '/planner',
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
  ///
  /// 여행이 없으면(tripId 빈 값) 담을 곳이 없다. 그냥 저장하면 서버가 빈 trip_id 를
  /// demo-trip 으로 대체해 '보이지 않는 여행'에 쌓이므로(DynamoDB — PutItem),
  /// 저장하지 않고 여행부터 만들도록 안내한다(대화·동선 제안 자체는 계속 가능).
  Future<bool> _addOne(_Proposed p) async {
    final messenger = ScaffoldMessenger.of(context);
    if (widget.tripId.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('담을 여행이 없어요. 먼저 여행을 만들어 주세요(왼쪽 위 메뉴 → 내 여행 관리).')));
      return false;
    }
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'trip_id': widget.tripId,
          'place_id': p.placeId,
          'place_name': p.placeName,
          if (widget.day.isNotEmpty) 'day': widget.day,
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

  /// '이대로 여행 만들기'(여행이 없을 때) — 제안 동선 전체를 한 여행으로 굳힌다.
  ///   ① 여행 이름·기간을 입력받고(기존 '새 여행' 시트 재사용)
  ///   ② 새 여행을 만들고(POST /schedule {action:"create_trip"} → 새 trip_id 발급)
  ///   ③ 제안 장소들을 그 여행에 차례로 담는다(POST /schedule, DynamoDB — PutItem)
  ///   ④ 호스트에 새 여행을 알려 '현재 여행'으로 전환시킨다(onTripCreated).
  /// 성공 시 true(제안 카드가 '모두 담음'으로 잠김).
  Future<bool> _createTripFromPlan(List<_Proposed> places) async {
    final form = await showTripFormSheet(context);
    if (form == null || !mounted) return false;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // ② 새 여행 생성 — 응답의 trip 객체에 새 trip_id 가 들어 있다.
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {
          'action': 'create_trip',
          'name': form.name,
          'start_date': form.startDate,
          'end_date': form.endDate,
        },
      );
      final tripJson = (res.data?['trip'] as Map?)?.cast<String, dynamic>();
      if (tripJson == null) throw Exception('여행 생성 응답이 비어 있어요');
      final trip = Trip.fromJson(tripJson);

      // ③ 제안 장소를 새 여행에 차례로 담는다(시작일이 있으면 첫날로 묶는다).
      for (final p in places) {
        await DioClient().post<Map<String, dynamic>>(
          '/schedule',
          data: {
            'trip_id': trip.tripId,
            'place_id': p.placeId,
            'place_name': p.placeName,
            if (form.startDate.isNotEmpty) 'day': form.startDate,
              if (p.lat != null) 'latitude': p.lat,
            if (p.lng != null) 'longitude': p.lng,
            if (p.address.isNotEmpty) 'address': p.address,
            if (p.rating != null) 'rating': p.rating,
          },
        );
      }
      if (!mounted) return true;
      messenger.showSnackBar(SnackBar(
          content: Text('"${trip.name}" 여행을 만들고 ${places.length}곳을 담았어요')));
      // ④ 호스트가 현재 여행으로 전환(보통 이 화면을 닫고 새 여행 홈으로).
      widget.onTripCreated?.call(trip);
      return true;
    } catch (e) {
      if (!mounted) return false;
      messenger.showSnackBar(SnackBar(content: Text('여행 만들기 실패: $e')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTrip = widget.tripId.isNotEmpty;
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
              return _PlanItemView(
                item: _items[i],
                onAddOne: _addOne,
                hasTrip: hasTrip,
                onCreateTrip: _createTripFromPlan,
              );
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
  final bool hasTrip;
  final Future<bool> Function(List<_Proposed>) onCreateTrip;
  const _PlanItemView({
    required this.item,
    required this.onAddOne,
    required this.hasTrip,
    required this.onCreateTrip,
  });

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      _PUser(:final text) => _Bubble(text: text, fromUser: true),
      _PAi(:final text) => _Bubble(text: text, fromUser: false),
      _PError(:final text) => _ErrorCard(message: text),
      _PProposal(:final places) => _ProposalBlock(
          places: places,
          onAddOne: onAddOne,
          hasTrip: hasTrip,
          onCreateTrip: onCreateTrip,
        ),
    };
  }
}

// ──────────────────────────────────────────────────────────────
// 제안 동선 블록 — 카드 목록 + 개별 담기 + '전부 담기'
// ──────────────────────────────────────────────────────────────
class _ProposalBlock extends StatefulWidget {
  final List<_Proposed> places;
  final Future<bool> Function(_Proposed) onAddOne;

  /// 여행이 있으면 '이대로 전부 담기'(기존 일정에 추가), 없으면 '이대로 여행 만들기'.
  final bool hasTrip;
  final Future<bool> Function(List<_Proposed>) onCreateTrip;
  const _ProposalBlock({
    required this.places,
    required this.onAddOne,
    required this.hasTrip,
    required this.onCreateTrip,
  });

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

  /// 여행이 없을 때 — 이 동선 전체로 새 여행을 만든다(이름·기간 입력 → 생성 → 전부 담기).
  Future<void> _createTrip() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.onCreateTrip(widget.places);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // 성공하면 보통 화면이 새 여행으로 전환되지만, 카드도 '담음'으로 잠가 둔다.
      if (ok) _added.addAll(List.generate(widget.places.length, (i) => i));
    });
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
                // 여행이 없으면 개별 담기는 숨기고, 하단 '이대로 여행 만들기'로 한 번에 굳힌다.
                showAdd: widget.hasTrip,
                onAdd: () => _addAt(i),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              // 여행이 있으면 기존 일정에 '전부 담기', 없으면 이 동선으로 '여행 만들기'.
              child: widget.hasTrip
                  ? FilledButton.icon(
                      onPressed: (_busy || allAdded) ? null : _addAll,
                      icon: Icon(
                          allAdded ? Icons.check_circle : Icons.playlist_add),
                      label: Text(allAdded ? '모두 담음' : '이대로 전부 담기'),
                    )
                  : FilledButton.icon(
                      onPressed: (_busy || allAdded) ? null : _createTrip,
                      icon: Icon(allAdded ? Icons.check_circle : Icons.luggage),
                      label: Text(allAdded ? '여행 만듦' : '이대로 여행 만들기'),
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
  final bool showAdd; // 개별 '담기' 버튼 표시 여부(여행 없을 땐 숨김)
  final VoidCallback onAdd;
  const _ProposedCard({
    required this.index,
    required this.place,
    required this.added,
    required this.busy,
    required this.showAdd,
    required this.onAdd,
  });

  /// 이름 탭 → 구글 지도의 그 장소 페이지(평점·리뷰)를 외부 앱으로 연다.
  /// 일정 화면(_ScheduleTile)과 같은 [openPlaceInMaps] 헬퍼를 재사용한다.
  Future<void> _openReviews(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await openPlaceInMaps(
      name: place.placeName,
      placeId: place.placeId,
      address: place.address,
    );
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('리뷰를 열 수 없어요')),
      );
    }
  }

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
                // 방문 시각은 AI 가 임의로 정하지 않는다(미정으로 담기고, 시간은
                // 사용자가 일정 화면의 '시간' 버튼으로 직접 지정). 그래서 제안 카드엔
                // 시각을 표시하지 않는다.
                //
                // 이름을 탭하면 구글 지도의 그 장소 페이지(평점·리뷰 포함)를 연다 —
                // 담기 전에 리뷰를 보고 결정하라고. place_id 가 있어야 '그 장소'로
                // 정확히 꽂히므로(없으면 링크 없이 평범한 텍스트), 있을 때만 링크로 만든다.
                place.placeId.isEmpty
                    ? Text(place.placeName,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold))
                    : InkWell(
                        onTap: () => _openReviews(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(place.placeName,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: scheme.primary)),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.rate_review_outlined,
                                size: 14, color: scheme.primary),
                          ],
                        ),
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
          if (showAdd) ...[
            const SizedBox(width: 8),
            added
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child:
                        Icon(Icons.check_circle, size: 22, color: Colors.green),
                  )
                : IconButton(
                    tooltip: '이 곳 담기',
                    onPressed: busy ? null : onAdd,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
          ],
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
        // Text.rich = 한 말풍선 안에서 글자마다 다른 스타일을 줄 수 있는 Text.
        // 바깥 style(색·줄간격)은 모든 조각에 상속되고, **굵게** 구간만 weight를 덮는다.
        child: Text.rich(
          TextSpan(children: _markdownBoldSpans(text)),
          style: TextStyle(
              color: fromUser ? scheme.onPrimary : scheme.onSurface,
              height: 1.4),
        ),
      ),
    );
  }
}

/// AI 응답에 섞여 오는 마크다운 **굵게** 만 골라 진짜 볼드 조각으로 바꾼다.
///
/// AI(Bedrock — Claude)는 강조를 `**이렇게**` 별표 두 개로 표시하는데, 기본 [Text]
/// 는 마크다운을 모르고 별표까지 그대로 그린다. flutter_markdown 같은 무거운 패키지를
/// 새로 들이는 대신(대화엔 굵게 정도만 나옴), 별표 두 개로 감싼 구간만 떼어 [FontWeight]
/// 를 입히고 별표는 지운다. 정규식 `\*\*(.+?)\*\*` 는 "가장 가까운 닫는 별표까지"(비탐욕
/// `.+?`)를 한 묶음으로 잡아, 한 줄에 굵게가 여러 번 나와도 따로따로 처리한다.
List<TextSpan> _markdownBoldSpans(String text) {
  final spans = <TextSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*', dotAll: true);
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    spans.add(TextSpan(
        text: m.group(1),
        style: const TextStyle(fontWeight: FontWeight.w700)));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
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
                ? (Icons.my_location, '현재 위치 기준 — 지역명을 말하면 그곳으로 짜요',
                    scheme.primary)
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
                  hintText: '어디서 뭐 할지 말해보세요 (예: 광화문→북촌, 밥이랑 구경)',
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
