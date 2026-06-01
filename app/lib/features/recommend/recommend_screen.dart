import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';

/// AI 장소 추천 화면.
///
/// 여행지 + 카테고리를 입력해 POST /recommend 를 호출하고,
/// Bedrock Claude 3 Haiku 가 생성한 추천 텍스트를 카드로 표시한다.
class RecommendScreen extends StatefulWidget {
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  final _locationController = TextEditingController();
  static const _categories = ['맛집', '숙소', '관광지', '카페'];
  String _category = '맛집';

  bool _loading = false;
  String? _error;
  String? _recommendation;
  String? _resultHeader;

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final location = _locationController.text.trim();
    if (location.isEmpty) {
      setState(() => _error = '여행지를 입력해 주세요.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _recommendation = null;
    });

    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/recommend',
        data: {'location': location, 'category': _category},
      );
      final data = res.data ?? const {};
      setState(() {
        _resultHeader = '${data['location']} · ${data['category']}';
        _recommendation = (data['recommendation'] ?? '').toString();
      });
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = (body is Map && body['error'] != null)
          ? body['error']
          : (e.message ?? '네트워크 오류');
      setState(() => _error = 'AI 추천을 불러오지 못했어요.\n$msg');
    } catch (e) {
      setState(() => _error = '알 수 없는 오류: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
            TextField(
              controller: _locationController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _loading ? null : _fetch(),
              decoration: const InputDecoration(
                labelText: '여행지',
                hintText: '예: 도쿄 신주쿠',
                prefixIcon: Icon(Icons.place_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _loading ? null : _fetch,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_loading ? '추천 생성 중…' : 'AI 추천받기'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 24),
            if (_error != null) _ErrorCard(message: _error!),
            if (_recommendation != null)
              _ResultCard(
                header: _resultHeader ?? '',
                body: _recommendation!,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final String header;
  final String body;
  final Color color;
  const _ResultCard({
    required this.header,
    required this.body,
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
            SelectableText(
              body,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
            ),
          ],
        ),
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
