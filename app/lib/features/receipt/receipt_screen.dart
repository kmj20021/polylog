import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/feature_nav.dart';

/// 영수증(지출 가계부) 화면 — 현재 여행(tripId)의 지출을 사진으로 기록하고,
/// 날짜별로 보여주며, 사용자가 직접 보정하고, 여행 전체 지출을 대시보드로 본다.
///
/// 서버(`POST /receipt`)는 action 으로 분기한다(새 라우트 없이):
///  - (기본) analyze : 사진 한 장 분석 후 저장 → 결과 반환
///  - list            : 이 여행의 영수증 전체(대시보드·날짜별 목록)
///  - update          : 보정한 영수증 1건을 다시 저장(환율 재계산·rate 명시)
///  - delete          : 영수증 1건 삭제
///
/// 화면 구성: ① 상단 대시보드 카드(총지출 + 카테고리별 합계) ② 날짜별 영수증 목록
///           ③ FAB "영수증 찍기"(분석→자동으로 보정 시트 열기).
class ReceiptScreen extends StatefulWidget {
  final String tripId;
  final String tripName;

  /// 기능 화면끼리 이동할 때 같은 여행 날짜 맥락을 넘기기 위한 값(영수증 화면 자체는 안 씀).
  final String day;
  const ReceiptScreen(
      {super.key, required this.tripId, required this.tripName, this.day = ''});

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

/// 지출 카테고리(서버 _CATEGORIES 와 동일 순서·이름) — 드롭다운·색칠에 공유.
const List<String> kCategories = ['식비', '교통', '쇼핑', '숙박', '관광', '기타'];

const Map<String, Color> kCategoryColors = {
  '식비': Color(0xFFE57373),
  '교통': Color(0xFF64B5F6),
  '쇼핑': Color(0xFFBA68C8),
  '숙박': Color(0xFF4DB6AC),
  '관광': Color(0xFFFFB74D),
  '기타': Color(0xFF90A4AE),
};

class _ReceiptScreenState extends State<ReceiptScreen> {
  final ImagePicker _picker = ImagePicker();

  bool _loading = true; // 첫 진입은 목록 로딩부터
  bool _busy = false; // 분석/저장 등 작업 중(중복 방지 + 오버레이)
  List<_Receipt> _receipts = [];

  final TextEditingController _search = TextEditingController();
  String _query = ''; // 가게·품목 검색어(목록만 필터; 대시보드는 전체 기준)

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ── 서버 호출 ───────────────────────────────────────────────
  Future<void> _loadList() async {
    setState(() => _loading = true);
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/receipt',
        data: {'action': 'list', 'trip_id': widget.tripId},
      );
      final raw = (res.data?['receipts'] as List?) ?? const [];
      final list = raw
          .whereType<Map>()
          .map((e) => _Receipt.fromJson(e.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _receipts = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('목록을 불러오지 못했어요: $e');
    }
  }

  /// 카메라/갤러리로 영수증을 찍어 분석(저장)하고, 곧바로 보정 시트를 연다.
  Future<void> _pickAndAnalyze(ImageSource source) async {
    try {
      // 미리 줄여 전송 — Lambda 동기 본문 6MB·우리 한도 5MB 보호(영수증 글자엔 1600px 충분).
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return; // 취소

      setState(() => _busy = true);
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);

      final res = await DioClient().post<Map<String, dynamic>>(
        '/receipt',
        data: {
          'trip_id': widget.tripId,
          'image_base64': b64,
          'home_currency': 'KRW',
        },
      );
      if (!mounted) return;
      setState(() => _busy = false);

      final r = _Receipt.fromJson(res.data ?? const {});
      await _loadList(); // 새 영수증이 목록에 반영되도록
      if (!mounted) return;
      // 분석 결과는 부정확할 수 있으니 바로 보정 시트를 띄운다.
      _openEditSheet(r, note: r.note);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('분석 실패: $e');
    }
  }

  Future<void> _saveEdit(_Receipt edited) async {
    setState(() => _busy = true);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/receipt',
        data: {'action': 'update', ...edited.toUpdateJson(widget.tripId)},
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _loadList();
      _snack('저장했어요.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('저장 실패: $e');
    }
  }

