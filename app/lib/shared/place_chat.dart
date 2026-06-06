import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/api/dio_client.dart';
import '../core/config/dev_config.dart';
import '../core/location/geolocator.dart';
import 'maps_link.dart';

/// 위치 기반 AI 장소 추천 '대화 위젯' — 추천 탭과 여행 탭이 함께 쓰는 공용 부품.
///
/// 이 위젯이 스스로 하는 일:
///   1) 화면 진입 시 GPS(또는 테스트용 고정 위치)를 한 번 확보한다.
///   2) 사용자 입력을 `POST /recommend` 로 보내고, 응답 type 으로 분기한다.
///        - "clarify": 되묻는 말풍선 + 카테고리 칩.
///        - "result" : 요약 + 장소 카드(별점·거리·리뷰 요약).
///   3) 장소 카드의 '담기'는 직접 저장하지 않고 [onAdd] 콜백으로 위임한다
///      → 추천 탭이면 일정 저장+상단 칩 갱신, 여행 탭이면 일정 저장+세로 타임라인 갱신.
///
/// Scaffold/AppBar 는 호스트가 제공하고, 이 위젯은 그 안의 한 영역(Expanded 등)으로 들어간다.
class PlaceChat extends StatefulWidget {
  /// 첫 화면에 띄울 AI 인사말(탭마다 다른 안내를 줄 수 있게 외부 주입).
  final String greeting;

  /// '담기' 처리 위임. 성공하면 true(카드가 '담음'으로 잠김), 실패면 false(다시 시도 가능).
  final Future<bool> Function(Place place) onAdd;

  const PlaceChat({
    super.key,
    required this.onAdd,
    this.greeting = '안녕하세요! 지금 계신 곳 주변을 찾아드릴게요. '
        '예: "근처 괜찮은 레스토랑 있어?", "조용한 카페 추천해줘"',
  });

  @override
  State<PlaceChat> createState() => _PlaceChatState();
}

class _PlaceChatState extends State<PlaceChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _location = LocationService();

  bool _loading = false;
  ({double lat, double lng})? _pos; // null = 위치 미확보(텍스트 폴백)
  bool _gpsTried = false;
  String _lastUserText = '';

  /// 대화 항목들(위→아래). _ChatItem 의 서브타입으로 분기 렌더.
  final List<_ChatItem> _items = [];

  @override
  void initState() {
    super.initState();
    _items.add(_AiText(widget.greeting));
    _ensureGps();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 화면 진입 시 GPS 좌표를 한 번 확보(거부/실패해도 텍스트 폴백으로 계속 진행).
  Future<void> _ensureGps() async {
    // 개발/테스트용 위치 고정이 켜져 있으면 실제 GPS 대신 그 좌표를 쓴다.
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
              .map((e) => Place.fromJson(e.cast<String, dynamic>()))
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GpsBanner(tried: _gpsTried, hasPos: _pos != null,
            mockLabel: DevConfig.mockLocation?.label),
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
                onAddToSchedule: widget.onAdd,
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
  final List<Place> places;
  const _AiResult({required this.summary, required this.places});
}

class _ChatItemView extends StatelessWidget {
  final _ChatItem item;
  final ValueChanged<String> onPickCategory;
  final Future<bool> Function(Place) onAddToSchedule;
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

/// 응답 places[] 항목 1개의 표시용 모델(공용 — onAdd 콜백 인자로도 쓰임).
class Place {
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

  const Place({
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

  factory Place.fromJson(Map<String, dynamic> j) {
    final loc = (j['location'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Place(
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

// ──────────────────────────────────────────────────────────────
// 위/아래 바 + 말풍선 / 카드들
// ──────────────────────────────────────────────────────────────
class _GpsBanner extends StatelessWidget {
  final bool tried;
  final bool hasPos;
  final String? mockLabel; // null 이 아니면 테스트용 고정 위치 사용 중
  const _GpsBanner({
    required this.tried,
    required this.hasPos,
    this.mockLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = !tried
        ? (Icons.gps_not_fixed, '현재 위치 확인 중…', scheme.onSurfaceVariant)
        : mockLabel != null
            ? (Icons.bug_report, '테스트 위치: $mockLabel', scheme.tertiary)
            : hasPos
                ? (Icons.my_location, '현재 위치 기준으로 찾아요', scheme.primary)
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
  final List<Place> places;
  final Future<bool> Function(Place) onAdd;
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
  final Place place;
  final Future<bool> Function(Place) onAdd;
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
    final ok = await widget.onAdd(widget.place);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _added = ok; // 성공했을 때만 '담음'으로 잠금(실패 시 다시 시도 가능)
    });
  }

  /// 장소명을 탭하면 구글 지도에서 그 장소를 연다(place_id 로 정확히). 실패 시 스낵바.
  Future<void> _openMaps() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await openPlaceInMaps(
      name: widget.place.name,
      placeId: widget.place.placeId,
      address: widget.place.address,
    );
    if (!mounted) return;
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('지도를 열 수 없어요')));
    }
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
                  // 장소명 탭 → 구글 지도에서 그 장소 열기. 탭 가능함을 알리려고
                  // 강조색 + 작은 지도 아이콘을 붙인다(일정 화면과 동일한 패턴).
                  child: InkWell(
                    onTap: _openMaps,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              place.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: scheme.primary),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.map_outlined,
                              size: 16, color: scheme.primary),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.bold),
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
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
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
