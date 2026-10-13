import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/services/sync/sync_api_client.dart';
import 'package:Kelivo/core/services/sync/sync_engine.dart';

void main() {
  final binary = Platform.environment['KELIVO_SYNC_SERVER_BINARY'];
  test(
    'real Go server: offline edits, incremental sync, deletes and retries',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_sync_http_',
      );
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final path = '${directory.path}/sync.db';
      final process = await Process.start(binary!, [
        '-addr',
        '127.0.0.1:$port',
        '-db',
        path,
      ]);
      process.stdout.drain<void>();
      final diagnostics = process.stderr.transform(utf8.decoder).join();
      int? exitStatus;
      process.exitCode.then((value) => exitStatus = value);
      addTearDown(() async {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode;
        await directory.delete(recursive: true);
      });
      final url = 'http://127.0.0.1:$port';
      final health = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      var ready = false;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (exitStatus == null && DateTime.now().isBefore(deadline)) {
        try {
          final request = await health.getUrl(Uri.parse('$url/health'));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) {
            ready = true;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      health.close();
      if (!ready) {
        process.kill(ProcessSignal.sigterm);
        final status = await process.exitCode;
        fail('Go server did not start (exit $status): ${await diagnostics}');
      }
      Future<({SyncApiClient api, String serverId})> pair(String device) async {
        final code = await Process.run(binary, ['-db', path, 'pair-code']);
        expect(code.exitCode, 0);
        final client = SyncApiClient(
          url,
          deviceId: device,
          allowLocalHttp: true,
        );
        final data = await client.request(
          'POST',
          '/v1/pair/claim',
          body: {
            'code': '${code.stdout}'.trim(),
            'deviceId': device,
            'deviceName': device,
            'platform': 'test',
          },
        );
        client.close();
        final api = SyncApiClient(
          url,
          deviceId: device,
          token: data['deviceToken'] as String,
          allowLocalHttp: true,
        );
        addTearDown(api.close);
        return (api: api, serverId: data['serverId'] as String);
      }

      final pa = await pair('A');
      final pb = await pair('B');
      final da = AppDatabase(NativeDatabase.memory());
      final db = AppDatabase(NativeDatabase.memory());
      final a = ChatDatabaseRepository(da);
      final b = ChatDatabaseRepository(db);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await a.ensureReady();
      await b.ensureReady();
      for (final entry in [(db: da, prefix: 'a'), (db: db, prefix: 'b')]) {
        await entry.db.customStatement(
          "INSERT INTO conversation_rows(id,title,created_at,updated_at) VALUES ('c','chat',100,100)",
        );
        for (var i = 0; i < 3; i++) {
          await entry.db.customStatement(
            'INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order) VALUES (?,?,?,?,?)',
            [
              '${entry.prefix}$i',
              'c',
              'user',
              (i * 2 + (entry.prefix == 'a' ? 0 : 1) + 1) * 100,
              i,
            ],
          );
          await entry.db.customStatement(
            'INSERT INTO message_part_rows(conversation_id,revision_id,ordinal,kind,payload,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
            ['c', '${entry.prefix}$i', 0, 'text', '{"text":"hello"}', 100, 100],
          );
        }
      }
      final ea = SyncEngine(a, pa.api, serverId: pa.serverId);
      final eb = SyncEngine(b, pb.api, serverId: pb.serverId);
      await ea.sync();
      await eb.sync();
      await ea.sync();
      final rowsA = await da
          .customSelect(
            'SELECT id,message_order FROM message_rows ORDER BY message_order',
          )
          .get();
      final rowsB = await db
          .customSelect(
            'SELECT id,message_order FROM message_rows ORDER BY message_order',
          )
          .get();
      expect(rowsA.map((r) => r.data), rowsB.map((r) => r.data));
      expect(rowsA.length, 6);
      final state = await pa.api.request('GET', '/v1/state');
      await Future.wait([ea.sync(), ea.sync()]);
      await eb.sync();
      expect(
        (await pa.api.request('GET', '/v1/state'))['cursor'],
        state['cursor'],
      );
      await a.deleteMessage('a1');
      await ea.sync();
      await eb.sync();
      expect(await b.getMessage('a1'), isNull);
      expect(await b.getMessage('b1'), isNotNull);
      await a.deleteConversation('c');
      await ea.sync();
      await eb.sync();
      expect(await a.getConversation('c'), isNull);
      expect(await b.getConversation('c'), isNull);
      expect(await a.syncState('outbox'), isNull);
      expect(await b.syncState('outbox'), isNull);
    },
    skip: binary == null
        ? 'Set KELIVO_SYNC_SERVER_BINARY to the compiled Go service.'
        : false,
  );
}
