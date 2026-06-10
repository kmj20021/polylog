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
                child: Center(
                  // 포인트 연두 동그라미로 안내 전체를 감싼다(패널 폭에 맞춘 큰 원).
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final d = c.biggest.shortestSide;
                      const padFrac = 0.09;
                      final inner = d * (1 - padFrac * 2); // 원 안 가용 폭
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
                                    size: 56, color: scheme.primary),
                                const SizedBox(height: 14),
                                // 제목은 한 줄로 — 폭에 맞춰 자동 축소.
                                SizedBox(
                                  width: inner,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text('메뉴판은 구글 렌즈로 번역하기',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  "앱을 열고 카메라로 메뉴판을 찍으면 모든 언어를 실시간으로 "
                                  "한국어 번역이 가능해요!\n궁금한 글자를 눌러 '번역'을 눌러주세요.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: scheme.onSurface, height: 1.4),
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
