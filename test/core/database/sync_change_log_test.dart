import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';

void main() {
  late AppDatabase db;
  late ChatDatabaseRepository repo;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = ChatDatabaseRepository(db);
    await repo.ensureReady();
  });
  tearDown(() => repo.close());

  Future<void> create() async {
    await db.customStatement(
      'INSERT INTO conversation_rows(id,title,created_at,updated_at) VALUES (?,?,?,?)',
      ['c', 'chat', 100, 100],
    );
    await db.customStatement(
      'INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order) VALUES (?,?,?,?,?)',
      ['m', 'c', 'user', 200, 0],
    );
  }

  test('all row and part writes tracked; nullable timestamp supported', () async {
    await create();
    var logs = await db.select(db.syncChangeLogRows).get();
    expect(logs.map((r) => r.kind), ['conversation', 'message']);
    expect(logs.last.updatedAt, 200);
    await db.customStatement(
      'INSERT INTO message_part_rows(conversation_id,revision_id,ordinal,kind,payload,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
      [
        'c',
        'm',
        0,
        'text',
        jsonEncode({'text': 'hello'}),
        200,
        200,
      ],
    );
    logs = await db.select(db.syncChangeLogRows).get();
    expect(logs.last.entityId, 'm');
    expect(logs.last.updatedAt, greaterThan(200));
    await db.customStatement('DELETE FROM message_part_rows');
    expect(
      (await db.select(db.syncChangeLogRows).get()).length,
      logs.length + 1,
    );
  });

  test('message deletion and conversation cascade create tombstones', () async {
    await create();
    await db.customStatement("DELETE FROM conversation_rows WHERE id='c'");
    final stones = await db.select(db.tombstoneRows).get();
    expect(
      stones.map((r) => r.scope),
      containsAll(['conversation', 'message']),
    );
    final logs = await db.select(db.syncChangeLogRows).get();
    expect(
      logs.where((r) => r.deleted).map((r) => r.kind),
      containsAll(['conversation', 'message']),
    );
  });

  test('suppression does not echo remote writes or create deletes', () async {
    await db.customStatement(
      "INSERT INTO sync_state_rows VALUES ('applying','1')",
    );
    await create();
    await db.customStatement('DELETE FROM conversation_rows');
    expect(await db.select(db.syncChangeLogRows).get(), isEmpty);
    expect(await db.select(db.tombstoneRows).get(), isEmpty);
    await db.customStatement(
      "DELETE FROM sync_state_rows WHERE key='applying'",
    );
    await create();
    expect((await db.select(db.syncChangeLogRows).get()).length, 2);
  });
}
