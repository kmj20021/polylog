import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/maps_link.dart';
import '../trips/trip.dart';

/// 메인 '내 여행' 홈의 본문 — 선택한 날짜의 계획을 '타임라인 카드'로 보여준다(읽기 전용).
///
/// 레퍼런스(docs/ref-image/main.jpg)의 아래쪽 파란 패널: 좌측 세로 타임라인 라인 +
/// 흰색 그림자 카드 + 우측 어두운 '시간 알약'. 헤더/날짜 스트립은 셸(MainShell)의 흰색
/// 상단 영역이 담당하고, 이 위젯은 파란 패널 위 카드 리스트만 그린다.
///
/// 추가/삭제/순서변경은 여기서 하지 않는다 — 상단 로고 메뉴의 '계획' 화면이 담당한다.
/// 날짜 매칭: 계획의 'day'('YYYY-MM-DD')와 [selectedDay] 비교. day 가 없는(기존/미배정)
/// 계획은 여행 '첫날'에 흡수해 사라지지 않게 한다.
class MyTripHome extends StatefulWidget {
  final Trip trip;

  /// 셸이 들고 있는 선택 날짜 'YYYY-MM-DD'(빈 값이면 날짜 없이 전체 표시).
  final String selectedDay;

  const MyTripHome({
    super.key,
    required this.trip,
    required this.selectedDay,
  });

  @override
  State<MyTripHome> createState() => _MyTripHomeState();
}

class _MyTripHomeState extends State<MyTripHome> {
  bool _loading = true;
  String? _error;
  final List<_Plan> _plans = [];

  late List<DateTime> _days; // 여행 날짜(첫날 흡수 계산용)

  @override
  void initState() {
    super.initState();
    _days = widget.trip.days();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await DioClient().get<Map<String, dynamic>>(
        '/schedule',
        queryParameters: {'trip_id': widget.trip.tripId},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _plans
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => _Plan.fromJson(e.cast<String, dynamic>())));
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

  /// 한 계획이 '어느 날'에 속하는지 — day 가 있으면 그 날, 없으면 여행 첫날(미배정 흡수).
  String _effectiveDay(_Plan p) {
    if (p.day.isNotEmpty) return p.day;
    return _days.isEmpty ? '' : Trip.ymd(_days.first);
  }

  /// 보여줄 계획 — 날짜가 없으면 전체, 있으면 선택 날짜에 속한 것만.
  List<_Plan> get _visible {
    if (widget.selectedDay.isEmpty) return _plans;
    return _plans.where((p) => _effectiveDay(p) == widget.selectedDay).toList();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.blue,
      backgroundColor: AppColors.base,
      onRefresh: _load,
      child: _body(),
    );
  }

  Widget _body() {
    if (_loading && _plans.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 120),
        Center(child: CircularProgressIndicator(color: AppColors.base)),
      ]);
    }
    if (_error != null && _plans.isEmpty) {
      return _MessageView(
        icon: Icons.cloud_off,
        title: '계획을 불러오지 못했어요',
        detail: _error!,
        onRetry: _load,
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return const _MessageView(
        icon: Icons.event_available_outlined,
        title: '이 날엔 계획이 없어요',
        detail: '오른쪽 위 로고를 눌러 "계획"에서\n장소를 담아 보세요.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      itemCount: visible.length,
      itemBuilder: (context, i) => _TimelineCard(
        plan: visible[i],
        isFirst: i == 0,
        isLast: i == visible.length - 1,
      ),
    );
  }
}

/// 좌측 타임라인 라인(점+선) + 흰색 그림자 카드 한 줄.
class _TimelineCard extends StatelessWidget {
  final _Plan plan;
  final bool isFirst;
  final bool isLast;
  const _TimelineCard({
    required this.plan,
    required this.isFirst,
    required this.isLast,
  });

  Future<void> _openMaps(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await openPlaceInMaps(
      name: plan.placeName,
      placeId: plan.placeId,
      address: plan.address,
    );
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('지도를 열 수 없어요')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 좌측 타임라인 레일: 점 + 위/아래로 이어지는 선(파란 패널 위 흰 라인).
          SizedBox(
            width: 22,
            child: Column(
              children: [
                _railLine(show: !isFirst),
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: AppColors.base,
                    shape: BoxShape.circle,
                  ),
                ),
                _railLine(show: !isLast),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 카드
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _card(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _railLine({required bool show}) => Expanded(
        child: Container(
          width: 2,
          color: show ? AppColors.base.withValues(alpha: 0.5) : Colors.transparent,
        ),
      );

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final sub = (plan.title.isNotEmpty && plan.title != plan.placeName)
        ? plan.title
        : plan.address;
    return Material(
      color: AppColors.base,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: () => _openMaps(context),
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.base,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 좌측 라운드 아이콘 박스(레퍼런스의 아바타/아이콘 자리).
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.blue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.place,
                          color: AppColors.blue, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(plan.placeName,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.north_east,
                                  size: 14, color: AppColors.blue),
                            ],
                          ),
                          if (sub.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(sub,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ],
                          if (plan.rating != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.star,
                                    size: 14, color: Colors.amber.shade700),
                                const SizedBox(width: 3),
                                Text(plan.rating!.toStringAsFixed(1),
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (plan.timeLabel.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _TimePill(text: plan.timeLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 레퍼런스의 '어두운 알약' 시간 배지(예: 10:00 AM / 오전).
class _TimePill extends StatelessWidget {
  final String text;
  const _TimePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2233), // 어두운 알약(레퍼런스 톤) — 토큰 외 국소색
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: const TextStyle(
              color: AppColors.base,
              fontSize: 12,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// 빈 상태·에러 안내(파란 패널 위 — 흰 글씨/아이콘).
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
    // RefreshIndicator 가 동작하려면 항상 스크롤 가능해야 해서 ListView 로 감싼다.
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      children: [
        const SizedBox(height: 100),
        Icon(icon, size: 56, color: AppColors.base),
        const SizedBox(height: 12),
        Center(
          child: Text(title,
              style: const TextStyle(
                  color: AppColors.base,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 6),
        Text(detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.base.withValues(alpha: 0.85))),
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

/// 메인 홈에서 쓰는 경량 계획 모델 — polylog-schedules 한 행(읽기용).
class _Plan {
  final String startTime;
  final String day; // 'YYYY-MM-DD'(없을 수 있음)
  final String placeId;
  final String title;
  final String placeName;
  final String address;
  final String timeLabel;
  final double? rating;

  const _Plan({
    required this.startTime,
    required this.day,
    required this.placeId,
    required this.title,
    required this.placeName,
    required this.address,
    required this.timeLabel,
    required this.rating,
  });

  factory _Plan.fromJson(Map<String, dynamic> j) {
    final name = (j['place_name'] ?? '').toString();
    return _Plan(
      startTime: (j['start_time'] ?? '').toString(),
      day: (j['day'] ?? '').toString(),
      placeId: (j['place_id'] ?? '').toString(),
      title: (j['title'] ?? name).toString(),
      placeName: name,
      address: (j['address'] ?? '').toString(),
      timeLabel: (j['time_label'] ?? '').toString(),
      rating: (j['rating'] as num?)?.toDouble(),
    );
  }
}
