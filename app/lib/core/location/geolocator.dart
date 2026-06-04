import 'package:geolocator/geolocator.dart';

/// 기기의 현재 위치(GPS)를 안전하게 가져오는 서비스.
///
/// 좌표를 얻을 수 없는 모든 경우(서비스 꺼짐·권한 거부)에는 예외 대신
/// null 을 돌려준다 → 화면은 null 을 받으면 텍스트 입력 폴백으로 전환한다.
class LocationService {
  Future<Position?> getCurrentPosition() async {
    // 1) 기기의 위치 서비스(GPS) 자체가 꺼져 있으면 좌표를 얻을 수 없다.
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    // 2) 앱 위치 권한 확인 — 아직 안 물어봤으면(denied) 사용자에게 요청.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    // 요청 후에도 거부(또는 영구 거부)면 좌표 없이 null.
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }
}
