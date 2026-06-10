import 'package:flutter/material.dart';

import '../../core/api/dio_client.dart';
import '../../core/auth/auth_service.dart';

/// '계정 관리' 화면 — 메인 홈 왼쪽 위 버튼으로 들어온다(기존 '다른 여행' 드로어 대체).
///
/// 두 가지를 한다:
///   ① 사용자 취향(선호하는 여행 스타일·분위기·운동·예산·동행)을 골라 서버에 저장한다.
///      AI(추천·플래너)가 나중에 이 취향을 배경지식으로 읽어 개인화하기 위한 토대다
///      (DynamoDB — polylog-users, fn-schedule save_profile/get_profile).
///   ② 계정 관련 동작: '내 여행 관리'(수정·삭제·현재 여행 선택)로 이동 + 로그아웃.
///
/// 취향 스키마는 **프론트가 주인**이다(아래 [_categories]). 백엔드는 받은 맵을 그대로
/// 저장만 하므로, 카테고리를 늘려도 서버를 고칠 필요가 없다.
class AccountScreen extends StatefulWidget {
  /// '내 여행 관리'(TripsScreen) 진입 — 현재 여행 선택/수정/삭제는 메인 셸이 들고 있는
  /// 콜백으로 처리되므로, 그 화면을 여는 일만 부모(MainShell)에 위임한다.
  final VoidCallback onManageTrips;

  const AccountScreen({super.key, required this.onManageTrips});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

/// 한 선호 항목(카테고리)의 정의 — 제목·아이콘·보기 목록·복수선택 여부.
class _Category {
  final String key; // 서버 저장 키
  final String title;
  final IconData icon;
  final List<String> options;
  final bool multi; // true=여러 개 고름, false=하나만
  const _Category(this.key, this.title, this.icon, this.options,
      {required this.multi});
}

const List<_Category> _categories = [
  _Category('travel_styles', '선호하는 여행 스타일', Icons.travel_explore, [
    '관광 위주', '액티비티', '휴양·힐링', '미식', '쇼핑', '자연·풍경', '역사·문화',
  ], multi: true),
  _Category('vibes', '선호하는 분위기', Icons.palette_outlined, [
    '고급스러운', '앤틱·클래식', '모던·세련', '아늑한', '활기찬', '로컬 감성',
  ], multi: true),
  _Category('activities', '좋아하는 운동·활동', Icons.directions_run, [
    '수영', '스쿠버다이빙', '등산', '서핑', '자전거', '골프', '요가', '스키',
  ], multi: true),
  _Category('budget', '예산 수준', Icons.payments_outlined, [
    '가성비', '보통', '프리미엄',
  ], multi: false),
  _Category('companion', '주로 함께 가는 사람', Icons.group_outlined, [
    '혼자', '친구', '연인', '가족(아이 동반)', '부모님',
  ], multi: false),
];

class _AccountScreenState extends State<AccountScreen> {
  bool _loading = true;
  bool _saving = false;
  // 카테고리 key → 선택된 보기 집합. 단일선택도 같은 자료구조로(크기 ≤ 1) 다룬다.
  final Map<String, Set<String>> _sel = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 저장된 취향을 불러와 선택 상태로 푼다(없으면 빈 선택). 실패해도 빈 채로 편집 가능.
  Future<void> _load() async {
    try {
      final res = await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'get_profile'},
      );
      final prefs =
          (res.data?['preferences'] as Map?)?.cast<String, dynamic>() ?? {};
      if (!mounted) return;
      setState(() {
        _sel.clear();
        for (final c in _categories) {
          final v = prefs[c.key];
          if (v is List) {
            _sel[c.key] = v.map((e) => e.toString()).toSet();
          } else if (v is String && v.isNotEmpty) {
            _sel[c.key] = {v};
          } else {
            _sel[c.key] = <String>{};
          }
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        for (final c in _categories) {
          _sel.putIfAbsent(c.key, () => <String>{});
        }
        _loading = false;
      });
    }
  }

  /// 보기 하나를 켜고 끈다. 단일선택은 같은 카테고리의 다른 선택을 비운다.
  void _toggle(_Category c, String opt) {
    setState(() {
      final s = _sel.putIfAbsent(c.key, () => <String>{});
      if (c.multi) {
        if (!s.add(opt)) s.remove(opt); // 있으면 끄고 없으면 켠다
      } else {
        if (s.contains(opt)) {
          s.clear(); // 선택된 걸 다시 누르면 해제
        } else {
          s
            ..clear()
            ..add(opt);
        }
      }
    });
  }

  /// 현재 선택을 통째로 서버에 저장(복수=리스트, 단일=문자열, 빈 항목은 생략).
  Future<void> _save() async {
    final prefs = <String, dynamic>{};
    for (final c in _categories) {
      final s = _sel[c.key] ?? const <String>{};
      if (s.isEmpty) continue;
      prefs[c.key] = c.multi ? s.toList() : s.first;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await DioClient().post<Map<String, dynamic>>(
        '/schedule',
        data: {'action': 'save_profile', 'preferences': prefs},
      );
      messenger.showSnackBar(const SnackBar(content: Text('취향을 저장했어요')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('저장 실패: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 로그아웃 — 확인 후 AuthService.signOut(). 토큰이 지워지고 AuthGate 가 로그인
  /// 화면으로 자동 전환한다(이 화면에서 직접 화면 이동을 하지 않는다).
  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('로그아웃할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('로그아웃')),
        ],
      ),
    );
    if (ok == true) await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('계정 관리'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('저장'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _accountHeader(),
                const SizedBox(height: 8),
                Text('AI가 더 잘 맞는 곳을 추천하도록, 취향을 알려주세요.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                const SizedBox(height: 8),
                for (final c in _categories) _categoryBlock(c),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: const Text('취향 저장'),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.luggage_outlined),
                  title: const Text('내 여행 관리'),
                  subtitle: const Text('여행 선택 · 수정 · 삭제'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onManageTrips,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout,
                      color: Theme.of(context).colorScheme.error),
                  title: Text('로그아웃',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  onTap: _logout,
                ),
              ],
            ),
    );
  }

  /// 로그인한 계정 정보(이름·이메일) — 토큰 미주입 등으로 없으면 안내.
  Widget _accountHeader() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final acc = AuthService.instance.account;
    final name = acc?.displayName ?? '게스트';
    final email = acc?.email ?? '로그인 정보 없음';
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primary,
          child: Icon(Icons.person, color: scheme.onPrimary),
        ),
        title: Text(name,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(email),
      ),
    );
  }

  /// 카테고리 한 블록 — 제목 + 보기 칩들(복수=FilterChip, 단일=ChoiceChip).
  Widget _categoryBlock(_Category c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _sel[c.key] ?? const <String>{};
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(c.icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(c.title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text(c.multi ? '(여러 개)' : '(하나)',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final opt in c.options)
                c.multi
                    ? FilterChip(
                        label: Text(opt),
                        selected: selected.contains(opt),
                        onSelected: (_) => _toggle(c, opt),
                      )
                    : ChoiceChip(
                        label: Text(opt),
                        selected: selected.contains(opt),
                        onSelected: (_) => _toggle(c, opt),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}
