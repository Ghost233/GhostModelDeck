import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/jev_playground.dart';

import 'fixtures/playground_runtime.dart';

void main() {
  test('gateway-created HTTP lease cancelled before admission cannot admit a late request', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final lease = fixture.gateway.leaseJevRequest();
    expect(fixture.gateway.activeOwnedRequests, 1);
    expect(lease.cancel(), true);
    final cancelled = await post(fixture, lease.id);
    expect(cancelled.$1, 409);
    expect(cancelled.$2['error']['code'], 'cancelled');
    expect(fixture.runtime.io.requests, isEmpty);
    await lease.close();
    expect(fixture.gateway.activeOwnedRequests, 0);
    final late = await post(fixture, lease.id);
    expect(late.$1, 404);
    expect(late.$2['error']['code'], 'unknown_owned_request');
    expect(fixture.runtime.io.requests, isEmpty);
  });
  test('missing, unknown and duplicate handles never consume or cancel another owned request', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final ordinary = await post(fixture, null);
    expect(ordinary.$1, 200);
    expect(ordinary.$2['model'], 'quick');
    fixture.runtime.io.requests.clear();
    expect((await post(fixture, 'unknown')).$1, 404);
    final lease = fixture.gateway.leaseJevRequest();
    final malformed = await post(
      fixture,
      lease.id,
      duplicate: [lease.id, lease.id],
    );
    expect(malformed.$1, 400);
    expect(fixture.gateway.activeOwnedRequests, 1);
    expect(fixture.runtime.io.requests, isEmpty);
    final held = Completer<void>(), arrived = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    fixture.runtime.io.respond = (body, raw) async {
      if (!arrived.isCompleted) arrived.complete();
      await held.future;
      return raw;
    };
    final pending = post(fixture, lease.id);
    await arrived.future.timeout(const Duration(seconds: 5));
    final duplicate = await post(fixture, lease.id);
    expect(duplicate.$1, 409);
    expect(duplicate.$2['error']['code'], 'duplicate_owned_request');
    expect(
      fixture.runtime.engine.state.instances.fold<int>(
        0,
        (sum, i) => sum + i.activeRequests,
      ),
      1,
    );
    lease.cancel();
    final cancelled = await pending.timeout(const Duration(seconds: 1));
    expect(cancelled.$1, 409);
    expect(cancelled.$2['error']['code'], 'cancelled');
    expect(cancelled.$2.containsKey('answers'), false);
    await lease.close();
    expect(fixture.gateway.activeOwnedRequests, 0);
    held.complete();
    expect(fixture.runtime.io.killedChildren, 0);
  });

  test('completed HTTP response wins over a later lease cancel and releases exactly once', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final lease = fixture.gateway.leaseJevRequest();
    final received = await post(fixture, lease.id);
    expect(received.$1, 200);
    expect(received.$2['answers']['route']['choice'], 'b');
    expect(lease.cancel(), false);
    await Future.wait([lease.close(), lease.close()]);
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect((await post(fixture, lease.id)).$1, 404);
    expect((await post(fixture, null)).$1, 200);
    expect(fixture.runtime.io.killedChildren, 0);
  });

  test(
    'an already cancelled protocol call has no invented received JSON or lease',
    () async {
      final fixture = await PlaygroundRuntime.create();
      addTearDown(fixture.close);
      final token = DecisionCancellation()..cancel();
      for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
        final result = await fixture.playground.run(
          mode,
          jsonEncode(playgroundDocument('quick', debug: true)),
          cancellation: token,
        );
        expect(result.status, JevPlaygroundStatus.cancelled);
        expect(result.output, isNull);
        expect(result.debug, isNull);
        expect(result.message, contains('未收到业务结果'));
      }
      expect(fixture.gateway.activeOwnedRequests, 0);
      expect(fixture.runtime.io.requests, isEmpty);
    },
  );

  test('cancel and close during a partial body drains before any model admission', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    final body = utf8.encode(jsonEncode(playgroundDocument('quick')));
    for (var attempt = 0; attempt < 3; attempt++) {
      final lease = fixture.gateway.leaseJevRequest();
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        fixture.gateway.baseUrl!.port,
      );
      final subscription = socket.listen((_) {}, onError: (Object _) {});
      try {
        socket.write(
          'POST /v1/systemone HTTP/1.1\r\nHost: 127.0.0.1:${fixture.gateway.baseUrl!.port}\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\n${PublicGatewayServer.ownedRequestHeader}: ${lease.id}\r\n\r\n',
        );
        await socket.flush();
        socket.add(body.take(5).toList());
        await socket.flush();
        // A real duplicate reply establishes header attachment while the first body is incomplete.
        final duplicate = await post(
          fixture,
          lease.id,
        ).timeout(const Duration(seconds: 5));
        expect(duplicate.$2['error']['code'], 'duplicate_owned_request');
        lease.cancel();
        socket.destroy();
        await lease.close().timeout(const Duration(seconds: 1));
        expect(fixture.gateway.activeOwnedRequests, 0);
        expect(fixture.runtime.io.requests, isEmpty);
      } finally {
        socket.destroy();
        await subscription.cancel();
        await lease.close();
      }
    }
    final neverConnected = fixture.gateway.leaseJevRequest();
    await neverConnected.close();
    expect((await post(fixture, neverConnected.id)).$1, 404);
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(fixture.gateway.state, PublicGatewayState.running);
    expect(fixture.runtime.io.killedChildren, 0);
  });

  test('owned parsing failures and unconnected shutdown leases leave no registry or permits', () async {
    final fixture = await PlaygroundRuntime.create();
    addTearDown(fixture.close);
    for (final invalid in [
      '{broken',
      jsonEncode({...playgroundDocument('unknown')}),
    ]) {
      final lease = fixture.gateway.leaseJevRequest();
      final rejected = await post(fixture, lease.id, raw: invalid);
      expect(rejected.$1, invalid == '{broken' ? 400 : 404);
      expect(rejected.$2.containsKey('answers'), false);
      await lease.close();
      expect(fixture.gateway.activeOwnedRequests, 0);
    }
    expect(fixture.runtime.io.requests, isEmpty);
    final first = fixture.gateway.leaseJevRequest(),
        second = fixture.gateway.leaseJevRequest();
    await fixture.gateway.stop().timeout(const Duration(seconds: 1));
    await Future.wait([first.close(), second.close()]);
    expect(fixture.gateway.activeOwnedRequests, 0);
    expect(
      fixture.runtime.engine.state.instances.every(
        (i) => i.activeRequests == 0,
      ),
      true,
    );
    expect(fixture.runtime.io.killedChildren, 0);
  });
}

Future<(int, Map)> post(
  PlaygroundRuntime fixture,
  String? handle, {
  List<String>? duplicate,
  String? raw,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      fixture.gateway.baseUrl!.resolve('/v1/systemone'),
    );
    request.headers.contentType = ContentType.json;
    if (handle != null) {
      request.headers.set(
        PublicGatewayServer.ownedRequestHeader,
        duplicate ?? handle,
      );
    }
    request.write(raw ?? jsonEncode(playgroundDocument('quick', debug: true)));
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join()) as Map,
    );
  } finally {
    client.close(force: true);
  }
}
