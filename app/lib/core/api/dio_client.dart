import 'package:dio/dio.dart';

/// 앱 전역에서 공유하는 단일 Dio 클라이언트.
///
/// baseUrl 은 배포된 API Gateway(dev 스테이지). recommend 는 Bedrock 응답을
/// 기다리므로(Lambda Timeout 30초) receiveTimeout 을 그보다 넉넉히 35초로 둔다.
class DioClient {
  DioClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 35),
        headers: const {'Content-Type': 'application/json'},
      ),
    );
    // 로그인 토큰이 있으면 모든 요청에 Authorization: Bearer 로 붙인다.
    // API Gateway 의 Lambda Authorizer(fn-authorizer)가 이 헤더로 사용자를 검증한다.
    // (서버 강제는 추후 활성화 — 지금은 auth=NONE 이라 헤더가 있어도 무해.)
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = _idToken;
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));
  }

  static final DioClient _instance = DioClient._internal();
  factory DioClient() => _instance;

  static const String baseUrl =
      'https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev';

  late final Dio _dio;

  /// 로그인 시 받은 Google ID 토큰(이후 요청 헤더에 자동 첨부). 로그아웃 시 null.
  String? _idToken;

  /// 로그인 성공 시 호출 — 토큰을 저장한다.
  void setIdToken(String token) => _idToken = token;

  /// 로그아웃 시 호출 — 토큰을 지운다.
  void clearIdToken() => _idToken = null;

  Future<Response<T>> get<T>(String path, {Map<String, dynamic>? queryParameters}) =>
      _dio.get<T>(path, queryParameters: queryParameters);

  Future<Response<T>> post<T>(String path, {Object? data}) =>
      _dio.post<T>(path, data: data);

  Future<Response<T>> delete<T>(String path,
          {Object? data, Map<String, dynamic>? queryParameters}) =>
      _dio.delete<T>(path, data: data, queryParameters: queryParameters);
}
