import 'dart:convert';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/services/sync/sync_record.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase a, b;
  late ChatDatabaseRepository ra, rb;
  setUp(() async {
    a = AppDatabase(NativeDatabase.memory());
    b = AppDatabase(NativeDatabase.memory());
    ra = ChatDatabaseRepository(a);
    rb = ChatDatabaseRepository(b);
    await ra.ensureReady();
    await rb.ensureReady();
  });
  tearDown(() async {
    await ra.close();
    await rb.close();
  });

  Future<void> seed(AppDatabase db, String prefix) async {
    await db.customStatement(
      'INSERT INTO conversation_rows(id,title,created_at,updated_at) VALUES (?,?,?,?)',
      ['c', 'chat', 100, 100],
    );
    for (var i = 0; i < 3; i++) {
      final time = (i * 2 + (prefix == 'a' ? 0 : 1) + 1) * 100;
      await db.customStatement(
        'INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order) VALUES (?,?,?,?,?)',
        ['$prefix$i', 'c', 'user', time, i],
      );
      await db.customStatement(
        'INSERT INTO message_part_rows(conversation_id,revision_id,ordinal,kind,payload,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
        [
          'c',
          '$prefix$i',
          0,
          'text',
          jsonEncode({'text': '$prefix$i'}),
          time,
          time,
        ],
      );
    }
  }

  List<SyncRecord> records(Map<String, dynamic> batch) =>
      (batch['records'] as List)
          .map((x) => SyncRecord.fromJson(Map<String, dynamic>.from(x as Map)))
          .toList();

  test(
    'two devices append offline, converge, and replay without echo',
    () async {
      await seed(a, 'a');
      await seed(b, 'b');
      await ra.prepareSync('server');
      await rb.prepareSync('server');
      final fromA = records((await ra.syncOutbox('A'))!);
      final fromB = records((await rb.syncOutbox('B'))!);
      await ra.applySyncRecords(fromB, 'A', cursor: 4);
      await rb.applySyncRecords(fromA, 'B', cursor: 4);
      final before = (await a.select(a.syncChangeLogRows).get()).length;
      await ra.applySyncRecords(fromB, 'A', cursor: 4);
      expect((await a.select(a.syncChangeLogRows).get()).length, before);
      final orderA = await a
          .customSelect(
            'SELECT id,message_order FROM message_rows ORDER BY message_order',
          )
          .get();
      final orderB = await b
          .customSelect(
            'SELECT id,message_order FROM message_rows ORDER BY message_order',
          )
          .get();
      expect(orderA.map((x) => x.data), orderB.map((x) => x.data));
      expect(orderA.map((x) => x.read<String>('id')), [
        'a0',
        'b0',
        'a1',
        'b1',
        'a2',
        'b2',
      ]);
      expect(orderA.map((x) => x.read<int>('message_order')), [
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
    },
  );

  test(
    'durable outbox retry is identical and ack preserves newer local edits',
    () async {
      await seed(a, 'a');
      await ra.prepareSync('server');
      final batch = (await ra.syncOutbox('A'))!;
      await a.customStatement(
        "UPDATE conversation_rows SET title='newer',updated_at=200 WHERE id='c'",
      );
      expect(await ra.syncOutbox('A'), batch);
      await ra.confirmSyncOutbox(batch, {
        'applied': [
          for (final x in batch['records'] as List)
            {
              'kind': x['kind'],
              'id': x['id'],
              'serverSeq': 100,
              'status': 'applied',
            },
        ],
        'superseded': [],
      });
      expect(await ra.syncState('cursor'), isNull);
      final next = (await ra.syncOutbox('A'))!;
      expect((next['records'] as List).single['payload']['title'], 'newer');
    },
  );

  test('deletes propagate without losing unrelated offline messages', () async {
    await seed(a, 'a');
    await ra.prepareSync('server');
    final time = DateTime.now().microsecondsSinceEpoch + 10000;
    await ra.applySyncRecords(
      [
        SyncRecord(
          kind: 'message',
          id: 'a1',
          updatedAt: time,
          originDevice: 'B',
          deleted: true,
        ),
      ],
      'A',
      cursor: 1,
    );
    expect(await ra.getMessage('a1'), isNull);
    expect(await ra.getMessage('a0'), isNotNull);
    expect(await ra.getMessage('a2'), isNotNull);
    await ra.applySyncRecords(
      [
        SyncRecord(
          kind: 'conversation',
          id: 'c',
          updatedAt: time + 1,
          originDevice: 'B',
          deleted: true,
        ),
      ],
      'A',
      cursor: 2,
    );
    expect(await ra.getConversation('c'), isNull);
    expect(await ra.syncState('cursor'), '2');
    expect(
      (await a.select(a.syncChangeLogRows).get()).where(
        (x) => x.kind == 'conversation',
      ),
      isEmpty,
    );
  });

  test('concurrent revisions preserve the selected message identity', () async {
    await seed(a, 'a');
    await seed(b, 'b');
    for (final db in [a, b]) {
      await db.customStatement(
        "UPDATE message_rows SET group_id='g',version=message_order",
      );
    }
    await a.customStatement(
      "UPDATE conversation_rows SET version_selections_json='{\"g\":0}'",
    );
    await b.customStatement(
      "UPDATE conversation_rows SET version_selections_json='{\"g\":1}'",
    );
    await ra.prepareSync('server');
    await rb.prepareSync('server');
    final fromA = records((await ra.syncOutbox('A'))!);
    final fromB = records((await rb.syncOutbox('B'))!);
    await ra.applySyncRecords(fromB, 'A');
    await rb.applySyncRecords(fromA, 'B');
    for (final db in [a, b]) {
      final chosen = await db
          .customSelect(
            "SELECT m.id FROM message_rows m JOIN conversation_rows c ON c.id=m.conversation_id WHERE m.group_id='g' AND m.version=json_extract(c.version_selections_json,'\$.g')",
          )
          .getSingle();
      expect(chosen.read<String>('id'), 'b1');
    }
  });

  test('local reset creates no cross-device delete intent', () async {
    await seed(a, 'a');
    await ra.clearAllData();
    expect(await a.select(a.syncChangeLogRows).get(), isEmpty);
    expect(await a.select(a.tombstoneRows).get(), isEmpty);
  });

  test(
    'remote conversation delete clears a large offline queue without blocking other chats',
    () async {
      await seed(a, 'a');
      await a.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<500)
      INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order)
      SELECT 'offline-' || i,'c','user',(i+1)*100,i+3 FROM n
    ''');
      await a.customStatement(
        "INSERT INTO conversation_rows(id,title,created_at,updated_at) VALUES ('other','Keep me',100,100)",
      );
      await a.customStatement(
        "INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order) VALUES ('unrelated','other','user',100,0)",
      );
      await ra.prepareSync('server');
      await ra.applySyncRecords(
        [
          SyncRecord(
            kind: 'conversation',
            id: 'c',
            updatedAt: DateTime.now().microsecondsSinceEpoch,
            originDevice: 'B',
            deleted: true,
          ),
        ],
        'A',
        cursor: 1,
      );
      final batch = (await ra.syncOutbox('A'))!;
      expect(
        (batch['records'] as List).map((r) => r['id']),
        unorderedEquals(['other', 'unrelated']),
      );
      expect(
        (await a.select(a.syncChangeLogRows).get()).map((r) => r.entityId),
        unorderedEquals(['other', 'unrelated']),
      );
      expect(await ra.getMessage('unrelated'), isNotNull);
    },
  );

  test(
    'ordinary remote edits do not create copies; competing pin edits do',
    () async {
      await seed(a, 'a');
      await ra.prepareSync('server');
      final batch = (await ra.syncOutbox('A'))!;
      final conversation = records(
        batch,
      ).firstWhere((r) => r.kind == 'conversation');
      await ra.confirmSyncOutbox(batch, {
        'applied': [
          for (final r in batch['records'] as List)
            {
              'kind': r['kind'],
              'id': r['id'],
              'serverSeq': 1,
              'status': 'applied',
            },
        ],
        'superseded': [],
      });
      final time = DateTime.now().microsecondsSinceEpoch;
      SyncRecord remote(int updatedAt) => SyncRecord(
        kind: 'conversation',
        id: 'c',
        updatedAt: updatedAt,
        originDevice: 'B',
        payload: {
          ...conversation.payload!,
          'title': 'Remote',
          'isPinned': false,
        },
      );
      await ra.applySyncRecords([remote(time)], 'A');
      expect(await a.select(a.conversationRows).get(), hasLength(1));
      await a.customStatement(
        "UPDATE conversation_rows SET is_pinned=1,updated_at=? WHERE id='c'",
        [time + 1],
      );
      await ra.applySyncRecords([remote(time + 2)], 'A');
      final conversations = await a.select(a.conversationRows).get();
      expect(conversations, hasLength(2));
      expect(conversations.singleWhere((c) => c.id != 'c').isPinned, isTrue);
      await ra.applySyncRecords([remote(time + 2)], 'A');
      expect(await a.select(a.conversationRows).get(), hasLength(2));
    },
  );

  test('failed winner application rolls back outbox confirmation', () async {
    await seed(a, 'a');
    await ra.prepareSync('server');
    final batch = (await ra.syncOutbox('A'))!;
    final sent =
        (batch['records'] as List).firstWhere((r) => r['id'] == 'a0') as Map;
    final winner = Map<String, dynamic>.from(sent)
      ..['originDevice'] = 'B'
      ..['updatedAt'] = DateTime.now().microsecondsSinceEpoch + 10000;
    winner['payload'] = Map<String, dynamic>.from(winner['payload'] as Map)
      ..['conversationId'] = 'missing-parent';
    final response = {
      'applied': [
        for (final r in batch['records'] as List)
          if (r['id'] != 'a0')
            {
              'kind': r['kind'],
              'id': r['id'],
              'serverSeq': 1,
              'status': 'applied',
            },
      ],
      'superseded': [
        {
          'kind': 'message',
          'id': 'a0',
          'serverSeq': 1,
          'status': 'superseded',
          'winner': winner,
        },
      ],
    };
    await expectLater(
      ra.confirmSyncOutbox(batch, response, device: 'A'),
      throwsA(anything),
    );
    expect(await ra.syncOutbox('A'), batch);
    expect((await a.select(a.syncChangeLogRows).get()).length, greaterThan(0));
    expect(await ra.syncState('cursor'), isNull);
  });

  test('streaming blocks an entire pull page and its checkpoint', () async {
    await seed(a, 'a');
    await ra.prepareSync('server');
    final raw = (records(
      (await ra.syncOutbox('A'))!,
    ).firstWhere((x) => x.id == 'a0')).toJson();
    raw['updatedAt'] = DateTime.now().microsecondsSinceEpoch + 10000;
    raw['originDevice'] = 'B';
    await a.customStatement(
      "UPDATE message_rows SET is_streaming=1 WHERE id='a0'",
    );
    await expectLater(
      ra.applySyncRecords([SyncRecord.fromJson(raw)], 'A', cursor: 10),
      throwsStateError,
    );
    expect(await ra.syncState('cursor'), isNull);
    expect(await ra.syncState('applying'), isNull);
  });
}
