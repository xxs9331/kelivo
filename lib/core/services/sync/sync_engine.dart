import '../../database/chat_database_repository.dart';
import 'sync_api_client.dart';
import 'sync_record.dart';

final class SyncEngine {
  SyncEngine(
    this.repository,
    this.api, {
    required this.serverId,
    this.isBlocked,
  });
  final ChatDatabaseRepository repository;
  final SyncApiClient api;
  final String serverId;
  final bool Function()? isBlocked;

  Future<void> _checkAdmission() async {
    if (isBlocked?.call() == true) {
      throw StateError('sync_restore_busy');
    }
    if (await repository.syncHasStreamingMessages) {
      throw StateError('sync_streaming_busy');
    }
  }

  Future<void>? _running;

  Future<void> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);
  Future<void> _sync() async {
    await _checkAdmission();
    await repository.prepareSync(serverId);
    // Finish the durable in-flight request before allowing pull to replace it.
    final active = await repository.syncState('outbox');
    if (active != null) await _push();
    await _pull();
    // Bound a round so continuous foreground writes cannot starve the app.
    for (var i = 0; i < 20; i++) {
      if (!await _push()) break;
    }
    await _pull();
  }

  Future<bool> _push() async {
    await _checkAdmission();
    final batch = await repository.syncOutbox(api.deviceId);
    if (batch == null) return false;
    final response = await api.request(
      'POST',
      '/v1/changes',
      body: {
        'changeId': batch['changeId'],
        'deviceId': batch['deviceId'],
        'records': batch['records'],
      },
    );
    await _checkAdmission();
    await repository.confirmSyncOutbox(batch, response, device: api.deviceId);
    return true;
  }

  Future<void> _pull() async {
    var cursor = int.parse(await repository.syncState('cursor') ?? '0');
    for (var page = 0; page < 10000; page++) {
      final response = await api.request(
        'GET',
        '/v1/changes',
        query: {'cursor': '$cursor', 'limit': '500'},
      );
      final next = response['nextCursor'];
      final changes = response['changes'];
      final more = response['hasMore'];
      if (next is! int ||
          next < cursor ||
          more is! bool ||
          changes is! List ||
          (more && next == cursor)) {
        throw const FormatException('invalid_sync_page');
      }
      final records = changes
          .map((r) => SyncRecord.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
      var previous = cursor;
      for (final record in records) {
        if (record.serverSeq <= previous || record.serverSeq > next) {
          throw const FormatException('invalid_sync_sequence');
        }
        previous = record.serverSeq;
      }
      await _checkAdmission();
      await repository.applySyncRecords(records, api.deviceId, cursor: next);
      cursor = next;
      if (!more) return;
    }
    throw StateError('sync_round_limit');
  }
}
