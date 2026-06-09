import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// 블루 상단 바 — 뒤로가기(좌) / 제목 / 로고 아바타(우).
///
/// 레퍼런스(docs/ref-image/chat.jpg)의 상단. 계획·근처 등 '책갈피' 레이아웃 화면이
/// 공유한다(Scaffold 배경이 블루일 때 흰 글씨/아이콘 전제).
class BookmarkTopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const BookmarkTopBar({super.key, required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: '뒤로',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new,
                  color: AppColors.base, size: 20),
            ),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.base,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.base, width: 2),
              ),
              child: const CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.base,
                backgroundImage: AssetImage('assets/logo/polylog_logo.png'),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// 상단에서 '끌어내리는' 책갈피 패널 — 평소엔 접혀([collapsedHeight]) 요약만 보이고,
/// 손잡이(노치)를 아래로 끌거나 탭하면 펼쳐져([expandedHeight]) 전체를 스크롤로 본다.
/// 살짝이라도 끌어내리면 [expandedChild] 로 전환된다(접힘 상태에서만 [collapsedChild]).
///
/// 레퍼런스(docs/ref-image/chat.jpg)의 상단 흰 박스 + 노치. 계획·근처 화면이 공유한다.
class BookmarkPanel extends StatefulWidget {
  final double collapsedHeight;
  final double expandedHeight;
  final Widget collapsedChild; // 접힘: 요약(예: 마지막 1개)
  final Widget expandedChild; // 펼침: 전체

  const BookmarkPanel({
    super.key,
    required this.collapsedHeight,
    required this.expandedHeight,
    required this.collapsedChild,
    required this.expandedChild,
  });

  @override
  State<BookmarkPanel> createState() => _BookmarkPanelState();
}

class _BookmarkPanelState extends State<BookmarkPanel> {
  late double _height = widget.collapsedHeight;
  bool _dragging = false;

  double get _mid => (widget.collapsedHeight + widget.expandedHeight) / 2;

  void _snap(bool expand) => setState(
      () => _height = expand ? widget.expandedHeight : widget.collapsedHeight);

  void _onDragUpdate(DragUpdateDetails d) => setState(() {
        _dragging = true;
        _height = (_height + d.delta.dy)
            .clamp(widget.collapsedHeight, widget.expandedHeight);
      });

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    setState(() => _dragging = false);
    if (v > 240) {
      _snap(true); // 빠르게 아래로
    } else if (v < -240) {
      _snap(false); // 빠르게 위로
    } else {
      _snap(_height >= _mid); // 중간 지점 기준 스냅
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _height.clamp(widget.collapsedHeight, widget.expandedHeight);
    final showFull = h > widget.collapsedHeight + 1;
    return AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      height: h,
      decoration: BoxDecoration(
        color: AppColors.base,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(
                key: ValueKey(showFull),
                child: showFull ? widget.expandedChild : widget.collapsedChild,
              ),
            ),
          ),
          // 손잡이(노치) — 세로 드래그/탭으로 펼침·접힘.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            onTap: () => _snap(h < _mid),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              alignment: Alignment.center,
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.blue.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
