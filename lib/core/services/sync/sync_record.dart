final class SyncRecord {
  const SyncRecord({
    required this.kind,
    required this.id,
    required this.updatedAt,
    required this.originDevice,
    this.deleted = false,
    this.payload,
    this.serverSeq = 0,
  });
  final String kind;
  final String id;
  final int updatedAt;
  final String originDevice;
  final bool deleted;
  final Map<String, dynamic>? payload;
  final int serverSeq;

  factory SyncRecord.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final id = json['id'];
    final time = json['updatedAt'];
    final origin = json['originDevice'];
    final deleted = json['deleted'];
    if (!['conversation', 'message'].contains(kind) ||
        id is! String ||
        id.isEmpty ||
        id.length > 200 ||
        time is! int ||
        time <= 0 ||
        origin is! String ||
        origin.isEmpty ||
        deleted is! bool ||
        (!deleted && json['payload'] is! Map)) {
      throw const FormatException('invalid_sync_record');
    }
    return SyncRecord(
      kind: kind as String,
      id: id,
      updatedAt: time,
      originDevice: origin,
      deleted: deleted,
      payload: json['payload'] == null
          ? null
          : Map<String, dynamic>.from(json['payload'] as Map),
      serverSeq: json['serverSeq'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'updatedAt': updatedAt,
    'originDevice': originDevice,
    'deleted': deleted,
    'payload': payload,
  };

  bool newerThan(SyncRecord other) =>
      updatedAt > other.updatedAt ||
      (updatedAt == other.updatedAt &&
          originDevice.compareTo(other.originDevice) > 0);
}
