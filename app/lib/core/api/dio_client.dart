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
  }

  static final DioClient _instance = DioClient._internal();
  factory DioClient() => _instance;

  static const String baseUrl =
      'https://mvlllsq6xj.execute-api.ap-northeast-2.amazonaws.com/dev';

  late final Dio _dio;

  Future<Response<T>> get<T>(String path, {Map<String, dynamic>? queryParameters}) =>
      _dio.get<T>(path, queryParameters: queryParameters);

  Future<Response<T>> post<T>(String path, {Object? data}) =>
      _dio.post<T>(path, data: data);

  Future<Response<T>> delete<T>(String path,
          {Object? data, Map<String, dynamic>? queryParameters}) =>
      _dio.delete<T>(path, data: data, queryParameters: queryParameters);
}
