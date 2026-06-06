import 'package:url_launcher/url_launcher.dart';

/// 장소를 '구글 지도'에서 여는 공용 헬퍼.
///
/// 왜 헬퍼로 빼나: 일정 타임라인뿐 아니라 추천 카드·수동 일정(향후)에서도 같은 동작이
/// 필요하다. URL 만드는 규칙을 한곳에 모아 두면 어디서든 한 줄로 재사용한다.
///
/// 동작:
///   - place_id 가 있으면 → 그 장소의 '정확한 페이지'를 연다(구글 공식 URL 스킴:
///     query 로 이름을 주고 query_place_id 로 장소를 특정). AI/추천으로 담은 장소가 해당.
///   - place_id 가 없으면(향후 수동 입력 일정) → 이름(+주소)으로 '지도 검색'을 연다(fallback).
///   - 이름조차 없으면 아무 것도 하지 않고 false.
///
/// 반환: 실제로 외부 앱(지도앱/크롬)이 열렸으면 true, 아니면 false.
/// (호출부가 false 일 때 스낵바로 사용자에게 알릴 수 있게 bool 로 돌려준다.)
Future<bool> openPlaceInMaps({
  required String name,
  String placeId = '',
  String address = '',
}) async {
  final trimmedName = name.trim();
  final trimmedId = placeId.trim();
  final trimmedAddr = address.trim();

  // 검색어: place_id 가 있으면 이름만으로 충분(장소는 id 로 특정). 없으면 주소까지 붙여
  // 동명이인 장소를 줄인다.
  final query = trimmedId.isNotEmpty
      ? trimmedName
      : [trimmedName, trimmedAddr].where((s) => s.isNotEmpty).join(' ');
  if (query.isEmpty) return false; // 열 단서가 전혀 없음

  // 구글 지도 'Universal cross-platform' URL — 웹/안드로이드/iOS 어디서나 동작.
  final params = <String, String>{'api': '1', 'query': query};
  if (trimmedId.isNotEmpty) {
    params['query_place_id'] = trimmedId; // 이게 있으면 검색이 그 장소로 정확히 꽂힌다.
  }
  final uri = Uri.https('www.google.com', '/maps/search/', params);

  // externalApplication: 인앱 웹뷰가 아니라 '지도앱(있으면)이나 크롬'으로 띄운다.
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
