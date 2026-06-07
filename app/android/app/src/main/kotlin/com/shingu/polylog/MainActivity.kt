package com.shingu.polylog

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 비라틴 메뉴판을 '구글 렌즈'로 유도할 때, 설치된 렌즈를 **선택창 없이 곧장** 연다.
 *
 * 왜 네이티브로 하나: 특정 앱을 모호함 없이 여는 정석은 PackageManager.getLaunchIntentForPackage
 * 인데, Flutter 플러그인(android_intent_plus 등)은 이를 노출하지 않아 암시적 인텐트로 떨어지고
 * '어느 앱으로 열까' 선택창이 떴다. 여기서 명시적 인텐트로 직접 실행해 그 문제를 없앤다.
 */
class MainActivity : FlutterActivity() {
    private val lensChannel = "polylog/lens"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, lensChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "openLens") {
                    result.success(openLens())
                } else {
                    result.notImplemented()
                }
            }
    }

    /** 설치된 구글 렌즈를 명시적으로 연다. 성공하면 true, 못 열면 false(→ Dart 가 스토어로 폴백). */
    private fun openLens(): Boolean {
        // 1) 독립 'Google Lens' 앱: 패키지의 런처 인텐트(명시적 → 선택창 안 뜸).
        packageManager.getLaunchIntentForPackage("com.google.ar.lens")?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(it)
            return true
        }
        // 2) 구글 앱 내장 렌즈 액티비티(명시적 컴포넌트).
        return try {
            val i = Intent(Intent.ACTION_VIEW)
            i.setClassName(
                "com.google.android.googlequicksearchbox",
                "com.google.android.apps.lens.LensLauncherActivity",
            )
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }
}