  Future<void> _deleteReceipt(_Receipt r) async {
    setState(() => _busy = true);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/receipt',
        data: {'action': 'delete', 'trip_id': widget.tripId, 'sk': r.sk},
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _loadList();
      _snack('삭제했어요.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('삭제 실패: $e');
    }
  }

  // ── 보정 시트 ───────────────────────────────────────────────
  void _openEditSheet(_Receipt r, {String? note}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ReceiptEditSheet(
        initial: r,
        note: note,
        onSave: (edited) {
          Navigator.pop(ctx);
          _saveEdit(edited);
        },
        onDelete: () {
          Navigator.pop(ctx);
          _deleteReceipt(r);
        },
      ),
    );
  }

  void _showSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('카메라로 촬영'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndAnalyze(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('갤러리에서 선택'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndAnalyze(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── 빌드 ────────────────────────────────────────────────────
  /// 레퍼런스(docs/ref-image/ui2.jpg): 블루 배경 + 상단 바(뒤로 / 검색 / 로고),
  /// 큰 흰 라운드 패널(대시보드+목록), 하단 흰 박스('영수증 찍기').
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _topBar(),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: const BoxDecoration(
                      color: AppColors.base,
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(28)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _content(),
                  ),
                ),
                _bottomBar(),
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black26,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 블루 상단 바 — 뒤로가기 / 가게·품목 검색 / 로고 아바타.
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
      child: Row(
        children: [
          IconButton(
            tooltip: '뒤로',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new,
                color: AppColors.base, size: 20),
          ),
          Expanded(
            child: SizedBox(
              height: 44,
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v.trim()),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '가게·품목 검색',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppColors.base,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => showFeatureNavMenu(
              context,
              tripId: widget.tripId,
              tripName: widget.tripName,
              day: widget.day,
              current: FeatureDest.receipt,
            ),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.base, width: 2),
              ),
              child: const CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.base,
                backgroundImage: AssetImage('assets/logo/polylog_logo.png'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 하단 흰 박스 — '영수증 찍기' 액션(기존 FAB 대체).
  Widget _bottomBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.base,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _busy ? null : _showSourceSheet,
          icon: const Icon(Icons.add_a_photo),
          label: const Text('영수증 찍기'),
        ),
      ),
    );
  }

  /// 흰 패널 본문 — 로딩 / 빈 안내 / 가계부.
  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_receipts.isEmpty) return _intro();
    return _ledger();
  }

  Widget _intro() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text('영수증을 찍어 지출을 기록해요',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '아래 "영수증 찍기"로 사진 속 품목·금액·통화를 읽어 원화로 환산해요.\n'
              '읽은 결과는 눌러서 직접 고칠 수 있고, 날짜별·카테고리별로 모아 봐요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 대시보드(전체 기준) + 날짜별 목록(검색어로 필터).
  Widget _ledger() {
    final q = _query.toLowerCase();
    final filtered = q.isEmpty
        ? _receipts
        : _receipts
            .where((r) =>
                r.merchant.toLowerCase().contains(q) ||
                r.items.any((it) => it.nameKo.toLowerCase().contains(q)))
            .toList();
    final groups = _groupByDate(filtered);
    return RefreshIndicator(
      onRefresh: _loadList,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _Dashboard(receipts: _receipts),
          const SizedBox(height: 8),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('"$_query" 검색 결과가 없어요',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            )
          else
            for (final entry in groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                child: Text(entry.key.isEmpty ? '(날짜 미상)' : entry.key,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              for (final r in entry.value)
                _ReceiptTile(receipt: r, onTap: () => _openEditSheet(r)),
            ],
        ],
      ),
    );
  }

  /// 날짜(occurredAt)별로 묶어 최신 날짜가 위로 오게 정렬.
  List<MapEntry<String, List<_Receipt>>> _groupByDate(List<_Receipt> rs) {
    final map = <String, List<_Receipt>>{};
    for (final r in rs) {
      map.putIfAbsent(r.occurredAt, () => []).add(r);
    }
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) MapEntry(k, map[k]!)];
  }
}

