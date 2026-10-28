import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/generation_configuration.dart';
import 'package:ghost_model_deck/generation_seed.dart';
import 'package:ghost_model_deck/prefill_operation_ledger.dart';
import 'package:ghost_model_deck/public_prefill_request.dart';
import 'package:ghost_model_deck/splash_operation_client.dart';

void main() {
  test(
    'large exact seed remains an integer in the native prefill request',
    () async {
      final decoded = decodeGenerationRequest(
        '{"model":"model","cache_salt":"scope",'
        '"messages":[{"role":"user","content":"A"}],"max_tokens":0,"seed":18446744073709551615}',
      ) as Map;
      final request = PublicPrefillRequest.parse(
        SplashOperationPath.chat,
        Map<String, Object?>.from(decoded),
      );
      expect(request.body['seed'], isA<ExactGenerationSeed>());
      final native = request.toSplash(nativeModel: 'native');
      final encoded = encodeGenerationRequest(native);
      expect(encoded, contains('"seed":18446744073709551615'));
      expect(encoded, isNot(contains('"seed":"18446744073709551615"')));
      final root = await Directory.systemTemp.createTemp(
        'gmd-prefill-exact-seed-',
      );
      addTearDown(() => root.delete(recursive: true));
      final ledger = await PrefillOperationLedger.open(
        File('${root.path}/ledger.json'),
        wallClock: () => 1000000,
      );
      addTearDown(ledger.close);
      final generation = 'generation';
      final id =
          'gmd1.${sha256.convert(utf8.encode(generation))}.1000000.${'a' * 32}';
      expect(
        (await ledger.admit(
          operationId: id,
          token: 'a' * 64,
          model: request.model,
          owner: 'owner',
          generation: generation,
          cacheSalt: request.cacheSalt,
          request: request.body,
          kind: request.kind,
        )).created,
        isTrue,
      );
      final changed = PublicPrefillRequest.parse(
        SplashOperationPath.chat,
        Map<String, Object?>.from(
          decodeGenerationRequest(
            '{"model":"model","cache_salt":"scope","messages":[{"role":"user","content":"A"}],'
            '"max_tokens":0,"seed":18446744073709551614}',
          ) as Map,
        ),
      );
      await expectLater(
        ledger.admit(
          operationId: id,
          token: 'a' * 64,
          model: changed.model,
          owner: 'owner',
          generation: generation,
          cacheSalt: changed.cacheSalt,
          request: changed.body,
          kind: changed.kind,
        ),
        throwsA(isA<PrefillOperationConflict>()),
      );
    },
  );

  test(
    'chat prefill validates zero budget without weakening final generation',
    () {
      final input = <String, Object?>{
        'model': 'model',
        'messages': [
          {'role': 'user', 'content': '材料'},
        ],
        'max_tokens': 0,
        'stream': false,
        'cache_salt': 'scope',
      };
      final prefill = PublicPrefillRequest.parse(
        SplashOperationPath.chat,
        input,
      );
      expect(prefill.kind, PrefillOperationKind.prefill);
      expect(prefill.body['max_tokens'], 0);
      expect(prefill.cacheSalt, 'scope');
      final native = prefill.toSplash(
        nativeModel: 'splash-runtime',
        defaults: GenerationConfiguration({
          'max_tokens': 256,
          'temperature': 0.4,
        }),
      );
      expect(native['model'], 'splash-runtime');
      expect(native['max_tokens'], 0);
      expect(native['temperature'], 0.4);
      expect(native['cache_salt'], 'scope');
      final consume = PublicPrefillRequest.parse(SplashOperationPath.chat, {
        ...input,
        'max_tokens': 32,
      });
      expect(consume.kind, PrefillOperationKind.consume);
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'max_completion_tokens': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'max_tokens': null,
          'max_completion_tokens': 0,
        }),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'stream': true,
        }),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'messages': [],
        }),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'max_tokens': null,
        }),
        throwsFormatException,
      );
      expect(
        () => PublicPrefillRequest.parse(SplashOperationPath.chat, {
          ...input,
          'temperature': -1,
        }),
        throwsFormatException,
      );
      ((input['messages'] as List).single as Map)['content'] = '后续变化';
      final snapshot = (prefill.body['messages'] as List).single as Map;
      expect(snapshot['content'], '材料');
      expect(() => snapshot['content'] = '尝试改写', throwsUnsupportedError);
    },
  );

  test('systemone prefill accepts state only while ordinary questions remain validated', () {
    final input = <String, Object?>{
      'model': 'model',
      'state': {'text': '内容'},
      'prefill_only': true,
      'cache_salt': 'scope',
    };
    final prefill = PublicPrefillRequest.parse(
      SplashOperationPath.systemone,
      input,
    );
    expect(prefill.kind, PrefillOperationKind.prefill);
    final native = prefill.toSplash(nativeModel: 'splash-decision');
    expect(native['model'], 'splash-decision');
    expect(native['prefill_only'], isTrue);
    expect(native['state'], {'text': '内容'});
    expect(
      () => PublicPrefillRequest.parse(SplashOperationPath.systemone, {
        ...input,
        'questions': {'q': {}},
      }),
      throwsFormatException,
    );
    expect(
      () => PublicPrefillRequest.parse(SplashOperationPath.systemone, {
        ...input,
        'state': null,
      }),
      throwsFormatException,
    );
    expect(
      () => PublicPrefillRequest.parse(SplashOperationPath.systemone, {
        ...input,
        'prefill_only': false,
        'questions': {},
      }),
      throwsFormatException,
    );
    final valid = {
      ...input,
      'prefill_only': false,
      'questions': {
        'q': {
          'type': 'choice',
          'instructions': '选择',
          'criteria': {'a': 'A', 'b': 'B'},
        },
      },
    };
    expect(
      PublicPrefillRequest.parse(SplashOperationPath.systemone, valid).kind,
      PrefillOperationKind.consume,
    );
  });
}
