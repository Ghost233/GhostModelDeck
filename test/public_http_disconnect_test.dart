import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('ordinary HTTP disconnect releases only its JEV request before inference returns', () async {
    final fixture = await PlaygroundRuntime.create();
    final held = Completer<void>();
    final arrived = Completer<void>();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      if (!held.isCompleted) held.complete();
      await fixture.close();
    });
    fixture.runtime.io.respond = (body, result) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return result;
    };
    final request = await client.postUrl(
      fixture.gateway.baseUrl!.resolve('/v1/systemone'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(playgroundDocument('native-kev')));
    final response = request.close().then<void>((_) {}, onError: (Object _) {});
    await arrived.future.timeout(const Duration(seconds: 3));
    expect(
      fixture.runtime.engine.state.instances.fold<int>(
        0,
        (sum, instance) => sum + instance.activeRequests,
      ),
      1,
    );
    client.close(force: true);
    final limit = DateTime.now().add(const Duration(seconds: 3));
    while (fixture.runtime.engine.state.instances.any(
      (instance) => instance.activeRequests != 0,
    )) {
      if (DateTime.now().isAfter(limit)) {
        fail(
          'A normal client disconnect did not cancel inference before external IO returned',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(held.isCompleted, false);
    await response;
  });
}
