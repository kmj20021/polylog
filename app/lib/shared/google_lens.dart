import 'package:android_intent_plus/android_intent.dart';
import 'package:url_launcher/url_launcher.dart';

/// 구글 렌즈(카메라 번역)를 여는 공용 헬퍼.
///
/// 왜 필요한가: 비(非)라틴 메뉴판(한국어·일본어·중국어 등)은 앱의 비전 번역 품질이
/// 떨어져, 번역 품질이 가장 좋은 '구글 렌즈'로 사용자를 유도한다(메뉴 화면에서 사용).
///
/// ⚠️ 렌즈는 설치 형태가 여러 가지다 — ① 독립 'Google Lens' 앱(com.google.ar.lens),
/// ② 구글 앱(googlequicksearchbox) 안의 렌즈 액티비티. 어느 게 깔렸는지 알 수 없으므로
/// **후보를 순서대로 시도**하고, 하나라도 열리면 멈춘다. 다 실패하면 플레이스토어로 안내한다.
/// (url_launcher 로는 특정 앱 액티비티를 못 열어 android_intent_plus 를 쓴다. 앱은 안드로이드 전용.)
///
/// 반환: 렌즈(또는 폴백 스토어)가 실제로 열렸으면 true.
Future<bool> openGoogleLens() async {
  // 1) 독립 'Google Lens' 앱의 런처 화면을 연다(가장 흔한 설치 형태).
  if (await _tryLaunch(const AndroidIntent(
    action: 'android.intent.action.MAIN',
    category: 'android.intent.category.LAUNCHER',
    package: 'com.google.ar.lens',
  ))) {
    return true;
  }

  // 2) 구글 앱 안의 렌즈 액티비티를 명시적 컴포넌트로 연다.
  if (await _tryLaunch(const AndroidIntent(
    action: 'action_view',
    package: 'com.google.android.googlequicksearchbox',
    componentName: 'com.google.android.apps.lens.LensLauncherActivity',
  ))) {
    return true;
  }

  // 3) 폴백: 플레이스토어의 'Google Lens' 설치 페이지(기존 url_launcher 재사용).
  return launchUrl(
    Uri.parse(
      'https://play.google.com/store/apps/details?id=com.google.ar.lens',
    ),
    mode: LaunchMode.externalApplication,
  );
}

/// 인텐트 실행을 시도하고, 대상 앱/액티비티가 없으면(예외) 조용히 false.
Future<bool> _tryLaunch(AndroidIntent intent) async {
  try {
    await intent.launch();
    return true;
  } catch (_) {
    return false;
  }
}
