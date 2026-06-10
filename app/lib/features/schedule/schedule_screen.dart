import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/bookmark_panel.dart';
import '../../shared/feature_nav.dart';
import '../../shared/maps_link.dart';
import 'schedule_planner.dart';

/// '여행' 탭 — 담아 둔 일정(polylog-schedules)을 세로 타임라인으로 보여주고 관리한다.
///
/// 추천 화면 상단의 작은 칩 타임라인이 '미리보기'라면, 이 화면은 일정 전체를
/// 한눈에 펼쳐 보고 개별 항목을 지울 수 있는 '본 화면'이다.
///
/// 데이터 출처:
///   - 조회: GET  /schedule?trip_id=demo-trip   (이미 배포된 fn-schedule)
///   - 삭제: DELETE /schedule {trip_id, start_time}  (fn-schedule 신규)
class ScheduleScreen extends StatefulWidget {
  /// 어느 여행의 일정을 보여줄지 — '내 여행' 목록에서 선택한 여행이 주입된다.
  final String tripId;
  final String tripName;

  /// 새로 담는 계획을 붙일 날짜 'YYYY-MM-DD'(메인 홈에서 보고 있던 날). 빈 값이면 미지정.
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

  @override
  void initState() {
    super.initState();
    _load();
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

  /// 손잡이를 끌어 순서를 바꿨을 때: ① 화면에서 먼저 옮겨 즉시 반응시키고
  /// ② 서버에 '새 순서'(start_time 목록)를 보내 영구 반영, ③ 서버가 다시 매긴
  /// start_time 으로 동기화한다. 실패하면 서버 상태로 되돌려 어긋남을 막는다.
  /// (백엔드는 fn-schedule 의 POST {action:"reorder"} 가 처리 — 이미 배포됨.)
  Future<void> _reorder(int oldIndex, int newIndex) async {
    // onReorderItem 은 newIndex 를 이미 보정해 준다(직접 -1 안 해도 됨).
    if (oldIndex == newIndex) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      final moved = _items.removeAt(oldIndex);
      _items.insert(newIndex, moved);
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
  ///   - 블루 배경 + 상단 바(뒤로가기 / 로고 아바타).
  ///   - 상단 '끌어내리는' 일정 패널 — 평소엔 접혀 마지막 일정 1개만, 손잡이를
  ///     아래로 슬라이드(또는 탭)하면 펼쳐져 전체 일정을 본다(_SchedulePanel).
  ///   - 그 아래 큰 흰 패널 = AI 대화 플래너(+ 하단 입력창).
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
                // 바닥: 상단 바 + (접힌 일정 패널 자리) + 큰 흰 플래너 패널.
                Column(
                  children: [
                    BookmarkTopBar(
                      title: widget.tripName,
                      onBack: () => Navigator.of(context).maybePop(),
                      onLogoTap: () => showFeatureNavMenu(
                        context,
                        tripId: widget.tripId,
                        tripName: widget.tripName,
                        day: widget.day,
                        current: FeatureDest.plan,
                      ),
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
                        child: SchedulePlanner(
                          tripId: widget.tripId,
                          day: widget.day, // 담을 때 이 날짜로 저장
                          onScheduleChanged: _load, // 담기/편집 후 타임라인 새로고침
                          // 여행이 없을 때 '이대로 여행 만들기'로 새 여행이 생기면 이
                          // 화면을 닫으며 새 여행을 돌려준다 → 홈(MainShell)이 현재
                          // 여행으로 삼는다.
                          onTripCreated: (trip) =>
                              Navigator.of(context).pop(trip),
                        ),
                      ),
                    ),
                  ],
                ),
                // 상단 일정 패널(접힘↔펼침) — 펼치면 플래너 위로 내려와 덮는다.
                Positioned(
                  top: topBarH,
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

  /// 접힘 상태에 보이는 '마지막 일정 1개' 요약(없으면 안내, 로딩 중이면 스피너).
  Widget _collapsedView() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_loading && _items.isEmpty) {
      return const Center(
        child: SizedBox(
            width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            _error != null ? '일정을 불러오지 못했어요' : '아직 담은 일정이 없어요',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final last = _items.last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primary,
            child: Text('${_items.length}',
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
                Text('마지막 일정 · 총 ${_items.length}개 — 아래로 끌어 전체 보기',
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
    if (_items.isEmpty) {
      return const _MessageView(
        icon: Icons.event_available_outlined,
        title: '아직 담은 일정이 없어요',
        detail: '"추천" 탭에서 마음에 드는 장소의 "담기"를 누르면\n여기에 순서대로 쌓입니다.',
      );
    }
    // 세로 타임라인을 드래그로 재정렬. 밀어서 삭제(Dismissible)와 제스처가 겹치지
    // 않도록 기본 드래그는 끄고(buildDefaultDragHandles:false), 오른쪽 '손잡이'에서만
    // 끌 수 있게 한다(_ScheduleTile 안의 ReorderableDragStartListener).
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: _items.length,
      onReorderItem: _reorder,
      buildDefaultDragHandles: false,
      itemBuilder: (context, i) => _ScheduleTile(
        key: ValueKey(_items[i].startTime),
        index: i + 1,
        listIndex: i,
        item: _items[i],
        isLast: i == _items.length - 1,
        confirmDelete: () => _confirmDelete(_items[i]),
        onDelete: () => _delete(_items[i]),
      ),
    );
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

  const _Schedule({
    required this.startTime,
    required this.placeId,
    required this.title,
    required this.placeName,
    required this.address,
    required this.rating,
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
    );
  }
}

/// 세로 타임라인의 한 줄: 왼쪽 순번 점 + 연결선, 오른쪽 장소 카드.
/// 스와이프(밀기)로 삭제할 수 있다(Dismissible).
class _ScheduleTile extends StatelessWidget {
  final int index;        // 화면에 보이는 순번(1-based)
  final int listIndex;    // 드래그 재정렬용 리스트 위치(0-based)
  final _Schedule item;
  final bool isLast;
  final Future<bool> Function() confirmDelete;
  final VoidCallback onDelete;

  const _ScheduleTile({
    super.key,
    required this.index,
    required this.listIndex,
    required this.item,
    required this.isLast,
    required this.confirmDelete,
    required this.onDelete,
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
                        // 장소명 탭 → 구글 지도에서 그 장소를 연다. 탭 가능함을 알리려고
                        // 옆에 작은 지도 아이콘을 붙이고 글자색도 강조색으로 둔다.
                        InkWell(
                          onTap: () => _openMaps(context),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(item.placeName,
                                      style: theme.textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: scheme.primary)),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.map_outlined,
                                    size: 16, color: scheme.primary),
                              ],
                            ),
                          ),
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
