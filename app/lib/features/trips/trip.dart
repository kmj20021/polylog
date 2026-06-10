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

  /// 여행 기간의 '날짜 목록'(시작일~종료일, 양끝 포함) — 메인 홈의 날짜 스트립용.
  /// 종료일이 없으면 당일치기로 보고 시작일 하루만. 시작일이 없으면 빈 리스트
  /// (→ 홈은 날짜 스트립을 숨기고 전체 계획을 보여준다).
  List<DateTime> days() {
    final start = DateTime.tryParse(startDate);
    if (start == null) return const [];
    final end = DateTime.tryParse(endDate) ?? start;
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    if (e.isBefore(s)) return [s]; // 잘못된 기간 방어(종료<시작) — 시작일만.
    final out = <DateTime>[];
    for (var d = s; !d.isAfter(e); d = d.add(const Duration(days: 1))) {
      out.add(d);
    }
    return out;
  }

  /// 날짜 → 'YYYY-MM-DD'(계획의 day 매칭·날짜 스트립 공용).
  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 새 계획을 담거나 스트립을 처음 열 때의 '기본 날짜' — 오늘이 기간 안이면 오늘,
  /// 아니면 첫날. 기간 미정이면 ''(날짜 없이 동작).
  String defaultDayYmd() {
    final ds = days();
    if (ds.isEmpty) return '';
    final today = ymd(DateTime.now());
    for (final d in ds) {
      if (ymd(d) == today) return today;
    }
    return ymd(ds.first);
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

  /// '아직 지나지 않은' 계획인가 — '계획' 화면 목록의 필터 기준.
  /// 종료일(없으면 시작일)이 오늘 이후면 true. 날짜가 미정(시작일 없음)이면 true.
  /// 즉 '이미 끝난 여행'만 false 가 되고, 진행 중·미래·날짜 미정은 모두 true.
  bool hasNotPassed([DateTime? now]) {
    final start = DateTime.tryParse(startDate);
    if (start == null) return true; // 날짜 미정 → 아직 안 지난 계획으로 본다
    final end = DateTime.tryParse(endDate) ?? start;
    final today = now ?? DateTime.now();
    // 시/분을 떼고 '날짜'만 비교(마지막 날 당일도 '안 지남'에 포함).
    final d = DateTime(today.year, today.month, today.day);
    final e = DateTime(end.year, end.month, end.day);
    return !e.isBefore(d); // e >= today
  }

  static String _dot(String isoDate) =>
      isoDate.isEmpty ? '' : isoDate.replaceAll('-', '.');
}
