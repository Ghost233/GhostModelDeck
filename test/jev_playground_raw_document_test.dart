import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/frozen_question_suite.dart';
import 'package:ghost_model_deck/jev_playground.dart';
import 'package:ghost_model_deck/public_gateway.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  for (final mode in JevPlaygroundMode.values) {
    test(
      'original unsupported fields reach the ordinary $mode validator',
      () async {
        final fixture = await PlaygroundRuntime.create();
        addTearDown(fixture.close);
        final document = playgroundDocument('native-kev');
        final questions = document['questions'] as Map;
        (questions['route'] as Map)['published_extra'] =
            'original attack field';
        final original = jsonEncode(document);
        final locallyRejected = await fixture.playground.run(mode, original);
        expect(locallyRejected.rawResponse, isNull);
        expect(locallyRejected.httpStatus, isNull);
        final delivered = await fixture.playground.run(
          mode,
          original,
          validateBeforeSend: false,
        );
        expect(delivered.status, JevPlaygroundStatus.businessError);
        expect(
          delivered.httpStatus,
          mode == JevPlaygroundMode.http ? 400 : null,
        );
        expect(delivered.rawResponse, isNotNull);
        expect(
          delivered.output!['error'],
          containsPair('code', 'invalid_input'),
        );
        expect(delivered.requestBody, original);
        expect(fixture.runtime.io.requests, isEmpty);
      },
    );
  }
  test(
    'ordinary HTTP preserves original JSON escapes and actual wire evidence',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final forwarding = HttpClient();
      addTearDown(() => forwarding.close(force: true));
      String? received;
      var ownedHeader = false;
      final subscription = proxy.listen((incoming) async {
        received = await utf8.decoder.bind(incoming).join();
        ownedHeader =
            incoming.headers.value(PublicGatewayServer.ownedRequestHeader) !=
            null;
        final request = await forwarding.postUrl(
          fixture.gateway.baseUrl!.resolve('/v1/systemone'),
        );
        request.headers.contentType = ContentType.json;
        request.write(received);
        final response = await request.close();
        incoming.response.statusCode = response.statusCode;
        incoming.response.headers.contentType = ContentType.json;
        await incoming.response.addStream(response);
        await incoming.response.close();
      });
      addTearDown(subscription.cancel);
      final body = playgroundDocument('native-kev')..remove('model');
      final originalQuestions = jsonEncode(body['questions'])
          .replaceFirst('"Choose"', r'"\u0043hoose"');
      final task = FrozenQuestionTask(
        id: 'original-escape',
        body: body,
        metadata: const {},
        questionsJson: originalQuestions,
      );
      final document = task.requestDocument('native-kev');
      expect(document, contains(r'\u0043'));
      final client = JevPlayground(
        gateway: _ForwardingGateway(
          fixture,
          Uri.parse('http://127.0.0.1:${proxy.port}'),
        ),
        mcp: fixture.mcp,
      );
      final result = await client.run(JevPlaygroundMode.http, document);
      expect(result.status, JevPlaygroundStatus.success);
      expect(ownedHeader, isFalse);
      expect(received, document);
      expect(result.requestBody, received);
      expect(result.request, task.request('native-kev'));
    },
  );
}

class _ForwardingGateway extends PublicGatewayServer {
  _ForwardingGateway(PlaygroundRuntime fixture, this.endpoint)
    : super(routes: fixture.routes, jevModels: fixture.council.models);

  final Uri endpoint;

  @override
  PublicGatewayState get state => PublicGatewayState.running;

  @override
  Uri get baseUrl => endpoint;
}
