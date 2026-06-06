/// 여행 1개 — polylog-trips 한 행. 여러 화면이 공유하므로 공개(public) 모델로 둔다.
class Trip {
  final String tripId;
  final String name;
  final String startDate; // 'YYYY-MM-DD'(없을 수 있음)
  final String endDate;

  const Trip({
    required this.tripId,
    required this.name,
    required this.startDate,
    required this.endDate,
  });

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        tripId: (j['trip_id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        startDate: (j['start_date'] ?? '').toString(),
        endDate: (j['end_date'] ?? '').toString(),
      );

  /// 목록에 보여줄 기간 문구: "2026.02.07 - 2026.02.09" / 한쪽만 있으면 그것만 /
  /// 둘 다 없으면 "날짜 미정".
  String get dateRangeLabel {
    final s = _dot(startDate);
    final e = _dot(endDate);
    if (s.isEmpty && e.isEmpty) return '날짜 미정';
    if (e.isEmpty) return s;
    if (s.isEmpty) return e;
    return '$s - $e';
  }

  /// '여행 중'인가 — 오늘 날짜가 [시작일, 종료일] 안에 들면 true.
  /// 종료일이 없으면 당일치기로 보고 시작일과 같은 날로 취급한다. 시작일이 없으면 false.
  bool isOngoing([DateTime? now]) {
    final start = DateTime.tryParse(startDate);
    if (start == null) return false;
    final end = DateTime.tryParse(endDate) ?? start;
    final today = now ?? DateTime.now();
    // 시/분을 떼고 '날짜'만 비교(같은 날도 포함되도록).
    final d = DateTime(today.year, today.month, today.day);
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return !d.isBefore(s) && !d.isAfter(e); // s <= d <= e
  }

  static String _dot(String isoDate) =>
      isoDate.isEmpty ? '' : isoDate.replaceAll('-', '.');
}
