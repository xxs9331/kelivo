part of 'chat_database_repository.dart';

/// Sync uses the gateway's existing connection and repository serializers.
extension ChatDatabaseSync on ChatDatabaseRepository {
  Future<Map<String, String>> _syncSelectedRevisions(
    String conversation,
  ) async {
    final pending =
        await (_db.select(_db.syncChangeLogRows)
              ..where(
                (r) =>
                    r.kind.equals('conversation') &
                    r.entityId.equals(conversation),
              )
              ..limit(1))
            .getSingleOrNull();
    final saved = await syncState('selection:$conversation');
    if (pending == null && saved != null) {
      return Map<String, String>.from(jsonDecode(saved) as Map);
    }
    final model = await getConversation(conversation);
    final selected = <String, String>{};
    for (final entry
        in model?.versionSelections.entries ?? <MapEntry<String, int>>[]) {
      final row = await _db
          .customSelect(
            'SELECT id FROM message_rows WHERE conversation_id=? AND COALESCE(group_id,id)=? AND version=?',
            variables: [
              Variable(conversation),
              Variable(entry.key),
              Variable(entry.value),
            ],
          )
          .getSingleOrNull();
      if (row != null) selected[entry.key] = row.read<String>('id');
    }
    return selected;
  }

  Future<void> resetSyncConnection() => _db.transaction(() async {
    await _db.delete(_db.syncStateRows).go();
    await _db.delete(_db.syncChangeLogRows).go();
  });
  Future<String?> syncState(String key) async => (await (_db.select(
    _db.syncStateRows,
  )..where((r) => r.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSyncState(String key, String? value) async {
    if (value == null) {
      await (_db.delete(
        _db.syncStateRows,
      )..where((r) => r.key.equals(key))).go();
    } else {
      await _db
          .into(_db.syncStateRows)
          .insertOnConflictUpdate(
            SyncStateRowsCompanion.insert(key: key, value: value),
          );
    }
  }

  Future<bool> get syncHasStreamingMessages async =>
      await (_db.select(_db.messageRows)
            ..where((r) => r.isStreaming.equals(true))
            ..limit(1))
          .getSingleOrNull() !=
      null;

  Future<void> prepareSync(String serverId) => _db.transaction(() async {
    if (await syncState('serverId') == serverId) return;
    await _db.delete(_db.syncStateRows).go();
    await _db.delete(_db.syncChangeLogRows).go();
    await _db.customStatement(
      "INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted) SELECT 'conversation',id,updated_at,0 FROM conversation_rows",
    );
    await _db.customStatement(
      "INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted) SELECT 'message',id,COALESCE(updated_at,timestamp),0 FROM message_rows",
    );
    await _db.customStatement(
      "INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted) SELECT scope,entity_id,deleted_at,1 FROM tombstone_rows WHERE scope IN ('conversation','message')",
    );
    await setSyncState('serverId', serverId);
  });

  Future<SyncRecord?> _syncLocalRecord(
    String kind,
    String id,
    String device,
  ) async {
    final pending =
        await (_db.select(_db.syncChangeLogRows)
              ..where((r) => r.kind.equals(kind) & r.entityId.equals(id))
              ..orderBy([(r) => OrderingTerm.desc(r.localSeq)])
              ..limit(1))
            .getSingleOrNull();
    final stamp = await syncState('record:$kind:$id');
    if (pending == null && stamp != null) {
      return SyncRecord.fromJson(
        Map<String, dynamic>.from(jsonDecode(stamp) as Map),
      );
    }
    if (pending?.deleted == true) {
      return SyncRecord(
        kind: kind,
        id: id,
        updatedAt: pending!.updatedAt,
        originDevice: device,
        deleted: true,
      );
    }
    if (kind == 'conversation') {
      final row = await (_db.select(
        _db.conversationRows,
      )..where((r) => r.id.equals(id))).getSingleOrNull();
      if (row == null) return null;
      final model = await _conversationFromRow(row, includeMessageIds: false);
      final payload = model.toJson()
        ..['messageIds'] = <String>[]
        ..['versionSelections'] = <String, int>{}
        ..['selectedRevisions'] = await _syncSelectedRevisions(id)
        ..['extras'] = <String, dynamic>{};
      return SyncRecord(
        kind: kind,
        id: id,
        updatedAt: pending?.updatedAt ?? row.updatedAt.microsecondsSinceEpoch,
        originDevice: device,
        payload: payload,
      );
    }
    final row = await (_db.select(
      _db.messageRows,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null || row.isStreaming) return null;
    final model = await _messageFromRowWithParts(row);
    final payload = model.toJson()
      ..['senderId'] = row.senderId
      ..['version'] = 0;
    // M1 leaves attachment bytes on the source device. Never send its paths.
    payload['parts'] = [
      for (final part in model.parts)
        if (part is ImagePart || part is FilePart)
          {
            'kind': 'text',
            'payload': TextPart(
              '[Attachment: available on the source device]',
            ).encodePayload(),
          }
        else
          {'kind': part.kind, 'payload': part.encodePayload()},
    ];
    payload['content'] = '';
    return SyncRecord(
      kind: kind,
      id: id,
      updatedAt:
          pending?.updatedAt ??
          (row.updatedAt ?? row.timestamp).microsecondsSinceEpoch,
      originDevice: device,
      payload: payload,
    );
  }

  /// Persist the exact request before sending; a crash retries the same bytes.
  Future<Map<String, dynamic>?> syncOutbox(
    String device,
  ) => _db.transaction(() async {
    final existing = await syncState('outbox');
    if (existing != null) {
      return Map<String, dynamic>.from(jsonDecode(existing) as Map);
    }
    final rows = await _db
        .customSelect(
          'SELECT kind,entity_id,MAX(local_seq) AS seq FROM sync_change_log_rows GROUP BY kind,entity_id ORDER BY CASE kind WHEN \'conversation\' THEN 0 ELSE 1 END,seq LIMIT 500',
        )
        .get();
    final records = <Map<String, dynamic>>[];
    final acks = <Map<String, dynamic>>[];
    var bytes = 0;
    for (final row in rows) {
      final kind = row.read<String>('kind');
      final id = row.read<String>('entity_id');
      final record = await _syncLocalRecord(kind, id, device);
      if (record == null) continue;
      final size = utf8.encode(jsonEncode(record.toJson())).length;
      if (size > 1024 * 1024) throw StateError('sync_payload_too_large');
      if (bytes + size > 14 * 1024 * 1024) break;
      bytes += size;
      records.add(record.toJson());
      acks.add({'kind': kind, 'id': id, 'seq': row.read<int>('seq')});
    }
    if (records.isEmpty) return null;
    final batch = <String, dynamic>{
      'changeId': const Uuid().v4(),
      'deviceId': device,
      'records': records,
      'acks': acks,
    };
    await setSyncState('outbox', jsonEncode(batch));
    return batch;
  });

  Future<void> confirmSyncOutbox(
    Map<String, dynamic> batch,
    Map<String, dynamic> response, {
    String? device,
  }) => _db.transaction(() async {
    if (response['applied'] is! List || response['superseded'] is! List) {
      throw const FormatException('invalid_sync_receipt');
    }
    final winners = <SyncRecord>[];
    for (final entry in response['superseded'] as List) {
      if (entry is! Map ||
          entry['winner'] is! Map ||
          entry['status'] != 'superseded') {
        throw const FormatException('invalid_sync_receipt');
      }
      final winner = SyncRecord.fromJson(
        Map<String, dynamic>.from(entry['winner'] as Map),
      );
      if (winner.kind != entry['kind'] || winner.id != entry['id']) {
        throw const FormatException('invalid_sync_receipt');
      }
      winners.add(winner);
    }
    for (final entry in response['applied'] as List) {
      if (entry is! Map ||
          entry['status'] != 'applied' ||
          entry['serverSeq'] is! int ||
          (entry['serverSeq'] as int) < 1) {
        throw const FormatException('invalid_sync_receipt');
      }
    }
    final receipts = [
      ...response['applied'] as List,
      ...response['superseded'] as List,
    ];
    if (receipts.length != (batch['records'] as List).length) {
      throw const FormatException('invalid_sync_receipt');
    }
    for (final raw in batch['acks'] as List) {
      final ack = Map<String, dynamic>.from(raw as Map);
      final matches = receipts
          .where((r) => r['kind'] == ack['kind'] && r['id'] == ack['id'])
          .toList();
      if (matches.length != 1) {
        throw const FormatException('invalid_sync_receipt');
      }
      await (_db.delete(_db.syncChangeLogRows)..where(
            (r) =>
                r.kind.equals(ack['kind'] as String) &
                r.entityId.equals(ack['id'] as String) &
                r.localSeq.isSmallerOrEqualValue(ack['seq'] as int),
          ))
          .go();
      final sent = (batch['records'] as List).firstWhere(
        (r) => r['kind'] == ack['kind'] && r['id'] == ack['id'],
      );
      await setSyncState(
        'record:${ack['kind']}:${ack['id']}',
        jsonEncode({
          ...sent as Map,
          'payload': sent['deleted'] == true ? null : <String, dynamic>{},
        }),
      );
    }
    if (device != null && winners.isNotEmpty) {
      await applySyncRecords(winners, device);
    }
    await setSyncState('outbox', null);
    // A push acknowledgement is not a pull checkpoint.
  });

  /// All writes and the pull checkpoint commit together.
  Future<void> applySyncRecords(
    List<SyncRecord> records,
    String device, {
    int? cursor,
  }) => _db.transaction(() async {
    await setSyncState('applying', '1');
    final affected = <String>{};
    final selections = <String, Map<String, String>>{};
    final outbox = await syncState('outbox');
    final inFlightConversations = outbox == null
        ? <String>{}
        : {
            for (final record in (jsonDecode(outbox) as Map)['records'] as List)
              if (record['kind'] == 'conversation') record['id'] as String,
          };
    final sorted = [...records]
      ..sort(
        (a, b) => (a.kind == 'conversation' ? 0 : 1).compareTo(
          b.kind == 'conversation' ? 0 : 1,
        ),
      );
    try {
      for (final remote in sorted) {
        final local = await _syncLocalRecord(remote.kind, remote.id, device);
        if (local != null &&
            !remote.newerThan(local) &&
            !(remote.deleted &&
                remote.kind == 'conversation' &&
                !local.deleted)) {
          continue;
        }
        if (remote.kind == 'conversation') {
          if (await (_db.select(_db.messageRows)
                    ..where(
                      (r) =>
                          r.conversationId.equals(remote.id) &
                          r.isStreaming.equals(true),
                    )
                    ..limit(1))
                  .getSingleOrNull() !=
              null) {
            throw StateError('sync_streaming_busy');
          }
          final old = await getConversation(remote.id);
          if (remote.deleted) {
            // Remote cascades must not leave absent revisions blocking the outbox.
            await _db.customStatement(
              "DELETE FROM sync_change_log_rows WHERE kind='message' AND entity_id IN (SELECT id FROM message_rows WHERE conversation_id=?)",
              [remote.id],
            );
            await (_db.delete(
              _db.conversationRows,
            )..where((r) => r.id.equals(remote.id))).go();
          } else {
            if (local?.deleted == true) continue;
            final payload = remote.payload!;
            if (payload['id'] != remote.id) {
              throw const FormatException('invalid_sync_payload');
            }
            final model = Conversation.fromJson(payload);
            final selected = payload['selectedRevisions'];
            if (selected is! Map ||
                selected.keys.any((k) => k is! String) ||
                selected.values.any((v) => v is! String)) {
              throw const FormatException('invalid_sync_selection');
            }
            selections[model.id] = Map<String, String>.from(selected);
            final pending =
                await (_db.select(_db.syncChangeLogRows)
                      ..where(
                        (r) =>
                            r.kind.equals('conversation') &
                            r.entityId.equals(remote.id),
                      )
                      ..limit(1))
                    .getSingleOrNull();
            if (old != null &&
                local != null &&
                local.originDevice == device &&
                (pending != null ||
                    inFlightConversations.contains(remote.id)) &&
                (old.title != model.title ||
                    old.isPinned != model.isPinned ||
                    old.chatModelProvider != model.chatModelProvider ||
                    old.chatModelId != model.chatModelId)) {
              final conflictId = _deterministicMergeId(
                'sync-conversation',
                remote.id,
                '${local.updatedAt}:${local.originDevice}',
              );
              final conflict = old.copyWith(
                id: conflictId,
                title: '${old.title} (conflict)',
                messageIds: [],
                extras: {},
              );
              await _db
                  .into(_db.conversationRows)
                  .insertOnConflictUpdate(_conversationCompanion(conflict));
              await _db
                  .into(_db.syncChangeLogRows)
                  .insert(
                    SyncChangeLogRowsCompanion.insert(
                      kind: 'conversation',
                      entityId: conflictId,
                      updatedAt: conflict.updatedAt.microsecondsSinceEpoch,
                    ),
                  );
            }
            await _db
                .into(_db.conversationRows)
                .insertOnConflictUpdate(
                  _conversationCompanion(
                    model.copyWith(
                      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
                        remote.updatedAt,
                      ),
                      messageIds: [],
                      extras: old?.extras ?? {},
                    ),
                  ),
                );
            await _replaceMcpServers(model.id, model.mcpServerIds);
          }
          affected.add(remote.id);
        } else {
          final oldRow = await (_db.select(
            _db.messageRows,
          )..where((r) => r.id.equals(remote.id))).getSingleOrNull();
          if (oldRow?.isStreaming == true) {
            throw StateError('sync_streaming_busy');
          }
          if (remote.deleted) {
            if (oldRow != null) affected.add(oldRow.conversationId);
            await (_db.delete(
              _db.messageRows,
            )..where((r) => r.id.equals(remote.id))).go();
          } else {
            final payload = remote.payload!;
            if (payload['id'] != remote.id || payload['isStreaming'] != false) {
              throw const FormatException('invalid_sync_payload');
            }
            final message = ChatMessage.fromJson(payload);
            if (oldRow != null &&
                oldRow.conversationId != message.conversationId) {
              throw const FormatException('sync_message_parent_changed');
            }
            final parent = await getConversation(message.conversationId);
            if (parent == null) {
              final parentStamp = await syncState(
                'record:conversation:${message.conversationId}',
              );
              if (parentStamp == null ||
                  !(jsonDecode(parentStamp) as Map)['deleted']) {
                throw StateError('sync_parent_missing');
              }
              continue;
            }
            if (!selections.containsKey(parent.id)) {
              selections[parent.id] = await _syncSelectedRevisions(parent.id);
            }
            // Free a positive order/version before INSERT; constraints prohibit negative staging values.
            final maxOrder = await _db
                .customSelect(
                  'SELECT COALESCE(MAX(message_order),-1)+1 AS n FROM message_rows WHERE conversation_id=?',
                  variables: [Variable(message.conversationId)],
                )
                .getSingle();
            final maxVersion = await _db
                .customSelect(
                  'SELECT COALESCE(MAX(version),-1)+1 AS n FROM message_rows WHERE conversation_id=? AND group_id=?',
                  variables: [
                    Variable(message.conversationId),
                    Variable(message.groupId),
                  ],
                )
                .getSingle();
            var parts = message.parts;
            if (oldRow != null) {
              final oldMessage = await _messageFromRowWithParts(oldRow);
              final attachments = oldMessage.parts
                  .where((p) => p is ImagePart || p is FilePart)
                  .toList();
              if (attachments.isNotEmpty) {
                parts = [
                  ...parts.where(
                    (p) =>
                        p is! TextPart ||
                        p.text !=
                            '[Attachment: available on the source device]',
                  ),
                  ...attachments,
                ];
              }
            }
            final staged = message.copyWith(
              version: maxVersion.read<int>('n'),
              parts: parts,
            );
            await _db
                .into(_db.messageRows)
                .insertOnConflictUpdate(
                  _messageCompanion(staged, maxOrder.read<int>('n')).copyWith(
                    updatedAt: Value(
                      DateTime.fromMicrosecondsSinceEpoch(remote.updatedAt),
                    ),
                    senderId: Value(payload['senderId'] as String?),
                    extrasJson: Value(oldRow?.extrasJson ?? '{}'),
                  ),
                );
            await _replaceMessageParts(staged);
            affected.add(message.conversationId);
          }
        }
        if (remote.deleted) {
          await _db
              .into(_db.tombstoneRows)
              .insertOnConflictUpdate(
                TombstoneRowsCompanion.insert(
                  scope: remote.kind,
                  entityId: remote.id,
                  deletedAt: DateTime.fromMicrosecondsSinceEpoch(
                    remote.updatedAt,
                  ),
                ),
              );
        }
        await setSyncState(
          'record:${remote.kind}:${remote.id}',
          jsonEncode({
            ...remote.toJson(),
            'payload': remote.deleted ? null : <String, dynamic>{},
          }),
        );
        await (_db.delete(_db.syncChangeLogRows)..where(
              (r) => r.kind.equals(remote.kind) & r.entityId.equals(remote.id),
            ))
            .go();
      }
      for (final id in affected) {
        if (selections.containsKey(id)) {
          await setSyncState('selection:$id', jsonEncode(selections[id]));
        }
        await _syncReorder(id);
      }
      if (cursor != null) await setSyncState('cursor', cursor.toString());
    } finally {
      await setSyncState('applying', null);
    }
  });

  Future<void> _syncReorder(String conversation) async {
    await MessageTimelineIndex.install(_db);
    final rows =
        await (_db.select(_db.messageRows)
              ..where((r) => r.conversationId.equals(conversation))
              ..orderBy([
                (r) => OrderingTerm.asc(r.timestamp),
                (r) => OrderingTerm.asc(r.id),
              ]))
            .get();
    if (rows.isEmpty) return;
    final offset =
        rows.map((r) => r.messageOrder).reduce((a, b) => a > b ? a : b) + 1;
    await _db.customStatement(
      'UPDATE message_rows SET message_order=message_order+?,version=version+? WHERE conversation_id=?',
      [
        offset,
        rows.map((r) => r.version).reduce((a, b) => a > b ? a : b) + 1,
        conversation,
      ],
    );
    final versions = <String, int>{};
    final selections = <String, int>{};
    final conv = await getConversation(conversation);
    final stored = await syncState('selection:$conversation');
    final selectedRevisions = stored == null
        ? await _syncSelectedRevisions(conversation)
        : Map<String, String>.from(jsonDecode(stored) as Map);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final group = row.groupId ?? row.id;
      final version = versions.update(group, (v) => v + 1, ifAbsent: () => 0);
      if (selectedRevisions[group] == row.id) {
        selections[group] = version;
      }
      await (_db.update(
        _db.messageRows,
      )..where((r) => r.id.equals(row.id))).write(
        MessageRowsCompanion(messageOrder: Value(i), version: Value(version)),
      );
    }
    if (conv != null) {
      await (_db.update(
        _db.conversationRows,
      )..where((r) => r.id.equals(conversation))).write(
        ConversationRowsCompanion(
          versionSelectionsJson: Value(jsonEncode(selections)),
        ),
      );
    }
    // Existing timeline triggers rebuild the projection; FTS triggers observe part writes.
    await _db.customStatement(
      'UPDATE timeline_state SET ready=0 WHERE conversation_id=?',
      [conversation],
    );
  }
}
