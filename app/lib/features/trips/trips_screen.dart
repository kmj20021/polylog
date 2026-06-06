import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import 'trip.dart';

/// '내 여행' 탭 — 여행을 만들고 고르고(현재 여행으로 선택) 관리한다.
///
/// 메인 셸(MainShell)의 한 탭으로 들어간다. 여행 하나를 탭하면 [onSelect] 로 부모에게
/// 알려 '현재 여행'을 바꾸고, 부모가 근처/계획/메뉴/영수증 탭으로 데려간다(이 화면에서
/// 직접 이동하지 않음 — 현재 여행 상태는 부모가 들고 있다).
///
/// 데이터 출처(모두 fn-schedule 의 POST action 분기 — 새 API 경로 없이 처리):
///   - 목록:   POST /schedule {action:"list_trips"}
///   - 생성:   POST /schedule {action:"create_trip", name, start_date, end_date}
///   - 수정:   POST /schedule {action:"update_trip", trip_id, name, start_date, end_date}
///   - 삭제:   POST /schedule {action:"delete_trip", trip_id}  (딸린 일정·대화도 함께 삭제)
class TripsScreen extends StatefulWidget {
  /// 지금 선택돼 있는 여행 id(이 화면에서 ✓ 로 표시). 없으면 null.
  final String? currentTripId;

  /// 여행을 탭해 '현재 여행'으로 고를 때 호출(부모가 상태를 바꾼다).
  final ValueChanged<Trip> onSelect;

  /// 목록이 바뀌었을 때(생성/수정/삭제) 부모에게 알림 — 부모도 사본을 새로고침한다.
  final VoidCallback? onChanged;

  const TripsScreen({
    super.key,
    required this.currentTripId,
    required this.onSelect,
    this.onChanged,
  });

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  bool _loading = true;
  String? _error;
  final List<Trip> _trips = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 서버에서 여행 목록을 불러온다(당겨서 새로고침도 이걸 호출).
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'list_trips'},
      );
      final raw = (res.data?['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _trips
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => Trip.fromJson(e.cast<String, dynamic>())));
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

  /// 새 여행 만들기 — 입력 시트를 띄워 이름·기간을 받아 서버에 저장.
  Future<void> _create() async {
    final data = await _showTripForm();
    if (data == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>('/schedule', data: {
        'action': 'create_trip',
        'name': data.name,
        'start_date': data.startDate,
        'end_date': data.endDate,
      });
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('여행 생성 실패: $e')));
    }
  }

  /// 기존 여행 수정 — 현재 값으로 채운 시트를 띄워 바뀐 값을 저장.
  Future<void> _edit(Trip trip) async {
    final data = await _showTripForm(initial: trip);
    if (data == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>('/schedule', data: {
        'action': 'update_trip',
        'trip_id': trip.tripId,
        'name': data.name,
        'start_date': data.startDate,
        'end_date': data.endDate,
      });
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('여행 수정 실패: $e')));
    }
  }

  /// 여행 삭제 — 확인 후 서버에서 지운다(그 여행의 일정·대화까지 함께 사라짐).
  Future<void> _delete(Trip trip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('여행 삭제'),
        content: Text('"${trip.name}"을(를) 삭제할까요?\n'
            '이 여행의 모든 일정과 대화 기록도 함께 사라집니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>('/schedule', data: {
        'action': 'delete_trip',
        'trip_id': trip.tripId,
      });
      if (!mounted) return;
      setState(() => _trips.removeWhere((t) => t.tripId == trip.tripId));
      widget.onChanged?.call();
      messenger.showSnackBar(SnackBar(content: Text('"${trip.name}" 삭제됨')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
      _load();
    }
  }

  /// 생성/수정 공용 입력 시트. 확인을 누르면 입력값을, 취소면 null 을 돌려준다.
  Future<_TripForm?> _showTripForm({Trip? initial}) {
    return showModalBottomSheet<_TripForm>(
      context: context,
      isScrollControlled: true, // 키보드가 올라와도 내용이 가려지지 않게
      builder: (ctx) => _TripFormSheet(initial: initial),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 여행'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('새 여행'),
      ),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading && _trips.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _trips.isEmpty) {
      return _Message(
        icon: Icons.cloud_off,
        title: '여행을 불러오지 못했어요',
        detail: _error!,
        onRetry: _load,
      );
    }
    if (_trips.isEmpty) {
      return const _Message(
        icon: Icons.luggage_outlined,
        title: '아직 만든 여행이 없어요',
        detail: '아래 "새 여행" 버튼으로 첫 여행을 만들어 보세요.\n'
            '예: 강원도 여행, 남친과 부산 여행',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), // FAB 가릴 자리 확보
      itemCount: _trips.length,
      itemBuilder: (context, i) => _TripCard(
        trip: _trips[i],
        isCurrent: _trips[i].tripId == widget.currentTripId,
        isOngoing: _trips[i].isOngoing(),
        onTap: () => widget.onSelect(_trips[i]),
        onEdit: () => _edit(_trips[i]),
        onDelete: () => _delete(_trips[i]),
      ),
    );
  }
}

