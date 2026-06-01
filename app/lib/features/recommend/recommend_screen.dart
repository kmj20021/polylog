import 'package:flutter/material.dart';
import '../../core/api/dio_client.dart';
import '../../shared/widgets/loading_widget.dart';

class RecommendScreen extends StatefulWidget {
  const RecommendScreen({super.key});

  @override
  State<RecommendScreen> createState() => _RecommendScreenState();
}

class _RecommendScreenState extends State<RecommendScreen> {
  String? _healthResult;
  bool _loading = false;

  Future<void> _checkHealth() async {
    setState(() {
      _loading = true;
      _healthResult = null;
    });
    try {
      final res = await DioClient().get<Map<String, dynamic>>('/health');
      setState(() => _healthResult = '${res.statusCode} OK — ${res.data}');
    } catch (e) {
      setState(() => _healthResult = 'Error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 여행 추천')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('WBS 1.4에서 구현 예정', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 32),
              // E2E 검증용 헬스체크 버튼
              OutlinedButton.icon(
                onPressed: _loading ? null : _checkHealth,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('서버 헬스체크'),
              ),
              const SizedBox(height: 16),
              if (_loading) const LoadingWidget(),
              if (_healthResult != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_healthResult!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
