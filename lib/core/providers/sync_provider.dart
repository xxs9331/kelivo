import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../database/business_preferences.dart';
import '../database/chat_database_repository.dart';
import '../services/backup/restore_workspace_lock.dart';
import '../services/backup/backup_activity.dart';
import '../services/chat/chat_service.dart';
import '../services/sync/sync_api_client.dart';
import '../services/sync/sync_engine.dart';

class SyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  SyncProvider({
    required this.repository,
    required this.chat,
    required this.directory,
    required this.businessPreferences,
    required this.backupBusy,
  }) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }
  static const key = 'multi_device_sync_v1';
  final ChatDatabaseRepository repository;
  final ChatService chat;
  final Directory directory;
  final BusinessPreferences businessPreferences;
  final bool Function() backupBusy;
  SharedPreferences? _prefs;
  Map<String, dynamic> _settings = {};
  bool busy = false;
  bool ready = false;
  bool _disposed = false;
  String? error;
  DateTime? lastSync;
  Timer? _timer;
  int _failures = 0;
  Future<void>? _operation;
  String get server => _settings['server'] as String? ?? '';
  String get device => _settings['device'] as String? ?? '';
  bool get paired => _settings['token'] != null;
  bool get enabled => paired && _settings['enabled'] == true;
  bool get allowLocalHttp => _settings['allowLocalHttp'] == true;

  Future<void> _load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs!.getString(key);
      if (saved != null) {
        _settings = Map<String, dynamic>.from(jsonDecode(saved) as Map);
      }
      lastSync = DateTime.tryParse(_settings['lastSync'] as String? ?? '');
    } catch (_) {
      error = 'invalid_local_settings';
    }
    ready = true;
    _notify();
    _schedule(const Duration(seconds: 3));
  }

  Future<void> _save() async {
    if (!await _prefs!.setString(key, jsonEncode(_settings))) {
      throw StateError('sync_settings_write_failed');
    }
  }

  SyncApiClient _api() => SyncApiClient(
    server,
    deviceId: device,
    token: _settings['token'] as String?,
    allowLocalHttp: allowLocalHttp,
  );

  Future<void> pair(String url, String code, {required bool localHttp}) async {
    if (!ready || busy) return;
    busy = true;
    error = null;
    _notify();
    final deviceId = device.isEmpty ? const Uuid().v4() : device;
    SyncApiClient? api;
    try {
      api = SyncApiClient(
        url.trim(),
        deviceId: deviceId,
        allowLocalHttp: localHttp,
      );
      final response = await api.request(
        'POST',
        '/v1/pair/claim',
        body: {
          'code': code.trim(),
          'deviceId': deviceId,
          'deviceName': Platform.localHostname,
          'platform': Platform.operatingSystem,
        },
      );
      final token = response['deviceToken'];
      final id = response['serverId'];
      if (token is! String || token.isEmpty || id is! String || id.isEmpty) {
        throw const FormatException('invalid_pair_response');
      }
      _settings = {
        'server': url.trim(),
        'device': deviceId,
        'token': token,
        'serverId': id,
        'enabled': true,
        'allowLocalHttp': localHttp,
      };
      await _save();
    } catch (e) {
      error = _errorCode(e);
    } finally {
      api?.close();
      busy = false;
      _notify();
    }
    if (paired && error == null) await sync();
  }

  Future<void> disconnect() async {
    if (busy || !ready) return;
    _timer?.cancel();
    _settings = {'device': device};
    lastSync = null;
    error = null;
    await _save();
    await repository.resetSyncConnection();
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (busy) return;
    _settings['enabled'] = value;
    await _save();
    _notify();
    if (value) {
      _schedule(Duration.zero);
    } else {
      _timer?.cancel();
    }
  }

  Future<Map<String, dynamic>> pairingQr() async {
    final api = _api();
    try {
      final code = await api.request('POST', '/v1/pair/code');
      return {'type': 'kelivo-sync', 'server': server, 'code': code['code']};
    } finally {
      api.close();
    }
  }

  Future<void> sync() =>
      _operation ??= _sync().whenComplete(() => _operation = null);
  Future<void> _sync() async {
    if (!ready || !paired || busy || _disposed) return;
    busy = true;
    error = null;
    _notify();
    SyncApiClient? api;
    try {
      if (businessPreferences.writesBlockedForRestore ||
          BackupActivity.isActive ||
          backupBusy()) {
        throw StateError('sync_restore_busy');
      }
      api = _api();
      final lock = RestoreWorkspaceLock(appDataDirectory: directory);
      await lock.synchronized(() async {
        for (final name in [
          RestoreWorkspaceLock.activeRunFileName,
          RestoreWorkspaceLock.publishingRunFileName,
          RestoreWorkspaceLock.discardingRunFileName,
          RestoreWorkspaceLock.archivingRunFileName,
        ]) {
          if (await File('${lock.workspaceRoot.path}/$name').exists()) {
            throw StateError('sync_restore_busy');
          }
        }
        if (await File(
              '${directory.path}/${RestoreWorkspaceLock.snapshotRecoveryMarkerName}',
            ).exists() ||
            businessPreferences.writesBlockedForRestore ||
            BackupActivity.isActive ||
            backupBusy()) {
          throw StateError('sync_restore_busy');
        }
        await SyncEngine(
          repository,
          api!,
          serverId: _settings['serverId'] as String,
          isBlocked: () =>
              businessPreferences.writesBlockedForRestore ||
              BackupActivity.isActive ||
              backupBusy(),
        ).sync();
        if (backupBusy()) throw StateError('sync_restore_busy');
        await chat.refreshAfterSync();
      });
      lastSync = DateTime.now();
      _settings['lastSync'] = lastSync!.toIso8601String();
      await _save();
      _failures = 0;
    } catch (e) {
      error = _errorCode(e);
      _failures++;
      if (e is SyncApiException && e.status == 401) {
        _settings['enabled'] = false;
        await _save();
      }
    } finally {
      api?.close();
      busy = false;
      _notify();
      _schedule(
        Duration(
          seconds: _failures == 0
              ? 60
              : (1 << (_failures.clamp(0, 8))).clamp(1, 300),
        ),
      );
    }
  }

  String _errorCode(Object e) => e is SyncApiException
      ? e.code
      : e is StateError
      ? e.message
      : e is FormatException
      ? e.message
      : 'server_unavailable';
  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_disposed && enabled) _timer = Timer(delay, () => unawaited(sync()));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && enabled) _schedule(Duration.zero);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
