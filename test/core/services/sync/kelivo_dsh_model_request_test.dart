import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/sync/sync_api_client.dart';
import 'package:Kelivo/core/services/sync/sync_engine.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

class _UnusedContext extends Fake implements BuildContext {}

void main() {
  final environment = Platform.environment;
  test('synced DSH replies enter the actual Kelivo model request', () async {
    final url = environment['KELIVO_DSH_SYNC_URL']!;
    final anonymous = SyncApiClient(
      url,
      deviceId: 'kelivo-model-check',
      allowLocalHttp: true,
    );
    addTearDown(anonymous.close);
    final claim = await anonymous.request(
      'POST',
      '/v1/pair/claim',
      body: {
        'deviceId': anonymous.deviceId,
        'deviceName': 'Kelivo test',
        'platform': 'test',
        'code': environment['KELIVO_DSH_PAIR_CODE'],
      },
    );
    final api = SyncApiClient(
      url,
      deviceId: anonymous.deviceId,
      token: claim['deviceToken'] as String,
      allowLocalHttp: true,
    );
    addTearDown(api.close);
    final repository = ChatDatabaseRepository(
      AppDatabase(NativeDatabase.memory()),
    );
    addTearDown(repository.close);
    await repository.ensureReady();
    await SyncEngine(
      repository,
      api,
      serverId: claim['serverId'] as String,
    ).sync();
    final id = environment['KELIVO_DSH_CONVERSATION']!;
    final conversation = (await repository.getConversation(id))!;
    final messages = await repository.getSelectedContextMessages(
      id,
      truncateIndex: conversation.truncateIndex,
      limit: 100,
    );
    final chat = ChatService(existingRepository: repository);
    addTearDown(chat.dispose);
    final body =
        MessageBuilderService(
          chatService: chat,
          chatRepository: repository,
          contextProvider: _UnusedContext(),
        ).buildApiMessages(
          messages: messages,
          versionSelections: conversation.versionSelections,
          currentConversation: conversation,
        );
    body.add({
      'role': 'user',
      'content': 'Continue this conversation on phone',
    });
    Map<String, dynamic>? captured;
    final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => model.close(force: true));
    model.listen((request) async {
      captured = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'id': 'mock-continuation',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'continued'},
              'finish_reason': 'stop',
            },
          ],
        }),
      );
      await request.response.close();
    });
    await ChatApiService.sendMessageStream(
      config: ProviderConfig(
        id: 'MockSync',
        enabled: true,
        name: 'MockSync',
        apiKey: 'mock',
        baseUrl: 'http://127.0.0.1:${model.port}/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'mock',
      messages: body,
      stream: false,
    ).toList();
    final sent = (captured!['messages'] as List).cast<Map>();
    final userMarker = environment['KELIVO_DSH_USER_MARKER']!;
    final assistantMarker = environment['KELIVO_DSH_ASSISTANT_MARKER']!;
    expect(
      sent.any((m) => m['role'] == 'user' && m['content'] == userMarker),
      isTrue,
    );
    expect(
      sent.any(
        (m) => m['role'] == 'assistant' && m['content'] == assistantMarker,
      ),
      isTrue,
    );
    for (final marker in [userMarker, assistantMarker]) {
      expect(
        sent.any(
          (m) => m['role'] == 'assistant' && m['content'] == '上下文里有「$marker」。',
        ),
        isTrue,
        reason: 'The DSH model reply must enter the Kelivo request',
      );
    }
  }, skip: environment['KELIVO_DSH_SYNC_URL'] == null);
}