/// 여행 목록의 카드 — 탭하면 현재 여행으로 선택, 오른쪽 ⋮ 메뉴로 수정/삭제.
/// '여행 중'(오늘이 기간 안)·'선택됨'을 배지/테두리로 알린다.
class _TripCard extends StatelessWidget {
  final Trip trip;
  final bool isCurrent;
  final bool isOngoing;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TripCard({
    required this.trip,
    required this.isCurrent,
    required this.isOngoing,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      // 선택된 여행은 강조 테두리로 한눈에 보이게.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isCurrent ? scheme.primary : scheme.outlineVariant,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.luggage, color: scheme.onPrimaryContainer),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(trip.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (isOngoing) ...[
              const SizedBox(width: 8),
              _Badge(text: '여행 중', color: scheme.primary),
            ],
            if (isCurrent) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle, size: 18, color: scheme.primary),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.event, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(trip.dateRangeLabel,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('수정')),
            PopupMenuItem(value: 'delete', child: Text('삭제')),
          ],
        ),
      ),
    );
  }
}

/// 작은 알약형 배지(예: "여행 중").
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

/// 생성/수정 입력값 묶음(시트가 부모에게 돌려주는 결과).
class _TripForm {
  final String name;
  final String startDate; // 'YYYY-MM-DD' 또는 ''
  final String endDate;
  const _TripForm(
      {required this.name, required this.startDate, required this.endDate});
}

/// 여행 이름 + 시작/종료일을 입력받는 바텀시트. initial 이 있으면 '수정' 모드.
class _TripFormSheet extends StatefulWidget {
  final Trip? initial;
  const _TripFormSheet({this.initial});

  @override
  State<_TripFormSheet> createState() => _TripFormSheetState();
}

class _TripFormSheetState extends State<_TripFormSheet> {
  late final TextEditingController _name;
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _start = _parse(widget.initial?.startDate);
    _end = _parse(widget.initial?.endDate);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static DateTime? _parse(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso);
  }

  /// 'YYYY-MM-DD' 로 직렬화(서버 저장용). null 이면 빈 문자열.
  static String _iso(DateTime? d) => d == null
      ? ''
      : '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  /// 화면 표시용 'YYYY.MM.DD'.
  static String _label(DateTime? d) =>
      d == null ? '선택 안 함' : _iso(d).replaceAll('-', '.');

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    setState(() {
      _start = picked;
      // 시작일이 종료일보다 늦어지면 종료일을 시작일로 맞춰 모순을 막는다.
      if (_end != null && _end!.isBefore(picked)) _end = picked;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _end ?? _start ?? DateTime.now(),
      firstDate: _start ?? DateTime(2020), // 종료일은 시작일 이후만 고르게
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    setState(() => _end = picked);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('여행 이름을 입력해 주세요')),
      );
      return;
    }
    Navigator.pop(
      context,
      _TripForm(name: name, startDate: _iso(_start), endDate: _iso(_end)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    // viewInsets.bottom: 키보드 높이만큼 아래 여백을 줘 입력창이 안 가리게 한다.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isEdit ? '여행 수정' : '새 여행',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: !isEdit,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '여행 이름',
              hintText: '예: 강원도 여행',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: '시작일',
                  value: _label(_start),
                  onTap: _pickStart,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: '종료일',
                  value: _label(_end),
                  onTap: _pickEnd,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              child: Text(isEdit ? '저장' : '만들기'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 날짜 선택 칸 — 탭하면 달력이 뜬다(라벨 + 현재 선택값 표시).
class _DateField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _DateField(
      {required this.label, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(value),
      ),
    );
  }
}

/// 빈 상태·에러 공용 안내 뷰.
class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;
  const _Message({
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
