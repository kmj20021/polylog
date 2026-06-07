import 'package:flutter/material.dart';

import '../../shared/google_lens.dart';

/// 메뉴판 화면 — 구글 렌즈로 안내만 한다(앱 자체 분석 폐지).
///
/// 왜 이렇게 바꿨나: 앱이 사진을 직접 읽어 번역+알레르기를 추정하던 방식은
/// ① 작은 비전 모델 한 콜에 읽기·번역·알레르기 추정을 다 몰아넣어 품질이 들쭉날쭉하고
/// ② 알레르기는 사진에 정보가 없어 '추측'이라 원리상 못 잡으며
/// ③ 환경 제약(권한·배포)으로 더 좋은 도구를 붙이기 어렵다.
/// 반대로 구글 렌즈는 이 용도(실시간 카메라 번역)에 특화돼 모든 언어를 잘 처리한다.
/// → 라틴/비라틴 구분·카메라 촬영·백엔드(/menu) 호출을 모두 없애고, 렌즈로 단일화했다.
class MenuScreen extends StatelessWidget {
  final String tripName;
  const MenuScreen({super.key, required this.tripName});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('$tripName · 메뉴판')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate_outlined, size: 64, color: scheme.primary),
              const SizedBox(height: 16),
              Text('메뉴판은 구글 렌즈로 번역해요',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text(
                '구글 렌즈를 열고 카메라로 메뉴판을 비추면\n'
                '모든 언어를 실시간으로 한국어로 번역해 줘요.\n'
                '사진 글자 인식·번역 품질이 가장 좋아요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => _openLens(context),
                icon: const Icon(Icons.search),
                label: const Text('구글 렌즈 열기'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 구글 렌즈를 연다. context 를 await 너머로 쓰지 않도록 messenger 를 미리 잡아 둔다.
  Future<void> _openLens(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await openGoogleLens();
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('구글 렌즈(구글 앱)를 열지 못했어요.')),
      );
    }
  }
}
