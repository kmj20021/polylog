import 'package:flutter/painting.dart';

/// 디자인 색상 토큰 — 허용된 4색만 정의한다(CLAUDE.md 2번 규칙).
///
/// 그 외 색(회색·검정·임의 음영 등)은 추가하지 않는다. 중간 톤이 필요하면
/// 산술 평균이 아니라 지정값 [mid] 를 그대로 쓴다.
abstract final class AppColors {
  /// 베이스 — 기본 배경 / 여백 / 텍스트 대비용.
  static const base = Color(0xFFFFFFFF);

  /// 포인트(블루) — 주요 강조색.
  static const blue = Color(0xFF1E98D8);

  /// 중간 톤 — blue ↔ green 이 섞이는 색. 전환·그라데이션·보조 강조에 사용.
  static const mid = Color(0xFF4EC1B6);

  /// 포인트(라이트 그린) — 주요 강조색.
  static const green = Color(0xFFA9E198);
}
