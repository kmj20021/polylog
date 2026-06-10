/// 개발·테스트 전용 설정 모음.
///
/// ⚠️ 출시 전 반드시 비활성화(값을 null 로) — 실제 사용자 GPS 를 덮어쓰기 때문.
class DevConfig {
  /// 테스트용 '가짜 현재 위치'.
  ///
  /// null  → 실제 기기 GPS 를 사용(정상 동작).
  /// 값 설정 → GPS 대신 이 좌표를 '현재 위치'로 사용 → 한국에 있어도 그 도시 기준으로
  ///           추천/일정 테스트가 가능하다(실기기에서 GPS 모킹이 어려울 때 유용).
  ///
  /// 현재값: null → 모든 화면이 실제 기기 GPS(현재 위치)를 사용한다.
  // null 로 바꿔 끌 수 있도록 일부러 nullable 로 둔다.
  // ignore: unnecessary_nullable_for_final_variable_declarations
  static const ({double lat, double lng, String label})? mockLocation = null;
}
