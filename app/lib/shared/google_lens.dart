import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 구글 렌즈(카메라 번역)를 여는 공용 헬퍼.
///
/// 왜 필요한가: 비(非)라틴 메뉴판(한국어·일본어·중국어 등)은 앱의 비전 번역 품질이
/// 떨어져, 번역 품질이 가장 좋은 '구글 렌즈'로 사용자를 유도한다(메뉴 화면에서 사용).
///
/// 어떻게: 네이티브(MainActivity)에 만든 채널을 호출해 설치된 렌즈를 **선택창 없이** 곧장
/// 연다(`getLaunchIntentForPackage`/명시적 컴포넌트). 못 열면(미설치 등) false 가 돌아오고,
/// 플레이스토어의 'Google Lens' 설치 페이지로 안내한다. 앱은 안드로이드 전용.
///
/// 반환: 렌즈(또는 폴백 스토어)가 실제로 열렸으면 true.
Future<bool> openGoogleLens() async {
  const channel = MethodChannel('polylog/lens');
  try {
    final ok = await channel.invokeMethod<bool>('openLens') ?? false;
    if (ok) return true;
  } on PlatformException {
    // 무시하고 스토어 폴백.
  } on MissingPluginException {
    // 채널 미등록(구형 빌드 등) → 스토어 폴백.
  }

  // 폴백: market:// 가 있으면 선택창 없이 스토어로, 없으면 https.
  final market = Uri.parse('market://details?id=com.google.ar.lens');
  if (await canLaunchUrl(market)) {
    return launchUrl(market, mode: LaunchMode.externalApplication);
  }
  return launchUrl(
    Uri.parse(
      'https://play.google.com/store/apps/details?id=com.google.ar.lens',
    ),
    mode: LaunchMode.externalApplication,
  );
}