// ──────────────────────────────────────────────────────────────
// 대시보드 카드 — 여행 총지출 + 카테고리별 합계(품목 amount_krw 합산)
// ──────────────────────────────────────────────────────────────
class _Dashboard extends StatelessWidget {
  final List<_Receipt> receipts;
  const _Dashboard({required this.receipts});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 여행 총지출 = 영수증 합계(total_krw) 합.
    var total = 0;
    var hasMissing = false; // 환산 안 된 영수증이 섞였는지
    for (final r in receipts) {
      if (r.totalKrw != null) {
        total += r.totalKrw!;
      } else {
        hasMissing = true;
      }
    }

    // 카테고리별 합계 = 모든 영수증의 품목 amount_krw 를 카테고리로 합산.
    final byCat = <String, int>{for (final c in kCategories) c: 0};
    for (final r in receipts) {
      for (final it in r.items) {
        if (it.amountKrw != null) {
          byCat[it.category] = (byCat[it.category] ?? 0) + it.amountKrw!;
        }
      }
    }
    final catTotal = byCat.values.fold<int>(0, (a, b) => a + b);
    final shown = kCategories.where((c) => (byCat[c] ?? 0) > 0).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('여행 총지출',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 2),
            Text('₩ ${_comma(total)}',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: scheme.primary)),
            Text('영수증 ${receipts.length}건',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            if (hasMissing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('* 환율을 못 구한 영수증은 합계에서 빠졌어요(눌러서 통화를 고쳐보세요).',
                    style: TextStyle(color: scheme.error, fontSize: 11)),
              ),
            if (shown.isNotEmpty) ...[
              const Divider(height: 24),
              Text('카테고리별 지출',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 8),
              for (final c in shown)
                _CategoryBar(
                  category: c,
                  amount: byCat[c]!,
                  fraction: catTotal == 0 ? 0 : byCat[c]! / catTotal,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 카테고리별 막대 한 줄(이름 칩 + 비율 막대 + ₩금액).
class _CategoryBar extends StatelessWidget {
  final String category;
  final int amount;
  final double fraction;
  const _CategoryBar(
      {required this.category, required this.amount, required this.fraction});

  @override
  Widget build(BuildContext context) {
    final color = kCategoryColors[category] ?? kCategoryColors['기타']!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 40, child: _CategoryChip(category: category)),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('₩ ${_comma(amount)}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 영수증 한 줄(목록) — 가게명·원화·원본금액·적용환율, 탭하면 보정
// ──────────────────────────────────────────────────────────────
class _ReceiptTile extends StatelessWidget {
  final _Receipt receipt;
  final VoidCallback onTap;
  const _ReceiptTile({required this.receipt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = receipt;
    final subtitleParts = <String>[];
    if (r.total != null) {
      subtitleParts.add('원본 ${r.total}${r.currency != null ? ' ${r.currency}' : ''}');
    }
    final rateLabel = r.rateLabel;
    if (rateLabel != null) subtitleParts.add(rateLabel);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        title: Text(r.merchant.isEmpty ? '(가게명 미인식)' : r.merchant,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitleParts.isNotEmpty)
              Text(subtitleParts.join('  ·  '),
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12)),
            Text('품목 ${r.items.length}개',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ],
        ),
        trailing: Text(
          r.totalKrw != null ? '₩ ${_comma(r.totalKrw!)}' : '환산 안됨',
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: r.totalKrw != null ? scheme.primary : scheme.error),
        ),
      ),
    );
  }
}

/// 지출 카테고리 색칠 칩.
class _CategoryChip extends StatelessWidget {
  final String category;
  const _CategoryChip({required this.category});

  @override
  Widget build(BuildContext context) {
    final color = kCategoryColors[category] ?? kCategoryColors['기타']!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(category,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 보정 시트 — 가게명·날짜·통화·합계 + 품목(이름/금액/카테고리) 직접 수정
// ──────────────────────────────────────────────────────────────
class _ReceiptEditSheet extends StatefulWidget {
  final _Receipt initial;
  final String? note;
  final ValueChanged<_Receipt> onSave;
  final VoidCallback onDelete;
  const _ReceiptEditSheet({
    required this.initial,
    required this.onSave,
    required this.onDelete,
    this.note,
  });

  @override
  State<_ReceiptEditSheet> createState() => _ReceiptEditSheetState();
}

class _ReceiptEditSheetState extends State<_ReceiptEditSheet> {
  late TextEditingController _merchant;
  late TextEditingController _currency;
  late TextEditingController _total;
  late String _date; // YYYY-MM-DD
  late List<_EditableItem> _items;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _merchant = TextEditingController(text: r.merchant);
    _currency = TextEditingController(text: r.currency ?? '');
    _total = TextEditingController(text: r.total ?? '');
    _date = r.occurredAt;
    _items = r.items
        .map((it) => _EditableItem(
              name: TextEditingController(text: it.nameKo),
              amount: TextEditingController(text: it.amount ?? ''),
              category: kCategories.contains(it.category) ? it.category : '기타',
            ))
        .toList();
  }

  @override
  void dispose() {
    _merchant.dispose();
    _currency.dispose();
    _total.dispose();
    for (final it in _items) {
      it.name.dispose();
      it.amount.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final init = DateTime.tryParse(_date) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _date =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
    }
  }

  void _submit() {
    final cur = _currency.text.trim().toUpperCase();
    final edited = _Receipt(
      receiptId: widget.initial.receiptId,
      sk: widget.initial.sk,
      occurredAt: _date,
      merchant: _merchant.text.trim(),
      currency: cur.isEmpty ? null : cur,
      total: _total.text.trim().isEmpty ? null : _total.text.trim(),
      totalKrw: widget.initial.totalKrw, // 서버가 재계산해 응답함
      rate: widget.initial.rate,
      homeCurrency: widget.initial.homeCurrency,
      photoS3Key: widget.initial.photoS3Key,
      items: [
        for (final it in _items)
          _Item(
            nameKo: it.name.text.trim(),
            amount: it.amount.text.trim().isEmpty ? null : it.amount.text.trim(),
            amountKrw: null,
            category: it.category,
          ),
      ],
    );
    widget.onSave(edited);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 저장 버튼이 ①키보드(viewInsets)와 ②시스템 내비게이션 바(padding.bottom)에
    // 가리지 않도록 둘을 모두 피한다. 키보드가 올라오면 padding.bottom 은 0 이 되고
    // viewInsets 가 그 높이를 대신하므로, 둘을 더하면 키보드 유/무 두 경우 모두 맞다.
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom + media.padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('영수증 수정',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  onPressed: widget.onDelete,
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  label: Text('삭제', style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
            if (widget.note != null && widget.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(widget.note!,
                    style: TextStyle(color: scheme.error, fontSize: 13)),
              ),
            TextField(
              controller: _merchant,
              decoration: const InputDecoration(labelText: '가게명'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: '날짜'),
                      child: Text(_date.isEmpty ? '선택' : _date),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _currency,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                        labelText: '통화', hintText: 'JPY'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _total,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: '합계(원본 통화)', hintText: '예: 3500'),
            ),
            if (widget.initial.rateLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(widget.initial.rateLabel!,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12)),
              ),
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: Text('품목',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _items.add(_EditableItem(
                        name: TextEditingController(),
                        amount: TextEditingController(),
                        category: '기타',
                      ))),
                  icon: const Icon(Icons.add),
                  label: const Text('추가'),
                ),
              ],
            ),
            for (int i = 0; i < _items.length; i++) _itemRow(i),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.save),
                label: const Text('저장'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemRow(int i) {
    final it = _items[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: it.name,
              decoration: const InputDecoration(
                  labelText: '품목', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: it.amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: '금액', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: it.category,
            underline: const SizedBox.shrink(),
            items: [
              for (final c in kCategories)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) =>
                setState(() => it.category = v ?? it.category),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              it.name.dispose();
              it.amount.dispose();
              _items.removeAt(i);
            }),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 보정 시트 내부의 편집용 임시 항목(컨트롤러 보관).
class _EditableItem {
  final TextEditingController name;
  final TextEditingController amount;
  String category;
  _EditableItem(
      {required this.name, required this.amount, required this.category});
}

// ──────────────────────────────────────────────────────────────
// 모델 (서버 응답 파싱 + update 페이로드 생성)
// ──────────────────────────────────────────────────────────────
class _Receipt {
  final String receiptId;
  final String sk; // update/delete 키(서버 SK 값)
  final String occurredAt; // 표시·그룹핑용 날짜(YYYY-MM-DD)
  final String merchant;
  final String? currency;
  final String? total;
  final int? totalKrw;
  final String? rate; // 적용 환율(1 currency = rate KRW)
  final String homeCurrency;
  final String photoS3Key;
  final List<_Item> items;
  final String? note;

  const _Receipt({
    required this.receiptId,
    required this.sk,
    required this.occurredAt,
    required this.merchant,
    required this.currency,
    required this.total,
    required this.totalKrw,
    required this.rate,
    required this.homeCurrency,
    required this.photoS3Key,
    required this.items,
    this.note,
  });

  /// "환율 1 JPY = 9.00 KRW" — 적용 환율 명시(없으면 null).
  String? get rateLabel {
    final cur = currency;
    final rt = rate;
    if (cur == null || rt == null) return null;
    final v = double.tryParse(rt);
    if (v == null) return null;
    return '환율 1 $cur = ${_money(v)} $homeCurrency';
  }

  factory _Receipt.fromJson(Map<String, dynamic> j) {
    final rawItems = (j['items'] as List?) ?? const [];
    return _Receipt(
      receiptId: (j['receipt_id'] ?? '').toString(),
      sk: (j['sk'] ?? j['occurred_at'] ?? '').toString(),
      occurredAt: (j['occurred_at'] ?? '').toString(),
      merchant: (j['merchant'] ?? '').toString(),
      currency: j['currency']?.toString(),
      total: j['total']?.toString(),
      totalKrw: (j['total_krw'] as num?)?.toInt(),
      rate: j['rate']?.toString(),
      homeCurrency: (j['home_currency'] ?? 'KRW').toString(),
      photoS3Key: (j['photo_s3_key'] ?? '').toString(),
      note: j['note']?.toString(),
      items: rawItems
          .whereType<Map>()
          .map((e) => _Item.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// update 액션 페이로드(서버가 환율·원화를 재계산하므로 원본 통화 값만 보낸다).
  Map<String, dynamic> toUpdateJson(String tripId) => {
        'trip_id': tripId,
        'receipt_id': receiptId,
        'sk': sk,
        'occurred_at': occurredAt,
        'merchant': merchant,
        'currency': currency,
        'total': total,
        'home_currency': homeCurrency,
        'photo_s3_key': photoS3Key,
        'items': [
          for (final it in items)
            {
              'item_id': it.itemId,
              'name_ko': it.nameKo,
              'amount': it.amount,
              'category': it.category,
            },
        ],
      };
}

class _Item {
  final String itemId;
  final String nameKo;
  final String? amount;
  final int? amountKrw;
  final String category;
  const _Item({
    this.itemId = '',
    required this.nameKo,
    required this.amount,
    required this.amountKrw,
    required this.category,
  });

  factory _Item.fromJson(Map<String, dynamic> j) => _Item(
        itemId: (j['item_id'] ?? '').toString(),
        nameKo: (j['name_ko'] ?? '').toString(),
        amount: j['amount']?.toString(),
        amountKrw: (j['amount_krw'] as num?)?.toInt(),
        category: (j['category'] ?? '기타').toString(),
      );
}

// ── 숫자 포맷 ──────────────────────────────────────────────────
/// 정수 천 단위 콤마 — 92281 → "92,281".
String _comma(int n) {
  final neg = n < 0;
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return (neg ? '-' : '') + buf.toString();
}

/// 환율 표시 — 정수면 콤마, 소수면 2자리(예: 9.00, 1,043.50).
String _money(double v) {
  final whole = v.truncate();
  final frac = ((v - whole) * 100).round().abs();
  return '${_comma(whole)}.${frac.toString().padLeft(2, '0')}';
}
