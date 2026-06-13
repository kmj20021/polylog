import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../shared/bookmark_panel.dart';
import '../../shared/feature_nav.dart';
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

  /// 기능 화면끼리 이동할 때 같은 여행 맥락을 넘기기 위한 값(메뉴 화면 자체는 안 씀).
  final String tripId;
  final String day;
  const MenuScreen({
    super.key,
    required this.tripName,
    this.tripId = '',
    this.day = '',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            BookmarkTopBar(
              title: tripName,
              onBack: () => Navigator.of(context).maybePop(),
              onLogoTap: () => showFeatureNavMenu(
                context,
                tripId: tripId,
                tripName: tripName,
                day: day,
                current: FeatureDest.menu,
              ),
            ),
            // 큰 흰 라운드 패널 — 안내 + 구글 렌즈 열기(다른 기능 화면과 같은 디자인).
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  color: AppColors.base,
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(24)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
                  child: Column(
                    children: [
                      // 상단 헤더 — 비어 보이던 윗공간을 안내로 채운다.
                      Text('메뉴판, 사진으로 번역하기',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Text(
                        '낯선 나라의 메뉴판도 걱정 마세요.\n'
                        '카메라로 비추면 모든 언어를 실시간으로 한국어로 바꿔드려요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, height: 1.5),
                      ),
                      const SizedBox(height: 24),
                      // 포인트 연두 동그라미 — 헤더 바로 아래에 붙인다(위쪽 정렬).
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final d = c.biggest.shortestSide;
                              const padFrac = 0.1;
                              return Container(
                                width: d,
                                height: d,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.green,
                                ),
                                padding: EdgeInsets.all(d * padFrac),
                                child: Center(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.translate_outlined,
                                            size: 64, color: scheme.primary),
                                        const SizedBox(height: 16),
                                        Text(
                                          "궁금한 글자를 눌러 '번역'을 누르면 돼요.",
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: scheme.onSurface,
                                              height: 1.4),
                                        ),
                                        const SizedBox(height: 20),
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
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
