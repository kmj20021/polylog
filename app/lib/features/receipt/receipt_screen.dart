import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/dio_client.dart';

/// 영수증(지출 기록) 화면 — 현재 여행(tripId)의 영수증 한 장을 사진으로 분석한다.
///
/// 흐름: ① 카메라/갤러리로 영수증 사진 선택 → ② base64 로 만들어 `POST /receipt` 전송
///       → ③ 서버(Textract OCR + Bedrock 구조화 + 환율 환산)가 돌려준 결과를 카드로 표시.
/// 저장은 서버가 polylog-receipts(trip_id)로 처리하므로, 이 화면은 사진을 보내고 결과를
/// 보여주는 일만 한다. (메뉴판 화면도 같은 사진→base64→POST 패턴을 공유한다.)
class ReceiptScreen extends StatefulWidget {
  /// 어느 여행의 지출로 기록할지 — 메인 셸이 '현재 여행'을 주입한다.
  final String tripId;
  final String tripName;
  const ReceiptScreen(
      {super.key, required this.tripId, required this.tripName});

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  final ImagePicker _picker = ImagePicker();

  bool _loading = false;       // 서버 분석 대기 중인지(중복 전송 방지 + 스피너)
  _ReceiptResult? _result;     // 마지막 분석 결과(없으면 안내 화면)

  /// 카메라/갤러리 중 무엇으로 사진을 가져올지 하단 시트로 묻는다.
  Future<void> _pickAndAnalyze(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // maxWidth/imageQuality 로 미리 줄여 전송한다 — Lambda 동기 본문 6MB·
      // Textract 동기 5MB 한도를 넘지 않게 하고 업로드도 빨라진다(영수증 글자엔 1600px면 충분).
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return; // 사용자가 취소

      setState(() => _loading = true);
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
      setState(() {
        _result = _ReceiptResult.fromJson(res.data ?? const {});
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(SnackBar(content: Text('분석 실패: $e')));
    }
  }

  /// 카메라/갤러리 선택 하단 시트.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.tripName} · 영수증')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_result == null ? _intro() : _resultView(_result!)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _showSourceSheet,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('영수증 찍기'),
      ),
    );
  }

  /// 첫 진입(결과 없음) 안내.
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
              '아래 "영수증 찍기"를 누르면 사진 속 품목·금액·통화를 읽어\n'
              '원화로 환산해 보여줘요. (해외 영수증도 OK)',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 분석 결과 — 상단 요약 카드 + 품목 리스트.
  Widget _resultView(_ReceiptResult r) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), // FAB 가림 방지
      children: [
        // ── 요약 카드 ──
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.merchant.isEmpty ? '(가게명 미인식)' : r.merchant,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                if (r.occurredAt.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(r.occurredAt,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                const Divider(height: 24),
                // 원화 환산을 가장 크게 — 사용자가 제일 궁금한 값.
                if (r.totalKrw != null)
                  Text('₩ ${_comma(r.totalKrw!)}',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.primary)),
                if (r.total != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '원본: ${r.total}${r.currency != null ? ' ${r.currency}' : ''}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (r.note != null && r.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: scheme.error),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(r.note!,
                              style: TextStyle(
                                  color: scheme.error, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // ── 품목 리스트 ──
        if (r.items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('품목을 읽지 못했어요.',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          )
        else
          ...r.items.map((it) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(it.nameKo.isEmpty ? '(이름 미인식)' : it.nameKo),
                  subtitle: _CategoryChip(category: it.category),
                  trailing: Text(
                    it.amount ?? '-',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              )),
      ],
    );
  }

  /// 정수에 천 단위 콤마 — 92281 → "92,281".
  String _comma(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// 지출 카테고리 색칠 칩(식비/교통/쇼핑/숙박/관광/기타).
class _CategoryChip extends StatelessWidget {
  final String category;
  const _CategoryChip({required this.category});

  static const Map<String, Color> _colors = {
    '식비': Color(0xFFE57373),
    '교통': Color(0xFF64B5F6),
    '쇼핑': Color(0xFFBA68C8),
    '숙박': Color(0xFF4DB6AC),
    '관광': Color(0xFFFFB74D),
    '기타': Color(0xFF90A4AE),
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[category] ?? _colors['기타']!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(category,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 응답 모델 (서버 POST /receipt 응답을 화면용으로 파싱)
// ──────────────────────────────────────────────────────────────
class _ReceiptResult {
  final String merchant;
  final String occurredAt;
  final String? currency;
  final String? total;
  final int? totalKrw;
  final String? note;
  final List<_ReceiptItem> items;

  const _ReceiptResult({
    required this.merchant,
    required this.occurredAt,
    required this.currency,
    required this.total,
    required this.totalKrw,
    required this.note,
    required this.items,
  });

  factory _ReceiptResult.fromJson(Map<String, dynamic> j) {
    final rawItems = (j['items'] as List?) ?? const [];
    return _ReceiptResult(
      merchant: (j['merchant'] ?? '').toString(),
      occurredAt: (j['occurred_at'] ?? '').toString(),
      currency: j['currency']?.toString(),
      total: j['total']?.toString(),
      totalKrw: (j['total_krw'] as num?)?.toInt(),
      note: j['note']?.toString(),
      items: rawItems
          .whereType<Map>()
          .map((e) => _ReceiptItem.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class _ReceiptItem {
  final String nameKo;
  final String? amount;
  final String category;
  const _ReceiptItem(
      {required this.nameKo, required this.amount, required this.category});

  factory _ReceiptItem.fromJson(Map<String, dynamic> j) => _ReceiptItem(
        nameKo: (j['name_ko'] ?? '').toString(),
        amount: j['amount']?.toString(),
        category: (j['category'] ?? '기타').toString(),
      );
}
