import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/dio_client.dart';
import '../../shared/google_lens.dart';

/// 메뉴판 번역 화면 — 현재 여행(tripId)의 식당 메뉴판을 사진 한 장으로 읽어
/// 한국어 번역 + 한 줄 설명 + AI 추천을 보여준다.
///
/// 서버(`POST /menu`)는 사진을 Bedrock(Claude Haiku) 비전으로 직접 읽어
/// 원문·번역·설명·가격을 추출하고, 알레르기(식이 제한)를 피한 추천 항목을 고른다.
/// 새 라우트·액션 분기 없이 단일 흐름: 사진 → 분석 결과 표시.
///
/// 화면 구성: ① 상단 알레르기 입력 카드(추천 정확도용) ② 분석 결과 메뉴 목록
///           (추천 항목엔 ⭐배지) ③ FAB "메뉴판 찍기".
class MenuScreen extends StatefulWidget {
  final String tripId;
  final String tripName;
  const MenuScreen(
      {super.key, required this.tripId, required this.tripName});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _allergyInput = TextEditingController();

  bool _busy = false; // 분석 중(중복 방지 + 오버레이)
  bool _analyzed = false; // 한 번이라도 분석했는지(인트로 vs 결과)
  final List<String> _allergies = []; // 등록한 알레르기(칩으로 누적)
  List<_MenuItem> _items = [];
  Set<String> _recommended = {}; // 추천 item_id
  String? _message; // 서버가 "못 읽었어요" 등 안내를 줄 때
  String? _unsupportedLanguage; // 비라틴 메뉴판 → 구글 렌즈 유도(감지된 언어명)

  @override
  void dispose() {
    _allergyInput.dispose();
    super.dispose();
  }

  /// 등록한 알레르기 목록(서버 추천 제외용으로 그대로 전송).
  List<String> _dietaryList() => List<String>.from(_allergies);

  /// 입력창의 텍스트를 칩으로 추가한다("갑각류, 땅콩"처럼 쉼표 다중 입력도 분해).
  /// 대소문자 무시 중복은 건너뛴다.
  void _addAllergy() {
    final parts = _allergyInput.text
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    setState(() {
      for (final p in parts) {
        final dup = _allergies.any((a) => a.toLowerCase() == p.toLowerCase());
        if (!dup) _allergies.add(p);
      }
      _allergyInput.clear();
    });
  }

