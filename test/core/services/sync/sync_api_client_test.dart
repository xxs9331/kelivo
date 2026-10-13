import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:Kelivo/core/services/sync/sync_api_client.dart';

void main() {
  test(
    'HTTPS required; local HTTP needs explicit opt-in; URL has no credentials',
    () {
      for (final url in [
        'http://sync.example.com',
        'https://user:secret@sync.example.com',
        'https://sync.example.com?token=secret',
        'https://sync.example.com#token',
        'http://127.0.0.1:8787',
      ]) {
        expect(() => SyncApiClient(url, deviceId: 'a'), throwsFormatException);
      }
      expect(
        () => SyncApiClient(
          'http://sync.example.com',
          deviceId: 'a',
          allowLocalHttp: true,
        ),
        throwsFormatException,
      );
      final local = SyncApiClient(
        'http://192.168.1.10:8787',
        deviceId: 'a',
        allowLocalHttp: true,
      );
      local.close();
    },
  );

  test(
    'authenticated requests never follow redirects or expose token in errors',
    () async {
      final api = SyncApiClient(
        'https://sync.example.com/base/',
        deviceId: 'a',
        token: 'secret',
        client: MockClient((request) async {
          expect(request.url.path, '/base/v1/state');
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer secret');
          expect(request.headers['X-Device-Id'], 'a');
          return http.Response(
            'redirect',
            307,
            headers: {'Location': 'https://elsewhere.example.com'},
          );
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.request('GET', '/v1/state'),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.status, 'status', 307)
              .having(
                (e) => e.toString(),
                'safe error',
                isNot(contains('secret')),
              ),
        ),
      );
    },
  );
}
