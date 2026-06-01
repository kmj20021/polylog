import 'package:dio/dio.dart';

class DioClient {
  static const String _baseUrl =
      'https://93yxt977xl.execute-api.ap-northeast-2.amazonaws.com/dev';

  static final DioClient _instance = DioClient._internal();
  factory DioClient() => _instance;

  late final Dio dio;
  String? _idToken;

  DioClient._internal() {
    dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));

    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_idToken != null) {
          options.headers['Authorization'] = 'Bearer $_idToken';
        }
        return handler.next(options);
      },
    ));
  }

  void setIdToken(String token) => _idToken = token;
  void clearToken() => _idToken = null;

  Future<Response<T>> get<T>(String path) => dio.get<T>(path);
  Future<Response<T>> post<T>(String path, {Object? data}) =>
      dio.post<T>(path, data: data);
}
