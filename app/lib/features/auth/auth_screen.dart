import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/theme/app_colors.dart';

/// 로그인 화면 — Google 로 로그인한다(ADR-007: Google 단독·Android).
///
/// 'Google로 시작하기'를 누르면 [AuthService.signIn] 을 호출한다. 성공하면
/// `AuthService.signedIn` 이 true 가 되어 [AuthGate] 가 자동으로 메인 셸로 전환하므로,
/// 이 화면은 직접 화면 이동을 하지 않는다(상태 한 곳에서만 흐름을 제어).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  bool _loading = false;

  /// 배경 그라데이션을 파랑↔초록으로 "왔다갔다" 번지게 하는 컨트롤러.
  /// 동작에는 영향 없는 순수 화면 연출이다.
  late final AnimationController _bgController;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bgController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _loading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await AuthService.instance.signIn();
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
            content: Text('로그인이 취소됐거나 토큰을 받지 못했어요.')));
      }
      // 성공 시 AuthGate 가 화면을 전환하므로 여기서 할 일이 없다.
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('로그인 실패: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _bgController,
        builder: (context, child) {
          // 컨트롤러 값(0~1)으로 그라데이션 정렬을 보간해 색이 번지며 오가게 한다.
          final t = _bgController.value;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.lerp(
                    Alignment.topLeft, Alignment.topRight, t)!,
                end: Alignment.lerp(
                    Alignment.bottomRight, Alignment.bottomLeft, t)!,
                colors: const [AppColors.blue, AppColors.mid, AppColors.green],
              ),
            ),
            child: child,
          );
        },
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 흰 원형 카드 위에 로고 — 그라데이션 위에서도 대비를 확보한다.
                  // 로고 자체는 변형·재색칠하지 않는다(CLAUDE.md 3번).
                  Container(
                    width: 132,
                    height: 132,
                    padding: const EdgeInsets.all(14),
                    decoration: const BoxDecoration(
                      color: AppColors.base,
                      shape: BoxShape.circle,
                    ),
                    child: Image.asset('assets/logo/polylog_logo.png'),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Polylog',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                      color: AppColors.base,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'AI 여행 동반자',
                    style: TextStyle(fontSize: 16, color: AppColors.base),
                  ),
                  const SizedBox(height: 48),
                  if (_loading)
                    const CircularProgressIndicator(color: AppColors.base)
                  else
                    FilledButton.icon(
                      onPressed: _signIn,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.base,
                        foregroundColor: AppColors.blue,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                      ),
                      icon: const Icon(Icons.login),
                      label: const Text('Google로 시작하기'),
                    ),
                  // 클라이언트 ID 미주입 시 idToken 이 null 로 와 로그인이 실패하므로 안내.
                  if (!AuthService.instance.hasClientId) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'GOOGLE_CLIENT_ID 가 빌드에 주입되지 않았어요.\n'
                      'flutter run --dart-define=GOOGLE_CLIENT_ID=<웹 클라이언트 ID>',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.base, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