  // ── 서버 호출 ───────────────────────────────────────────────
  /// 카메라/갤러리로 메뉴판을 찍어 분석한다.
  Future<void> _pickAndAnalyze(ImageSource source) async {
    try {
      // 미리 줄여 전송 — Lambda 동기 본문 6MB·우리 한도 5MB 보호(글자 인식엔 1600px 충분).
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
        '/menu',
        data: {
          'trip_id': widget.tripId,
          'image_base64': b64,
          'language': 'ko',
          'dietary_restrictions': _dietaryList(),
        },
      );
      if (!mounted) return;

      final data = res.data ?? const {};

      // 비라틴 메뉴판: 서버가 분석 대신 'unsupported_language' 신호를 준다 → 구글 렌즈로 유도.
      if ((data['type'] ?? '').toString() == 'unsupported_language') {
        final lang = data['language']?.toString() ?? '';
        setState(() {
          _busy = false;
          _analyzed = true;
          _items = [];
          _recommended = {};
          _message = null;
          _unsupportedLanguage = lang.isEmpty ? '이 언어' : lang;
        });
        return;
      }

      final rawItems = (data['items'] as List?) ?? const [];
      final items = rawItems
          .whereType<Map>()
          .map((e) => _MenuItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      final rec = ((data['recommended'] as List?) ?? const [])
          .map((e) => e.toString())
          .toSet();

      setState(() {
        _busy = false;
        _analyzed = true;
        _items = items;
        _recommended = rec;
        _message = data['message']?.toString();
        _unsupportedLanguage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('분석 실패: $e');
    }
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
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.tripName} · 메뉴판')),
      body: Stack(
        children: [
          Column(
            children: [
              _dietaryCard(),
              Expanded(child: _content()),
            ],
          ),
          if (_busy)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _showSourceSheet,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('메뉴판 찍기'),
      ),
    );
  }

  /// 알레르기 입력 카드 — 재료를 입력해 칩으로 등록한다(다음 촬영부터 추천 제외 +
  /// 메뉴별 알레르기 태그에서 빨갛게 강조). 칩의 X 로 삭제.
  Widget _dietaryCard() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.no_food_outlined, color: scheme.primary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _allergyInput,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addAllergy(),
                      decoration: const InputDecoration(
                        labelText: '알레르기 · 못 먹는 재료',
                        hintText: '예: 갑각류 (입력 후 추가)',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  TextButton(onPressed: _addAllergy, child: const Text('추가')),
                ],
              ),
              if (_allergies.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 30, top: 2),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 0,
                    children: [
                      for (final a in _allergies)
                        Chip(
                          avatar: Icon(Icons.warning_amber_rounded,
                              size: 16, color: scheme.error),
                          label: Text(a),
                          onDeleted: () =>
                              setState(() => _allergies.remove(a)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 본문 — 분석 전 인트로 / 비라틴 안내 / 결과 없음 / 메뉴 목록.
  Widget _content() {
    if (!_analyzed) return _intro();
    if (_unsupportedLanguage != null) return _unsupportedCard();
    if (_items.isEmpty) return _emptyResult();

    final recCount = _recommended.length;
    final myAllergies = _allergies.map((e) => e.toLowerCase()).toSet();
    final hasAllergens = _items.any((it) => it.allergens.isNotEmpty);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      children: [
        if (recCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 16, color: Colors.amber),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'AI 추천 $recCount개 — ⭐ 표시를 참고하세요'
                    '${_dietaryList().isNotEmpty ? ' (${_dietaryList().join(", ")} 제외)' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        for (final it in _items)
          _MenuItemTile(
            item: it,
            recommended: _recommended.contains(it.itemId),
            myAllergies: myAllergies,
          ),
        if (hasAllergens)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 13, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '알레르기 표시는 AI가 일반 조리법으로 추정한 값이에요. '
                    '정확한 정보는 식당에 확인하세요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _intro() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text('메뉴판을 찍어 번역해요',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '아래 "메뉴판 찍기"로 사진 속 메뉴를 한국어로 번역하고,\n'
              '무슨 음식인지 한 줄 설명과 AI 추천(⭐)을 함께 보여줘요.\n'
              '못 먹는 재료를 위에 적으면 추천에서 빼드려요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 비라틴 메뉴판 안내 — 앱 번역이 안 되므로 구글 렌즈로 유도.
  Widget _unsupportedCard() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 14),
            Text("'${_unsupportedLanguage!}'는 앱에서 번역이 불가능해요.",
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('번역 품질이 가장 좋은 구글 렌즈로 검색해 보시겠어요?',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openLens,
              icon: const Icon(Icons.search),
              label: const Text('구글 렌즈로 검색'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openLens() async {
    final ok = await openGoogleLens();
    if (!ok && mounted) _snack('구글 렌즈(구글 앱)를 열지 못했어요.');
  }

  Widget _emptyResult() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 56, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              _message ?? '사진에서 메뉴를 읽지 못했어요. 더 선명하게 다시 찍어주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('또는 구글 렌즈로 검색해 보시겠어요?',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openLens,
              icon: const Icon(Icons.search),
              label: const Text('구글 렌즈로 검색'),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 메뉴 한 항목(카드) — 번역명 + 원문 + 한 줄 설명 + 가격, 추천이면 ⭐
// ──────────────────────────────────────────────────────────────
class _MenuItemTile extends StatelessWidget {
  final _MenuItem item;
  final bool recommended;
  final Set<String> myAllergies; // 소문자 정규화된 내 알레르기(강조용)
  const _MenuItemTile({
    required this.item,
    required this.recommended,
    required this.myAllergies,
  });

  /// 이 메뉴의 알레르기 재료가 내가 등록한 것과 겹치는지(양방향 부분일치로 관대하게).
  bool _isMine(String allergen) {
    final a = allergen.toLowerCase();
    return myAllergies.any((m) => a.contains(m) || m.contains(a));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: recommended ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (recommended)
                  const Padding(
                    padding: EdgeInsets.only(right: 6, top: 2),
                    child: Icon(Icons.star, size: 18, color: Colors.amber),
                  ),
                Expanded(
                  child: Text(
                    item.translatedName.isEmpty
                        ? item.originalName
                        : item.translatedName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                if (item.price != null)
                  Text(_comma(item.price!),
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: scheme.primary)),
              ],
            ),
            if (item.originalName.isNotEmpty &&
                item.originalName != item.translatedName)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(item.originalName,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12)),
              ),
            if (item.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(item.description,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13)),
              ),
            if (item.allergens.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final a in item.allergens) _allergenTag(context, a),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 알레르기 재료 한 칸 — 내가 등록한 것이면 빨갛게(경고 아이콘+굵게) 강조.
  Widget _allergenTag(BuildContext context, String allergen) {
    final scheme = Theme.of(context).colorScheme;
    final mine = _isMine(allergen);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: mine ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: mine ? Border.all(color: scheme.error, width: 1) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mine) ...[
            Icon(Icons.warning_amber_rounded, size: 12, color: scheme.error),
            const SizedBox(width: 3),
          ],
          Text(
            allergen,
            style: TextStyle(
              fontSize: 11,
              color: mine ? scheme.onErrorContainer : scheme.onSurfaceVariant,
              fontWeight: mine ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 모델 (POST /menu 응답 파싱)
// ──────────────────────────────────────────────────────────────
class _MenuItem {
  final String itemId;
  final String originalName;
  final String translatedName;
  final int? price; // 현지 통화 가격(숫자만), 없으면 null
  final String description;
  final List<String> allergens; // 함유 가능성 높은 알레르기 재료(한국어), 없으면 빈 리스트

  const _MenuItem({
    required this.itemId,
    required this.originalName,
    required this.translatedName,
    required this.price,
    required this.description,
    required this.allergens,
  });

  factory _MenuItem.fromJson(Map<String, dynamic> j) => _MenuItem(
        itemId: (j['item_id'] ?? '').toString(),
        originalName: (j['original_name'] ?? '').toString(),
        translatedName: (j['translated_name'] ?? '').toString(),
        price: (j['price'] as num?)?.toInt(),
        description: (j['description'] ?? '').toString(),
        allergens: ((j['allergens'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList(),
      );
}

/// 정수 천 단위 콤마 — 12000 → "12,000".
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
