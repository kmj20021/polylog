import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/location/geolocator.dart';

/// 위치 기반 AI 장소 추천 화면 (메인 기능 #1).
///
/// 기본 동작은 GPS — "내 주변 추천받기"를 누르면 현재 좌표를 잡아
/// POST /recommend 에 {lat,lng,category} 를 보낸다. 위치 권한이 거부되거나
/// GPS 가 꺼져 있으면 여행지를 직접 입력하는 텍스트 폴백으로 추천한다.
/// 응답의 places[] 를 별점·거리·추천 이유가 담긴 카드 리스트로 그린다.
class RecommendScreen extends StatefulWidget {
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  final _locationController = TextEditingController();
  final _location = LocationService();

  static const _categories = ['맛집', '숙소', '관광지', '카페'];
  String _category = '맛집';

  bool _loading = false;
  String? _error;
  String? _aiSummary;
  String? _resultHeader;
  List<_Place> _places = const [];

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  /// 📍 GPS 경로 — 현재 좌표를 잡아 추천. 좌표를 못 얻으면 텍스트 입력 안내.
  Future<void> _fetchByGps() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pos = await _location.getCurrentPosition();
      if (pos == null) {
        setState(() => _error =
            '위치를 가져오지 못했어요. 위치 권한을 허용하거나, 아래에 여행지를 직접 입력해 주세요.');
        return;
      }
      await _post(
        {'lat': pos.latitude, 'lng': pos.longitude, 'category': _category},
        header: '내 주변 · $_category',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// ⌨️ 폴백 경로 — 입력한 여행지 텍스트로 추천.
  Future<void> _fetchByText() async {
    final location = _locationController.text.trim();
    if (location.isEmpty) {
      setState(() => _error = '여행지를 입력하거나 "내 주변 추천받기"를 눌러 주세요.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _post(
        {'location': location, 'category': _category},
        header: '$location · $_category',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 공통 호출 — 성공하면 ai_summary + places 카드로 그린다.
  Future<void> _post(Map<String, dynamic> data, {required String header}) async {
    setState(() {
      _error = null;
      _aiSummary = null;
      _places = const [];
    });
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/recommend',
        data: data,
      );
      final body = res.data ?? const {};
      final rawPlaces = (body['places'] as List?) ?? const [];
      setState(() {
        _resultHeader = header;
        _aiSummary = (body['ai_summary'] ?? '').toString();
        _places = rawPlaces
            .whereType<Map>()
            .map((e) => _Place.fromJson(e.cast<String, dynamic>()))
            .toList();
      });
    } on DioException catch (e) {
      final b = e.response?.data;
      final msg = (b is Map && b['error'] != null)
          ? b['error']
          : (e.message ?? '네트워크 오류');
      setState(() => _error = 'AI 추천을 불러오지 못했어요.\n$msg');
    } catch (e) {
      setState(() => _error = '알 수 없는 오류: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 장소 추천')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(
                labelText: '카테고리',
                prefixIcon: Icon(Icons.category_outlined),
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in _categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _category = v ?? _category),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading ? null : _fetchByGps,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
              label: Text(_loading ? '주변 검색 중…' : '내 주변 추천받기'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('또는 여행지 직접 입력',
                      style: theme.textTheme.bodySmall),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _locationController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _loading ? null : _fetchByText(),
              decoration: InputDecoration(
                labelText: '여행지',
                hintText: '예: 도쿄 신주쿠',
                prefixIcon: const Icon(Icons.place_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _loading ? null : _fetchByText,
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_error != null) _ErrorCard(message: _error!),
            if (_aiSummary != null && _aiSummary!.isNotEmpty)
              _SummaryCard(
                header: _resultHeader ?? '',
                summary: _aiSummary!,
                color: theme.colorScheme.primary,
              ),
            if (_places.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final p in _places) _PlaceCard(place: p),
            ],
            if (_aiSummary != null && _places.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('조건에 맞는 장소를 찾지 못했어요.'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 응답 places[] 항목 1개의 표시용 모델.
class _Place {
  final String name;
  final double? rating;
  final int userRatings;
  final int? distanceM;
  final String address;
  final bool? openNow;
  final String aiReason;

  const _Place({
    required this.name,
    required this.rating,
    required this.userRatings,
    required this.distanceM,
    required this.address,
    required this.openNow,
    required this.aiReason,
  });

  factory _Place.fromJson(Map<String, dynamic> j) {
    return _Place(
      name: (j['name'] ?? '').toString(),
      rating: (j['rating'] as num?)?.toDouble(),
      userRatings: (j['user_ratings'] as num?)?.toInt() ?? 0,
      distanceM: (j['distance_m'] as num?)?.toInt(),
      address: (j['address'] ?? '').toString(),
      openNow: j['open_now'] as bool?,
      aiReason: (j['ai_reason'] ?? '').toString(),
    );
  }

  /// 거리 표기: 1km 미만은 m, 이상은 km(소수 1자리).
  String? get distanceLabel {
    if (distanceM == null) return null;
    if (distanceM! < 1000) return '${distanceM}m';
    return '${(distanceM! / 1000).toStringAsFixed(1)}km';
  }
}

class _SummaryCard extends StatelessWidget {
  final String header;
  final String summary;
  final Color color;
  const _SummaryCard({
    required this.header,
    required this.summary,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: color.withOpacity(0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withOpacity(0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    header,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(summary,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
          ],
        ),
      ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final _Place place;
  const _PlaceCard({required this.place});

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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              place.name,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
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
                    iconColor:
                        place.openNow! ? Colors.green : scheme.error,
                    label: place.openNow! ? '영업 중' : '영업 종료',
                  ),
              ],
            ),
            if (place.aiReason.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(place.aiReason,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.4)),
                    ),
                  ],
                ),
              ),
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

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
