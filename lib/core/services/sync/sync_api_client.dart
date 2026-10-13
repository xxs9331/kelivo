import 'dart:convert';
import 'package:http/http.dart' as http;
import '../network/dio_http_client.dart';

final class SyncApiException implements Exception {
  const SyncApiException(this.code, this.status);
  final String code;
  final int status;
  @override
  String toString() => 'SyncApiException($code, $status)';
}

final class SyncApiClient {
  SyncApiClient(
    String server, {
    required this.deviceId,
    this.token,
    bool allowLocalHttp = false,
    http.Client? client,
  }) : base = Uri.parse(server),
       _client =
           client ??
           DioHttpClient(
             timeout: const Duration(seconds: 30),
             logRequests: false,
           ) {
    if (base.userInfo.isNotEmpty ||
        base.host.isEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty ||
        (base.scheme != 'https' &&
            !(allowLocalHttp &&
                base.scheme == 'http' &&
                _isPrivateHost(base.host)))) {
      throw const FormatException('sync_requires_https');
    }
  }
  final Uri base;
  final String deviceId;
  final String? token;
  final http.Client _client;
  static bool _isPrivateHost(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      RegExp(r'^10\.\d+\.\d+\.\d+$').hasMatch(host) ||
      RegExp(r'^192\.168\.\d+\.\d+$').hasMatch(host) ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$').hasMatch(host);

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
    final req = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'X-Device-Id': deviceId,
        if (token != null) 'Authorization': 'Bearer $token',
      });
    if (body != null) req.body = jsonEncode(body);
    final streamed = await _client.send(req);
    final bytes = <int>[];
    await for (final chunk in streamed.stream) {
      if (bytes.length + chunk.length > 32 * 1024 * 1024) {
        throw const FormatException('sync_response_too_large');
      }
      bytes.addAll(chunk);
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      var code = 'server_unavailable';
      try {
        code =
            (jsonDecode(utf8.decode(bytes)) as Map)['error']['code'] as String;
      } catch (_) {}
      throw SyncApiException(code, streamed.statusCode);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('invalid_sync_response');
    return Map<String, dynamic>.from(decoded);
  }

  void close() => _client.close();
}
