import 'package:android_intent_plus/android_intent.dart';
import 'package:url_launcher/url_launcher.dart';

/// 구글 렌즈(라이브 카메라 번역)를 여는 공용 헬퍼.
///
/// 왜 필요한가: 비(非)라틴 메뉴판(한국어·일본어·중국어 등)은 앱의 비전 번역 품질이
/// 떨어져, 사용자를 번역 품질이 가장 좋은 '구글 렌즈'로 유도한다(메뉴 화면에서 사용).
///
/// 동작: 구글 앱(googlequicksearchbox) 안의 렌즈 액티비티를 '명시적 컴포넌트'로 실행한다
///   (url_launcher 로는 특정 앱 액티비티 지정 불가 → android_intent_plus 사용).
///   앱은 안드로이드 전용(ios 폴더 없음)이라 이 경로만 고려한다.
/// 폴백: 구글 앱/렌즈가 없으면 플레이스토어 설치 페이지로 안내(기존 url_launcher 재사용).
///
/// 반환: 렌즈(또는 폴백)가 실제로 열렸으면 true.
Future<bool> openGoogleLens() async {
  const intent = AndroidIntent(
    action: 'action_view', // android.intent.action.VIEW
    package: 'com.google.android.googlequicksearchbox',
    componentName: 'com.google.android.apps.lens.LensLauncherActivity',
  );
  try {
    await intent.launch();
    return true;
  } catch (_) {
    // 구글 앱/렌즈 미설치(혹은 액티비티명 변경) → 플레이스토어로 설치 유도.
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.google.android.googlequicksearchbox',
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
