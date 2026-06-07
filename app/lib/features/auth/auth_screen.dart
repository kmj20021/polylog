import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';

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

class _AuthScreenState extends State<AuthScreen> {
  bool _loading = false;

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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.travel_explore, size: 72, color: scheme.primary),
                const SizedBox(height: 16),
                const Text('Polylog',
                    style:
                        TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('AI 여행 동반자',
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 48),
                if (_loading)
                  const CircularProgressIndicator()
                else
                  FilledButton.icon(
                    onPressed: _signIn,
                    icon: const Icon(Icons.login),
                    label: const Text('Google로 시작하기'),
                  ),
                // 클라이언트 ID 미주입 시 idToken 이 null 로 와 로그인이 실패하므로 안내.
                if (!AuthService.instance.hasClientId) ...[
                  const SizedBox(height: 16),
                  Text(
                    'GOOGLE_CLIENT_ID 가 빌드에 주입되지 않았어요.\n'
                    'flutter run --dart-define=GOOGLE_CLIENT_ID=<웹 클라이언트 ID>',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
