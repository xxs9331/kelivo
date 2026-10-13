import 'package:drift/drift.dart';

/// Triggers observe all write paths; remote apply and local reset suppress them
/// inside their database transaction, so unrelated local writes are not lost.
final class SyncTracking {
  static const suppressed =
      "COALESCE((SELECT value FROM sync_state_rows "
      "WHERE key='applying'),'0')='1'";
  static const clock =
      "CAST((julianday('now')-2440587.5)*86400000000 AS INTEGER)";

  static Future<void> install(GeneratedDatabase db) async {
    for (final kind in ['conversation', 'message']) {
      final table = '${kind}_rows';
      final stamp = kind == 'message'
          ? 'COALESCE(NEW.updated_at,NEW.timestamp)'
          : 'NEW.updated_at';
      for (final op in ['INSERT', 'UPDATE']) {
        await db.customStatement('''
CREATE TRIGGER IF NOT EXISTS sync_${kind}_${op.toLowerCase()}
AFTER $op ON $table WHEN NOT ($suppressed)
BEGIN
  INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted)
  VALUES ('$kind',NEW.id,$stamp,0);
END
''');
      }
      final oldStamp = kind == 'message'
          ? 'COALESCE(OLD.updated_at,OLD.timestamp)'
          : 'OLD.updated_at';
      await db.customStatement('''
CREATE TRIGGER IF NOT EXISTS sync_${kind}_delete
AFTER DELETE ON $table WHEN NOT ($suppressed)
BEGIN
  INSERT INTO tombstone_rows(scope,entity_id,deleted_at,payload)
  VALUES ('$kind',OLD.id,MAX($clock,$oldStamp+1),'{}')
  ON CONFLICT(scope,entity_id) DO UPDATE SET deleted_at=MAX(deleted_at,excluded.deleted_at);
END
''');
    }
    for (final op in ['INSERT', 'UPDATE']) {
      await db.customStatement('''
CREATE TRIGGER IF NOT EXISTS sync_tombstone_${op.toLowerCase()}
AFTER $op ON tombstone_rows
WHEN NOT ($suppressed) AND NEW.scope IN ('conversation','message')
BEGIN
  INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted)
  VALUES (NEW.scope,NEW.entity_id,NEW.deleted_at,1);
END
''');
    }
    for (final table in [
      'message_part_rows',
      'message_prompt_rows',
      'message_asset_rows',
    ]) {
      const key = 'revision_id';
      for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
        final row = op == 'DELETE' ? 'OLD' : 'NEW';
        await db.customStatement('''
CREATE TRIGGER IF NOT EXISTS sync_${table}_${op.toLowerCase()}
AFTER $op ON $table WHEN NOT ($suppressed)
BEGIN
  INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted)
  SELECT 'message',id,MAX($clock,COALESCE(updated_at,timestamp)+1),0
  FROM message_rows WHERE id=$row.$key;
END
''');
      }
    }
    for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
      final row = op == 'DELETE' ? 'OLD' : 'NEW';
      await db.customStatement('''
CREATE TRIGGER IF NOT EXISTS sync_mcp_${op.toLowerCase()}
AFTER $op ON conversation_mcp_server_rows WHEN NOT ($suppressed)
BEGIN
  INSERT INTO sync_change_log_rows(kind,entity_id,updated_at,deleted)
  SELECT 'conversation',id,MAX($clock,updated_at+1),0
  FROM conversation_rows WHERE id=$row.conversation_id;
END
''');
    }
  }
}
